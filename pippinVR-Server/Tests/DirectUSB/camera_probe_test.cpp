#include "ql_camera_probe.h"

#include <cassert>
#include <cstdio>

static constexpr int64_t kTen = 10000000000LL;

static ql_camera_probe_action step(ql_camera_probe_state& s, int64_t now, bool ready,
                                   bool stalled = false, int64_t duration = kTen) {
    return ql_camera_probe_step(&s, now, ready, stalled, duration);
}

int main() {
    ql_camera_probe_state state{};
    assert(step(state, 1, false) == QL_CAMERA_PROBE_NONE);
    assert(!state.attempted);
    assert(step(state, 100, true) == QL_CAMERA_PROBE_START);
    assert(step(state, 101, true) == QL_CAMERA_PROBE_NONE);
    assert(step(state, 10000000099LL, true) == QL_CAMERA_PROBE_NONE);
    assert(step(state, 10000000100LL, true) == QL_CAMERA_PROBE_STOP);
    assert(!state.active);
    assert(step(state, 20000000100LL, true) == QL_CAMERA_PROBE_NONE);
    assert(step(state, 20000000101LL, false) == QL_CAMERA_PROBE_NONE);
    assert(step(state, 20000000102LL, true) == QL_CAMERA_PROBE_NONE);

    state = {};
    assert(step(state, 200, true) == QL_CAMERA_PROBE_START);
    assert(step(state, 201, false) == QL_CAMERA_PROBE_STOP);
    assert(step(state, 202, false) == QL_CAMERA_PROBE_NONE);
    assert(step(state, 203, true) == QL_CAMERA_PROBE_NONE);

    state = {};
    assert(step(state, 0, true, false, 15000000000LL) == QL_CAMERA_PROBE_START);
    assert(step(state, 14999999999LL, true) == QL_CAMERA_PROBE_NONE);
    assert(step(state, 15000000000LL, true) == QL_CAMERA_PROBE_STOP);

    state = {};
    assert(step(state, 0, false, true) == QL_CAMERA_PROBE_NONE);

    state = {};
    const int64_t ms = 1000000;
    assert(step(state, 0, true) == QL_CAMERA_PROBE_START);
    assert(step(state, 1000 * ms, true, true) == QL_CAMERA_PROBE_RESTART_STOP);
    assert(state.restarts == 1 && state.restart_pending);
    assert(step(state, 1100 * ms, true, true) == QL_CAMERA_PROBE_NONE);
    assert(step(state, 1300 * ms, true, true) == QL_CAMERA_PROBE_RESTART_START);
    assert(!state.restart_pending);
    assert(step(state, 1400 * ms, true, true) == QL_CAMERA_PROBE_NONE);
    assert(step(state, 3299 * ms, true, true) == QL_CAMERA_PROBE_NONE);
    assert(step(state, 3300 * ms, true, false) == QL_CAMERA_PROBE_NONE);

    int64_t t = 4000 * ms;
    for (int i = 1; i < QL_CAMERA_PROBE_MAX_RESTARTS; i++) {
        assert(step(state, t, true, true) == QL_CAMERA_PROBE_RESTART_STOP);
        assert(step(state, t + 300 * ms, true, true) == QL_CAMERA_PROBE_RESTART_START);
        t += 2300 * ms;
    }
    assert(state.restarts == QL_CAMERA_PROBE_MAX_RESTARTS);
    assert(t < kTen);
    assert(step(state, t, true, true) == QL_CAMERA_PROBE_NONE);
    assert(step(state, kTen, true, true) == QL_CAMERA_PROBE_STOP);

    state = {};
    assert(step(state, 0, true) == QL_CAMERA_PROBE_START);
    assert(step(state, 9900 * ms, true, true) == QL_CAMERA_PROBE_RESTART_STOP);
    assert(step(state, kTen, true, true) == QL_CAMERA_PROBE_STOP);
    assert(!state.active && !state.restart_pending);
    assert(step(state, kTen + 300 * ms, true, true) == QL_CAMERA_PROBE_NONE);
    state = {};
    assert(step(state, 0, true) == QL_CAMERA_PROBE_START);
    assert(step(state, 1000 * ms, true, true) == QL_CAMERA_PROBE_RESTART_STOP);
    assert(step(state, 1100 * ms, false, true) == QL_CAMERA_PROBE_STOP);

    auto portal = [](ql_camera_probe_state& s, int64_t now, bool ready, bool requested,
                     bool stalled = false) {
        return ql_camera_portal_step(&s, now, ready, requested, stalled);
    };
    state = {};
    assert(portal(state, 0, true, false) == QL_CAMERA_PROBE_NONE);
    assert(portal(state, 1, false, true) == QL_CAMERA_PROBE_NONE);
    assert(portal(state, 2, true, true) == QL_CAMERA_PROBE_START);
    assert(portal(state, kTen * 10, true, true) == QL_CAMERA_PROBE_NONE);
    assert(portal(state, kTen * 10 + 1, true, false) == QL_CAMERA_PROBE_STOP);
    const int64_t stopped = kTen * 10 + 1;
    assert(portal(state, stopped + 100 * ms, true, true) == QL_CAMERA_PROBE_NONE);
    assert(portal(state, stopped + 300 * ms, true, true) == QL_CAMERA_PROBE_START);

    t = stopped + 1000 * ms;
    for (int i = 0; i < QL_CAMERA_PROBE_MAX_RESTARTS; i++) {
        assert(portal(state, t, true, true, true) == QL_CAMERA_PROBE_RESTART_STOP);
        assert(portal(state, t + 300 * ms, true, true, true) == QL_CAMERA_PROBE_RESTART_START);
        t += 2300 * ms;
    }
    assert(portal(state, t, true, true, true) == QL_CAMERA_PROBE_NONE);
    assert(portal(state, t + ms, true, false, true) == QL_CAMERA_PROBE_STOP);
    assert(portal(state, t + 400 * ms, true, true) == QL_CAMERA_PROBE_START);
    assert(state.restarts == 0);

    assert(portal(state, t + 500 * ms, true, true, true) == QL_CAMERA_PROBE_RESTART_STOP);
    assert(portal(state, t + 600 * ms, false, true, true) == QL_CAMERA_PROBE_STOP);
    assert(!state.active && !state.restart_pending);

    puts(
        "PASS: delayed readiness, configurable window, shutdown/session loss, no retries on "
        "reconnect, "
        "stall restart with pause/grace/cap; portal follows request with pause and per-start "
        "restart budget");
}
