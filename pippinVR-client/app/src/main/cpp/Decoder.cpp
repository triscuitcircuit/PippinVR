#include "Decoder.h"
#include "Log.h"

#include <cstring>

namespace pippinvr {
namespace {

/// Hold at most this many encoded frames. The link can burst faster than the decoder
/// retires frames; past this point the oldest non-keyframes are the right thing to
/// lose, because latency debt is worse than a dropped frame for interactive video.
constexpr size_t kMaxQueuedFrames = 12;

/// Images in flight between the codec and the renderer.
constexpr int32_t kMaxImages = 3;

constexpr int64_t kDequeueTimeoutUs = 10000;   // 10 ms

/// NAL unit type of the unit starting at `p` (which points just past a start code).
uint8_t nalType(const uint8_t* p, bool hevc) {
    return hevc ? static_cast<uint8_t>((p[0] >> 1) & 0x3f)
                : static_cast<uint8_t>(p[0] & 0x1f);
}

bool isParameterSet(uint8_t type, bool hevc) {
    if (hevc) return type == 32 || type == 33 || type == 34;   // VPS, SPS, PPS
    return type == 7 || type == 8;                             // SPS, PPS
}

/// Length of the leading run of parameter-set NALs in an Annex-B buffer -- i.e. the
/// bytes that belong in csd-0. Returns 0 if the buffer does not start with one.
size_t csdPrefixLength(const std::vector<uint8_t>& buf, bool hevc) {
    size_t lastEnd = 0;
    size_t i = 0;
    const size_t n = buf.size();

    while (i + 3 < n) {
        // Locate a start code at i.
        size_t scLen = 0;
        if (buf[i] == 0 && buf[i + 1] == 0 && buf[i + 2] == 1) {
            scLen = 3;
        } else if (i + 4 < n && buf[i] == 0 && buf[i + 1] == 0 && buf[i + 2] == 0 &&
                   buf[i + 3] == 1) {
            scLen = 4;
        } else {
            break;
        }

        const size_t payload = i + scLen;
        if (payload >= n) break;
        if (!isParameterSet(nalType(&buf[payload], hevc), hevc)) break;

        // Advance to the next start code; that is where this NAL ends.
        size_t j = payload;
        while (j + 2 < n && !(buf[j] == 0 && buf[j + 1] == 0 && buf[j + 2] == 1)) ++j;
        if (j + 2 >= n) { lastEnd = n; break; }
        // Include a 4-byte start code's leading zero in the next NAL, not this one.
        lastEnd = (j > payload && buf[j - 1] == 0) ? j - 1 : j;
        i = lastEnd;
    }
    return lastEnd;
}

}  // namespace

StreamDecoder::~StreamDecoder() { shutdown(); }

bool StreamDecoder::init(const StreamInfo& info) {
    info_ = info;

    // AIMAGE_FORMAT_PRIVATE + GPU_SAMPLED_IMAGE is what lets the decoder write into a
    // buffer we can later import as an EGLImage without a CPU copy.
    AImageReader* rawReader = nullptr;
    media_status_t st = AImageReader_newWithUsage(
        info.width, info.height, AIMAGE_FORMAT_PRIVATE,
        AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE, kMaxImages, &rawReader);
    if (st != AMEDIA_OK || rawReader == nullptr) {
        LOGE("stream %u: AImageReader_newWithUsage failed (%d)", info.id, st);
        return false;
    }
    reader_.reset(rawReader);

    st = AImageReader_getWindow(reader_.get(), &window_);
    if (st != AMEDIA_OK || window_ == nullptr) {
        LOGE("stream %u: AImageReader_getWindow failed (%d)", info.id, st);
        return false;
    }

    running_.store(true, std::memory_order_relaxed);
    worker_ = std::thread([this] { workerLoop(); });
    LOGI("stream %u: decoder ready (%ux%u %s)", info.id, info.width, info.height,
         info.mimeType());
    return true;
}

void StreamDecoder::shutdown() {
    if (running_.exchange(false)) {
        cv_.notify_all();
        if (worker_.joinable()) worker_.join();
    }

    // Order matters: the codec writes into the reader's window, and images must go
    // before the reader that vended them.
    codec_.reset();
    currentImage_.reset();
    reader_.reset();        // frees window_ as well
    window_ = nullptr;
    configured_ = false;
}

void StreamDecoder::submit(FramePacket&& pkt) {
    {
        std::lock_guard<std::mutex> lock(mutex_);
        if (queue_.size() >= kMaxQueuedFrames) {
            // Drop from the front, but never a keyframe -- losing one costs us every
            // frame until the next IDR.
            auto it = queue_.begin();
            while (it != queue_.end() && it->keyframe) ++it;
            if (it != queue_.end()) {
                queue_.erase(it);
            } else {
                queue_.pop_front();
            }
            framesDropped_.fetch_add(1, std::memory_order_relaxed);
        }
        queue_.push_back(std::move(pkt));
    }
    cv_.notify_one();
}

bool StreamDecoder::configureFromKeyframe(const FramePacket& pkt) {
    const bool hevc = info_.codec != 1;

    MediaFormatPtr format(AMediaFormat_new());
    AMediaFormat_setString(format.get(), AMEDIAFORMAT_KEY_MIME, info_.mimeType());
    AMediaFormat_setInt32(format.get(), AMEDIAFORMAT_KEY_WIDTH, info_.width);
    AMediaFormat_setInt32(format.get(), AMEDIAFORMAT_KEY_HEIGHT, info_.height);
    AMediaFormat_setInt32(format.get(), AMEDIAFORMAT_KEY_FRAME_RATE, info_.refreshHz);
    // Latency over smoothness: we want the freshest frame, not a reordered one.
    AMediaFormat_setInt32(format.get(), "low-latency", 1);

    // The server prepends VPS/SPS/PPS to every keyframe, so csd-0 is the leading
    // parameter-set run of this very frame.
    const size_t csdLen = csdPrefixLength(pkt.payload, hevc);
    if (csdLen > 0) {
        AMediaFormat_setBuffer(format.get(), "csd-0", pkt.payload.data(), csdLen);
        LOGI("stream %u: csd-0 is %zu bytes", info_.id, csdLen);
    } else {
        LOGW("stream %u: keyframe has no leading parameter sets; "
             "relying on in-band config", info_.id);
    }

    codec_.reset(AMediaCodec_createDecoderByType(info_.mimeType()));
    if (!codec_) {
        LOGE("stream %u: no decoder for %s", info_.id, info_.mimeType());
        return false;
    }

    media_status_t st = AMediaCodec_configure(codec_.get(), format.get(), window_,
                                              nullptr, 0);
    if (st != AMEDIA_OK) {
        LOGE("stream %u: AMediaCodec_configure failed (%d)", info_.id, st);
        codec_.reset();
        return false;
    }

    st = AMediaCodec_start(codec_.get());
    if (st != AMEDIA_OK) {
        LOGE("stream %u: AMediaCodec_start failed (%d)", info_.id, st);
        codec_.reset();
        return false;
    }

    configured_ = true;
    LOGI("stream %u: codec started", info_.id);
    return true;
}

void StreamDecoder::feed(const FramePacket& pkt) {
    ssize_t index = AMediaCodec_dequeueInputBuffer(codec_.get(), kDequeueTimeoutUs);
    if (index < 0) {
        framesDropped_.fetch_add(1, std::memory_order_relaxed);
        return;   // no input buffer free; skip this frame rather than block
    }

    size_t capacity = 0;
    uint8_t* buf = AMediaCodec_getInputBuffer(codec_.get(), static_cast<size_t>(index), &capacity);
    if (buf == nullptr || capacity < pkt.payload.size()) {
        LOGW("stream %u: input buffer too small (%zu < %zu)", info_.id, capacity,
             pkt.payload.size());
        AMediaCodec_queueInputBuffer(codec_.get(), static_cast<size_t>(index), 0, 0, 0, 0);
        return;
    }

    std::memcpy(buf, pkt.payload.data(), pkt.payload.size());
    const uint32_t flags = pkt.keyframe ? AMEDIACODEC_BUFFER_FLAG_KEY_FRAME : 0u;
    AMediaCodec_queueInputBuffer(codec_.get(), static_cast<size_t>(index), 0,
                                 pkt.payload.size(),
                                 static_cast<int64_t>(pkt.ptsUsec), flags);
}

void StreamDecoder::drainOutput() {
    AMediaCodecBufferInfo bufferInfo;
    for (;;) {
        ssize_t index = AMediaCodec_dequeueOutputBuffer(codec_.get(), &bufferInfo, 0);
        if (index >= 0) {
            // render = true sends the frame to the AImageReader surface.
            AMediaCodec_releaseOutputBuffer(codec_.get(), static_cast<size_t>(index), true);
            framesDecoded_.fetch_add(1, std::memory_order_relaxed);
        } else if (index == AMEDIACODEC_INFO_OUTPUT_FORMAT_CHANGED) {
            MediaFormatPtr out(AMediaCodec_getOutputFormat(codec_.get()));
            LOGI("stream %u: output format %s", info_.id,
                 AMediaFormat_toString(out.get()));
        } else {
            break;   // TRY_AGAIN_LATER or buffers-changed: nothing more to do now
        }
    }
}

void StreamDecoder::workerLoop() {
    while (running_.load(std::memory_order_relaxed)) {
        FramePacket pkt;
        {
            std::unique_lock<std::mutex> lock(mutex_);
            cv_.wait(lock, [this] {
                return !queue_.empty() || !running_.load(std::memory_order_relaxed);
            });
            if (!running_.load(std::memory_order_relaxed)) break;
            pkt = std::move(queue_.front());
            queue_.pop_front();
        }

        if (!configured_) {
            // Nothing before the first keyframe is decodable. The server guarantees
            // the first packet on a stream is a keyframe, so this should hit at once.
            if (!pkt.keyframe) continue;
            if (!configureFromKeyframe(pkt)) continue;
        }

        feed(pkt);
        drainOutput();
    }
    LOGI("stream %u: worker exiting", info_.id);
}

AHardwareBuffer* StreamDecoder::acquireLatest() {
    if (!reader_) return nullptr;

    AImage* rawImage = nullptr;
    media_status_t st = AImageReader_acquireLatestImage(reader_.get(), &rawImage);
    if (st != AMEDIA_OK || rawImage == nullptr) {
        // No new frame. Keep showing the previous one rather than flashing black.
        if (!currentImage_) return nullptr;
        AHardwareBuffer* held = nullptr;
        AImage_getHardwareBuffer(currentImage_.get(), &held);
        return held;
    }

    // The AHardwareBuffer is only valid while its AImage is alive, so the previous
    // image is released only once its replacement is in hand.
    currentImage_.reset(rawImage);

    AHardwareBuffer* buffer = nullptr;
    if (AImage_getHardwareBuffer(currentImage_.get(), &buffer) != AMEDIA_OK) {
        return nullptr;
    }
    return buffer;   // borrowed: owned by currentImage_
}

}  // namespace pippinvr
