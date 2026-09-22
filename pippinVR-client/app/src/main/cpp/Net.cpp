#include "Net.h"
#include "Log.h"

#include <arpa/inet.h>
#include <cerrno>
#include <cstring>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <sys/socket.h>
#include <unistd.h>

namespace pippinvr {
namespace {

constexpr uint32_t kMaxPayload = 32u * 1024u * 1024u;   // sanity bound per frame

uint16_t be16(const uint8_t* p) {
    return static_cast<uint16_t>((static_cast<uint16_t>(p[0]) << 8) | p[1]);
}

uint32_t be32(const uint8_t* p) {
    return (static_cast<uint32_t>(p[0]) << 24) | (static_cast<uint32_t>(p[1]) << 16) |
           (static_cast<uint32_t>(p[2]) << 8)  |  static_cast<uint32_t>(p[3]);
}

uint64_t be64(const uint8_t* p) {
    uint64_t v = 0;
    for (int i = 0; i < 8; ++i) v = (v << 8) | p[i];
    return v;
}

}  // namespace

StreamClient::StreamClient(std::string host, uint16_t port)
    : host_(std::move(host)), port_(port) {}

StreamClient::~StreamClient() { stop(); }

void StreamClient::start(HeaderFn onHeader, FrameFn onFrame) {
    if (running_.exchange(true)) return;
    onHeader_ = std::move(onHeader);
    onFrame_ = std::move(onFrame);
    thread_ = std::thread([this] { runLoop(); });
}

void StreamClient::stop() {
    if (!running_.exchange(false)) return;
    int s = sock_.load();
    if (s >= 0) ::shutdown(s, SHUT_RDWR);
    if (thread_.joinable()) thread_.join();
    closeSocket();
}

void StreamClient::closeSocket() {
    int s = sock_.exchange(-1);
    if (s >= 0) ::close(s);
    connected_.store(false, std::memory_order_relaxed);
}

bool StreamClient::connectOnce() {
    int s = ::socket(AF_INET, SOCK_STREAM, 0);
    if (s < 0) {
        LOGE("socket() failed: %s", strerror(errno));
        return false;
    }

    int one = 1;
    ::setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));

    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(port_);
    if (::inet_pton(AF_INET, host_.c_str(), &addr.sin_addr) != 1) {
        LOGE("bad host address '%s'", host_.c_str());
        ::close(s);
        return false;
    }

    if (::connect(s, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) != 0) {
        ::close(s);
        return false;
    }

    sock_.store(s);
    connected_.store(true, std::memory_order_relaxed);
    LOGI("connected to %s:%u", host_.c_str(), port_);
    return true;
}

bool StreamClient::readExact(void* dst, size_t n) {
    auto* p = static_cast<uint8_t*>(dst);
    size_t got = 0;
    while (got < n) {
        if (!running_.load(std::memory_order_relaxed)) return false;
        int s = sock_.load();
        if (s < 0) return false;
        ssize_t r = ::recv(s, p + got, n - got, 0);
        if (r > 0) {
            got += static_cast<size_t>(r);
        } else if (r == 0) {
            LOGW("server closed the connection");
            return false;
        } else {
            if (errno == EINTR) continue;
            LOGW("recv failed: %s", strerror(errno));
            return false;
        }
    }
    return true;
}

bool StreamClient::readSessionHeader(std::vector<StreamInfo>& out) {
    uint8_t head[8];
    if (!readExact(head, sizeof(head))) return false;

    if (std::memcmp(head, "MVRS", 4) != 0) {
        LOGE("bad magic %02x%02x%02x%02x -- not a pippinvr stream",
             head[0], head[1], head[2], head[3]);
        return false;
    }
    const uint16_t version = be16(head + 4);
    const uint16_t count = be16(head + 6);
    if (version != 2) {
        LOGE("unsupported protocol version %u (this client speaks 2)", version);
        return false;
    }

    out.clear();
    out.reserve(count);
    for (uint16_t i = 0; i < count; ++i) {
        uint8_t rec[10];
        if (!readExact(rec, sizeof(rec))) return false;

        StreamInfo s;
        s.id        = rec[0];
        s.codec     = rec[1];
        s.width     = be16(rec + 2);
        s.height    = be16(rec + 4);
        s.refreshHz = be16(rec + 6);
        s.hiDPI     = (rec[8] & 0x01) != 0;

        const uint8_t nameLen = rec[9];
        if (nameLen > 0) {
            std::vector<char> name(nameLen);
            if (!readExact(name.data(), nameLen)) return false;
            s.name.assign(name.data(), nameLen);
        }

        LOGI("stream %u '%s' %ux%u@%u %s hiDPI=%d", s.id, s.name.c_str(),
             s.width, s.height, s.refreshHz, s.mimeType(), s.hiDPI ? 1 : 0);
        out.push_back(std::move(s));
    }
    return true;
}

bool StreamClient::readFrame(FramePacket& out) {
    uint8_t hdr[14];
    if (!readExact(hdr, sizeof(hdr))) return false;

    const uint32_t length = be32(hdr + 2);
    if (length == 0 || length > kMaxPayload) {
        LOGE("implausible frame length %u -- stream desynchronised", length);
        return false;
    }

    out.streamId = hdr[0];
    out.keyframe = (hdr[1] & 0x01) != 0;
    out.ptsUsec  = be64(hdr + 6);
    out.payload.resize(length);
    return readExact(out.payload.data(), length);
}

void StreamClient::runLoop() {
    bool loggedWaiting = false;

    while (running_.load(std::memory_order_relaxed)) {
        if (loggedWaiting) {
            for (int i = 0; i < 5 && running_.load(std::memory_order_relaxed); ++i) {
                usleep(100 * 1000);
            }
            if (!running_.load(std::memory_order_relaxed)) break;
        }

        if (!connectOnce()) {
            if (!loggedWaiting) {
                LOGI("waiting for server at %s:%u", host_.c_str(), port_);
                loggedWaiting = true;
            }
            continue;
        }

        std::vector<StreamInfo> streams;
        if (!readSessionHeader(streams)) {
            if (!loggedWaiting) {
                LOGI("Waiting for tunnel server");
                loggedWaiting = true;
            }
            closeSocket();
            continue;
        }

        loggedWaiting = false;
        if (onHeader_) onHeader_(streams);

        FramePacket pkt;
        while (running_.load(std::memory_order_relaxed) && readFrame(pkt)) {
            if (onFrame_) onFrame_(std::move(pkt));
            pkt.payload.clear();
        }

        closeSocket();
        LOGI("Retrying connection");
        loggedWaiting = true;
    }
}

}  // namespace pippinvr
