
#ifndef PIPPINVR_NET_H
#define PIPPINVR_NET_H

#include <atomic>
#include <cstdint>
#include <functional>
#include <string>
#include <thread>
#include <vector>

namespace pippinvr {

struct FramePacket {
    uint8_t streamId = 0;
    bool keyframe = false;
    uint64_t ptsUsec = 0;
    std::vector<uint8_t> payload;
};

struct StreamInfo {
    uint8_t id = 0;
    uint8_t codec = 0;
    uint16_t width = 0;
    uint16_t height = 0;
    uint16_t refreshHz = 0;
    bool hiDPI = false;
    std::string name;

    const char* mimeType() const { return codec == 1 ? "video/avc" : "video/hevc"; }
};

class StreamClient {
   public:
    using HeaderFn = std::function<void(const std::vector<StreamInfo>&)>;
    using FrameFn = std::function<void(FramePacket&&)>;
    using ReconfigureFn = std::function<void(const std::vector<StreamInfo>&)>;
    using StatusFn = std::function<void(bool connected, const char* message)>;

    StreamClient(std::string host, uint16_t port);
    ~StreamClient();

    StreamClient(const StreamClient&) = delete;
    StreamClient& operator=(const StreamClient&) = delete;

    void start(HeaderFn onHeader, FrameFn onFrame, ReconfigureFn onReconfigure = nullptr,
               StatusFn onStatus = nullptr);
    void stop();

    bool connected() const { return connected_.load(std::memory_order_relaxed); }

   private:
    void runLoop();
    bool connectOnce();
    void closeSocket();

    bool readExact(void* dst, size_t n);
    bool readSessionHeader(std::vector<StreamInfo>& out);
    bool readFrame(FramePacket& out);
    bool readReconfiguration(std::vector<StreamInfo>& out);

    std::string host_;
    uint16_t port_;

    std::atomic<int> sock_{-1};
    std::atomic<bool> running_{false};
    std::atomic<bool> connected_{false};
    std::thread thread_;

    HeaderFn onHeader_;
    FrameFn onFrame_;
    ReconfigureFn onReconfigure_;
    StatusFn onStatus_;
};

}  // namespace pippinvr

#endif  // PIPPINVR_NET_H
