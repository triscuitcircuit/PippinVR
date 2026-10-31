#include "ql_invite_ok.h"

#include <cassert>
#include <cstdio>
#include <cstring>

static void read_list(const uint8_t* msg, size_t index, size_t* at, uint32_t* elem,
                      uint32_t* count) {
    uint32_t root_hi, lo, hi;
    memcpy(&root_hi, msg + 4, 4);
    const size_t slot = 1 + (root_hi & 0xffff) + index;
    memcpy(&lo, msg + slot * 8, 4);
    memcpy(&hi, msg + slot * 8 + 4, 4);
    assert((lo & 3) == 1);
    *at = slot + 1 + ((int32_t)lo >> 2);
    *elem = hi & 7;
    *count = hi >> 3;
}

int main() {
    const uint8_t ok2[] = {0x00, 0x00, 0x00, 0x00, 0x03, 0x00, 0x03, 0x00, 0x01, 0x00, 0x00, 0x00,
                           0x1F, 0x00, 0x01, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                           0x78, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                           0x00, 0x00, 0x00, 0x00, 0x09, 0x00, 0x00, 0x00, 0x1B, 0x00, 0x00, 0x00,
                           0x01, 0x00, 0x00, 0x00, 0x2A, 0x00, 0x00, 0x00, 0x55, 0x53, 0x42, 0x33,
                           0x00, 0x00, 0x00, 0x00, 0x01, 0x00, 0x03, 0x00, 0x02, 0x00, 0x00, 0x00};
    static_assert(sizeof(ok2) == 72, "fixture size");

    uint8_t out[128];
    const uint16_t raw[] = {0};
    const size_t len = ql_invite_ok_add_camera_formats(ok2, sizeof(ok2), raw, 1, out, sizeof(out));
    assert(len == 88);

    uint32_t root_hi;
    memcpy(&root_hi, out + 4, 4);
    assert((root_hi & 0xffff) == 3 && (root_hi >> 16) == 4);
    assert(memcmp(out + 8, ok2 + 8, 24) == 0);
    assert(memcmp(out + 32, ok2 + 32, 8) == 0);

    size_t at;
    uint32_t elem, count;
    read_list(out, 1, &at, &elem, &count);
    assert(elem == 3 && count == 3);
    assert(memcmp(out + at * 8, "\x01\x00\x03\x00\x02\x00", 6) == 0);
    read_list(out, 2, &at, &elem, &count);
    assert(elem == 2 && count == 5);
    assert(memcmp(out + at * 8, "USB3", 5) == 0);
    read_list(out, 3, &at, &elem, &count);
    assert(elem == 3 && count == 1 && at == 10);
    assert(out[at * 8] == 0 && out[at * 8 + 1] == 0);

    const uint16_t several[] = {0, 1, 2, 0x1234, 7};
    assert(ql_invite_ok_add_camera_formats(ok2, sizeof(ok2), several, 5, out, sizeof(out)) == 96);
    read_list(out, 3, &at, &elem, &count);
    assert(count == 5 && at == 10);
    assert(memcmp(out + at * 8, several, sizeof(several)) == 0);

    assert(ql_invite_ok_add_camera_formats(ok2, sizeof(ok2), raw, 0, out, sizeof(out)) == 0);
    assert(ql_invite_ok_add_camera_formats(ok2, sizeof(ok2) - 4, raw, 1, out, sizeof(out)) == 0);
    assert(ql_invite_ok_add_camera_formats(ok2, sizeof(ok2), raw, 1, out, 80) == 0);
    uint8_t four_ptrs[sizeof(ok2)];
    memcpy(four_ptrs, ok2, sizeof(ok2));
    four_ptrs[6] = 4;
    assert(ql_invite_ok_add_camera_formats(four_ptrs, sizeof(four_ptrs), raw, 1, out,
                                           sizeof(out)) == 0);
    uint8_t far_ptr[sizeof(ok2)];
    memcpy(far_ptr, ok2, sizeof(ok2));
    far_ptr[40] = 0x0a;
    assert(ql_invite_ok_add_camera_formats(far_ptr, sizeof(far_ptr), raw, 1, out, sizeof(out)) ==
           0);

    puts(
        "PASS: streaming InviteOk gains pointer 3 camera formats; data, features and text "
        "preserved");
}
