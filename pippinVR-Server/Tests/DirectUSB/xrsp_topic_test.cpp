#include "ql_xrsp_topic.h"
#include "ql_xrsp_types.h"

#include <cassert>
#include <cstdio>
#include <cstring>
#include <vector>

extern "C" const char* xrsp_topic_str(int) {
    return "test";
}

static std::vector<uint8_t> packet(size_t bytes, size_t padding) {
    assert((bytes + padding) % 4 == 0 && padding <= 255);
    std::vector<uint8_t> wire(sizeof(xrsp_topic_header) + bytes + padding, 0xde);
    xrsp_topic_header header{};
    header.topic = TOPIC_CAMERA_STREAM;
    header.packet_version_is_internal = 1;
    header.has_alignment_padding = padding != 0;
    header.num_words = (bytes + padding) / 4 + 1;
    memcpy(wire.data(), &header, sizeof(header));
    for (size_t i = 0; i < bytes; ++i)
        wire[sizeof(header) + i] = uint8_t(i);
    if (padding)
        wire.back() = padding;
    return wire;
}

int main() {
    for (auto lengths : {std::pair<size_t, size_t>{984, 32}, {32, 0}, {0, 0}, {1, 3}}) {
        auto wire = packet(lengths.first, lengths.second);
        for (size_t split = sizeof(xrsp_topic_header); split <= wire.size(); ++split) {
            ql_xrsp_topic_pkt parsed{};
            std::vector<uint8_t> initial(wire.begin(), wire.begin() + split);
            assert(ql_xrsp_topic_pkt_create(&parsed, initial.data(), initial.size(), 123) ==
                   int(split));
            size_t pos = split;
            while (pos < wire.size()) {
                const size_t count = std::min<size_t>(7, wire.size() - pos);
                assert(ql_xrsp_topic_pkt_append(&parsed, wire.data() + pos, count) == int(count));
                pos += count;
            }
            assert(parsed.missing_bytes == 0);
            assert(parsed.payload_size == lengths.first && parsed.payload_valid == lengths.first);
            assert(parsed.remainder_offs == wire.size());
            assert(parsed.recv_ns == 123);
            if (lengths.first)
                assert(memcmp(parsed.payload, wire.data() + sizeof(xrsp_topic_header),
                              lengths.first) == 0);
            assert(ql_xrsp_topic_pkt_append(&parsed, nullptr, 0) == 0);
            assert(parsed.payload_valid == lengths.first);
            ql_xrsp_topic_pkt_destroy(&parsed);
        }
    }

    auto wire = packet(3, 1);
    wire.insert(wire.end(), 32, 0xff);
    ql_xrsp_topic_pkt parsed{};
    assert(ql_xrsp_topic_pkt_create(&parsed, wire.data(), wire.size(), 0) == 12);
    assert(parsed.payload_valid == 3);
    ql_xrsp_topic_pkt_destroy(&parsed);

    for (uint8_t padding : {uint8_t(0), uint8_t(5)}) {
        auto invalid = packet(3, 1);
        invalid.back() = padding;
        assert(ql_xrsp_topic_pkt_create(&parsed, invalid.data(), invalid.size(), 0) == -1);
        assert(!parsed.payload);
        assert(ql_xrsp_topic_pkt_create(&parsed, invalid.data(), 8, 0) == 8);
        assert(ql_xrsp_topic_pkt_append(&parsed, invalid.data() + 8, 4) == -1);
        assert(!parsed.payload);
    }
    auto invalid = packet(4, 0);
    invalid[2] = invalid[3] = 0;
    assert(ql_xrsp_topic_pkt_create(&parsed, invalid.data(), invalid.size(), 0) == -1);
    for (int n = -1; n < 8; ++n)
        assert(ql_xrsp_topic_pkt_create(&parsed, invalid.data(), n, 0) == -1);
    auto emptyPadding = packet(0, 0);
    emptyPadding[0] |= 8;
    assert(ql_xrsp_topic_pkt_create(&parsed, emptyPadding.data(), emptyPadding.size(), 0) == -1);
    puts(
        "PASS: padded/unpadded packets, every split, trailing packets, invalid padding and short "
        "headers");
}
