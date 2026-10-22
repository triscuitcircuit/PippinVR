#ifndef PIPPINVR_DECODER_H
#define PIPPINVR_DECODER_H

#include "NdkHandles.h"
#include "Net.h"

#include <android/hardware_buffer.h>
#include <android/native_window.h>

#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <deque>
#include <mutex>
#include <thread>

namespace pippinvr {

class StreamDecoder {
   public:
    StreamDecoder() = default;
    ~StreamDecoder();

    StreamDecoder(const StreamDecoder&) = delete;
    StreamDecoder& operator=(const StreamDecoder&) = delete;

    bool init(const StreamInfo& info);
    void shutdown();

    void submit(FramePacket&& pkt);

    AHardwareBuffer* acquireLatest();

    void setSmoothingEnabled(bool enabled) {
        smoothingEnabled_.store(enabled, std::memory_order_relaxed);
    }

    const StreamInfo& info() const { return info_; }
    uint64_t framesDecoded() const { return framesDecoded_.load(std::memory_order_relaxed); }
    uint64_t framesDropped() const { return framesDropped_.load(std::memory_order_relaxed); }

   private:
    void workerLoop();
    bool configureFromKeyframe(const FramePacket& pkt);
    void feed(const FramePacket& pkt);
    void drainOutput();
    AHardwareBuffer* acquirePaced();

    StreamInfo info_;

    ImageReaderPtr reader_;
    MediaCodecPtr codec_;
    ANativeWindow* window_ = nullptr;
    bool configured_ = false;

    ImagePtr currentImage_;

    std::atomic<bool> smoothingEnabled_{false};
    std::chrono::steady_clock::time_point lastAcquireTime_{};

    std::deque<FramePacket> queue_;
    std::mutex mutex_;
    std::condition_variable cv_;
    std::atomic<bool> running_{false};
    std::thread worker_;

    std::atomic<uint64_t> framesDecoded_{0};
    std::atomic<uint64_t> framesDropped_{0};
};

}  // namespace pippinvr

#endif  // PIPPINVR_DECODER_H
