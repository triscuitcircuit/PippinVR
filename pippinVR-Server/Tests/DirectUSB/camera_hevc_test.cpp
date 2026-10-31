#include "ql_camera_hevc.h"

#include <cassert>
#include <cstdio>
#include <vector>

using bytes = std::vector<uint8_t>;

static void append(bytes& out, const bytes& more) {
    out.insert(out.end(), more.begin(), more.end());
}

static bytes nal4(unsigned type, bytes body) {
    bytes out = {0, 0, 0, 1, (uint8_t)(type << 1), 1};
    append(out, body);
    return out;
}

static bytes chunk(const bytes& annexb) {
    bytes out = {(uint8_t)annexb.size(), (uint8_t)(annexb.size() >> 8),
                 (uint8_t)(annexb.size() >> 16), (uint8_t)(annexb.size() >> 24)};
    append(out, annexb);
    return out;
}

static std::vector<bytes> sample_nals(const bytes& sample) {
    std::vector<bytes> out;
    size_t at = 0;
    while (at + 4 <= sample.size()) {
        const size_t n = (size_t)sample[at] << 24 | (size_t)sample[at + 1] << 16 |
                         (size_t)sample[at + 2] << 8 | sample[at + 3];
        assert(at + 4 + n <= sample.size());
        out.emplace_back(sample.begin() + at + 4, sample.begin() + at + 4 + n);
        at += 4 + n;
    }
    assert(at == sample.size());
    return out;
}

int main() {
    bytes params = nal4(32, {0x0c, 0x01});
    append(params, nal4(33, {0x01, 0x02, 0x03}));
    append(params, nal4(34, {0xc1, 0x73}));
    bytes picture = nal4(19, {0xaf, 0x01});
    append(picture, nal4(19, {0x10, 0x02, 0x00, 0x00}));
    append(picture, nal4(19, {0x20, 0x03}));
    bytes payload = chunk(params);
    append(payload, chunk(picture));

    ql_hevc_access_unit unit;
    assert(ql_hevc_from_chunks(payload.data(), payload.size(), &unit));
    assert((unit.vps == bytes{32 << 1, 1, 0x0c, 0x01}));
    assert((unit.sps == bytes{33 << 1, 1, 0x01, 0x02, 0x03}));
    assert((unit.pps == bytes{34 << 1, 1, 0xc1, 0x73}));
    assert(unit.vcl_count == 3 && unit.irap && !unit.cra_or_bla && !unit.rasl);
    auto nals = sample_nals(unit.sample);
    assert(nals.size() == 3);
    assert((nals[0] == bytes{19 << 1, 1, 0xaf, 0x01}));
    assert((nals[1] == bytes{19 << 1, 1, 0x10, 0x02}));
    assert((nals[2] == bytes{19 << 1, 1, 0x20, 0x03}));

    bytes p = {0, 0, 1, 35 << 1, 1, 0x50};
    append(p, {0, 0, 1, 39 << 1, 1, 0x05, 0x80});
    for (uint8_t i = 0; i < 3; i++)
        append(p, {0, 0, 1, 1 << 1, 1, (uint8_t)(0x40 + i)});
    payload = chunk(p);
    assert(ql_hevc_from_chunks(payload.data(), payload.size(), &unit));
    assert(unit.vps.empty() && unit.sps.empty() && unit.pps.empty());
    assert(unit.vcl_count == 3 && !unit.irap);
    nals = sample_nals(unit.sample);
    assert(nals.size() == 3 && (nals[2] == bytes{1 << 1, 1, 0x42}));

    payload = chunk(nal4(21, {0x01}));
    assert(ql_hevc_from_chunks(payload.data(), payload.size(), &unit) && unit.irap &&
           unit.cra_or_bla);
    payload = chunk(nal4(8, {0x01}));
    assert(ql_hevc_from_chunks(payload.data(), payload.size(), &unit) && unit.rasl && !unit.irap);

    bytes bad = chunk(picture);
    bad[0] += 1;
    assert(!ql_hevc_from_chunks(bad.data(), bad.size(), &unit));
    bad = chunk(picture);
    bad.push_back(0);
    assert(!ql_hevc_from_chunks(bad.data(), bad.size(), &unit));
    bytes zero = {0, 0, 0, 0};
    assert(!ql_hevc_from_chunks(zero.data(), zero.size(), &unit));

    puts(
        "PASS: HEVC chunk framing to parameter sets + length-prefixed sample; AUD/SEI dropped; "
        "CRA/RASL flags; malformed chunks");
}
