#include "ql_camera_stream.h"

#include <cassert>
#include <cstdio>
#include <vector>

using R = ql_camera_reassembler;

static std::vector<uint8_t> frame(std::vector<uint32_t> words, uint8_t seed) {
    std::vector<uint8_t> out;
    auto put32 = [&](uint32_t v) {
        for (int i = 0; i < 4; i++)
            out.push_back((uint8_t)(v >> (8 * i)));
    };
    put32((uint32_t)words.size() - 1);
    for (uint32_t w : words)
        put32(w);
    while (out.size() % 8)
        out.push_back(0);
    size_t total = 0;
    for (uint32_t w : words)
        total += (size_t)w * 8;
    for (size_t i = 0; i < total; i++)
        out.push_back((uint8_t)(seed + i));
    return out;
}

static std::vector<std::vector<uint8_t>> run(R& r,
                                             const std::vector<std::vector<uint8_t>>& packets) {
    std::vector<std::vector<uint8_t>> done;
    for (const auto& p : packets) {
        size_t offset = 0;
        for (;;) {
            auto result = r.feed(p.data(), p.size(), &offset);
            if (result == R::Result::Message) {
                done.push_back(r.body);
                r.reset();
                continue;
            }
            break;
        }
    }
    return done;
}

static std::vector<uint8_t> body_of(const std::vector<uint8_t>& framed, size_t header) {
    return std::vector<uint8_t>(framed.begin() + header, framed.end());
}

int main() {
    const auto three = frame({5, 1, 40}, 7);
    assert(three.size() == 16 + 46 * 8);

    {
        R r;
        auto out = run(r, {{three.begin(), three.begin() + 16}, {three.begin() + 16, three.end()}});
        assert(out.size() == 1 && out[0] == body_of(three, 16));
        assert(r.segment_count == 0 && r.invalid == 0);
    }

    for (size_t split = 1; split < three.size(); split++) {
        R r;
        auto out =
            run(r, {{three.begin(), three.begin() + split}, {three.begin() + split, three.end()}});
        assert(out.size() == 1 && out[0] == body_of(three, 16));
    }

    {
        R r;
        std::vector<std::vector<uint8_t>> packets;
        for (uint8_t b : three)
            packets.push_back({b});
        auto out = run(r, packets);
        assert(out.size() == 1 && out[0] == body_of(three, 16));
    }

    {
        const auto two = frame({2, 3}, 1);
        const auto one = frame({4}, 9);
        assert(two.size() == 16 + 40 && one.size() == 8 + 32);
        std::vector<uint8_t> packet(two);
        packet.insert(packet.end(), one.begin(), one.end());
        R r;
        auto out = run(r, {packet});
        assert(out.size() == 2 && out[0] == body_of(two, 16) && out[1] == body_of(one, 8));
    }

    {
        R r;
        std::vector<uint8_t> bad_count = {0xff, 0, 0, 0, 1, 2, 3, 4};
        std::vector<uint8_t> zero_size = {0, 0, 0, 0, 0, 0, 0, 0, 9, 9};
        std::vector<uint8_t> oversize = {0, 0, 0, 0, 0xff, 0xff, 0xff, 0xff};
        auto out = run(r, {bad_count, zero_size, oversize, three});
        assert(r.invalid == 3);
        assert(out.size() == 1 && out[0] == body_of(three, 16));
    }

    puts(
        "PASS: camera stream framing across every split, byte-wise delivery, packed messages, "
        "invalid framing resync");
}
