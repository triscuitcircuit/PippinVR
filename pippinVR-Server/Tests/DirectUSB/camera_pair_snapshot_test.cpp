#include <cassert>
#include <cstdio>
#include <thread>

#include "ql_camera_vt.cpp"

enum u_logging_level ql_log_level = U_LOGGING_ERROR;
extern "C" void u_log(const char*, int, const char*, enum u_logging_level, const char*, ...) {}

int main() {
    CVPixelBufferRef images[2]{};
    for (auto& image : images)
        assert(CVPixelBufferCreate(nullptr, 2, 2, kCVPixelFormatType_32BGRA, nullptr, &image) ==
               kCVReturnSuccess);
    vt_stream left{}, right{};
    left.id = 0;
    right.id = 1;
    std::atomic<bool> done{false};
    std::thread publisher([&] {
        for (uint64_t i = 1; i <= 50000; ++i) {
            const unsigned which = unsigned(i % 2);
            publish_frame(&left, images[which], i);
            publish_frame(&right, images[which], i);
            if (i % 10 == 0)
                std::this_thread::yield();
        }
        done = true;
    });
    uint64_t seq = 0, checked = 0;
    while (!done || seq != 50000) {
        void *l = nullptr, *r = nullptr;
        int64_t timestamp = 0;
        if (ql_passthrough_copy_latest_ex(&seq, &l, &r, &timestamp)) {
            assert(timestamp > 0);
            assert(l == images[timestamp % 2] && r == images[timestamp % 2]);
            assert(seq == uint64_t(timestamp));
            CVPixelBufferRelease(static_cast<CVPixelBufferRef>(l));
            CVPixelBufferRelease(static_cast<CVPixelBufferRef>(r));
            ++checked;
        }
    }
    publisher.join();
    void *l = nullptr, *r = nullptr;
    assert(!ql_passthrough_copy_latest(nullptr, &l, &r));
    assert(!ql_passthrough_copy_latest(&seq, &l, &r));
    ql_camera_vt_clear_frames();
    seq = 0;
    assert(!ql_passthrough_copy_latest_ex(&seq, &l, &r, nullptr));
    publish_frame(&left, images[0], 60000);
    publish_frame(&left, images[1], 60001);
    publish_frame(&right, images[0], 60000);
    int64_t timestamp = 0;
    assert(ql_passthrough_copy_latest_ex(&seq, &l, &r, &timestamp));
    assert(timestamp == 60000 && l == images[0] && r == images[0]);
    CVPixelBufferRelease(static_cast<CVPixelBufferRef>(l));
    CVPixelBufferRelease(static_cast<CVPixelBufferRef>(r));
    publish_frame(&right, images[1], 60001);
    assert(ql_passthrough_copy_latest_ex(&seq, &l, &r, &timestamp));
    assert(timestamp == 60001 && l == images[1] && r == images[1]);
    CVPixelBufferRelease(static_cast<CVPixelBufferRef>(l));
    CVPixelBufferRelease(static_cast<CVPixelBufferRef>(r));
    publish_frame(&left, images[0], 59999);
    publish_frame(&right, images[0], 59999);
    assert(!ql_passthrough_copy_latest_ex(&seq, &l, &r, &timestamp));
    for (uint64_t i = 70000; i < 70020; ++i)
        publish_frame(&left, images[0], i);
    assert(g_frames.pending[0].size() == 4);
    publish_frame(&right, images[0], 70019);
    assert(ql_passthrough_copy_latest_ex(&seq, &l, &r, &timestamp) && timestamp == 70019);
    CVPixelBufferRelease(static_cast<CVPixelBufferRef>(l));
    CVPixelBufferRelease(static_cast<CVPixelBufferRef>(r));
    ql_camera_vt owner{};
    g_frames.owner = &owner;
    g_frames.last_pair_ns = os_monotonic_get_ns() - 3'000'000'000LL;
    assert(ql_camera_vt_stalled(&owner));
    g_frames.last_pair_ns = os_monotonic_get_ns();
    assert(!ql_camera_vt_stalled(&owner));
    g_frames.owner = nullptr;
    vt_stream failed{};
    failed.waiting_for_irap = false;
    failed.in_flight = 1;
    on_decoded(&failed, nullptr, -12909, 0, nullptr, kCMTimeInvalid, kCMTimeInvalid);
    assert(failed.waiting_for_irap && failed.gaps == 1 && failed.decode_errors == 1 &&
           failed.in_flight == 0);
    ql_camera_vt_clear_frames();
    for (auto image : images)
        CVPixelBufferRelease(image);
    printf(
        "PASS: %llu concurrent snapshots, skewed stereo matching, bounded retention, stale-pair "
        "and decode-error recovery\n",
        (unsigned long long)checked);
}
