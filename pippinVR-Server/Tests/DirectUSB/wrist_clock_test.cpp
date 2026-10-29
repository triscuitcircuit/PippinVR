#include "../../Sources/NewtDashboard/WristClock.h"

#include <cassert>
#include <cstdio>
#include <limits>

int main() {
    auto viewer = IdentityPose();
    auto palm = IdentityPose();
    palm.position = {0, -0.1f, -0.45f};
    palm.orientation = {-std::sqrt(0.5f), 0, 0, std::sqrt(0.5f)};
    WristClockGesture clock;
    clock.Update(0, true, palm, viewer);
    assert(!clock.visible);
    clock.Update(0.20, true, palm, viewer);
    assert(!clock.visible);
    clock.Update(0.26, true, palm, viewer);
    assert(clock.visible);
    clock.Update(20, true, palm, viewer);
    assert(clock.visible);
    auto away = palm;
    away.orientation = {std::sqrt(0.5f), 0, 0, std::sqrt(0.5f)};
    clock.Update(20.01, true, away, viewer);
    assert(clock.visible);
    clock.Update(20.05, true, palm, viewer);
    assert(clock.visible);
    clock.Update(20.10, true, away, viewer);
    clock.Update(20.23, true, away, viewer);
    assert(!clock.visible);
    clock.Update(21, true, palm, viewer);
    clock.Update(21.26, true, palm, viewer);
    assert(clock.visible);
    clock.Update(21.27, false, palm, viewer);
    assert(!clock.visible);
    for (float x : {-0.2f, 0.2f}) {
        clock.Reset();
        palm.position.x = x;
        clock.Update(0, true, palm, viewer);
        clock.Update(.3, true, palm, viewer);
        assert(clock.visible);
    }
    palm.position.x = 0;
    for (float z : {-0.10f, -1.1f, 0.45f}) {
        clock.Reset();
        palm.position.z = z;
        clock.Update(0, true, palm, viewer);
        clock.Update(1, true, palm, viewer);
        assert(!clock.visible);
    }
    palm.position.z = -.45f;
    palm.orientation.w = std::numeric_limits<float>::quiet_NaN();
    clock.Update(2, true, palm, viewer);
    assert(!clock.visible);
    palm.orientation = {0, 0, 0, 0};
    clock.Update(3, true, palm, viewer);
    assert(!clock.visible);
    std::puts(
        "PASS: wrist-clock dwell, hysteresis, either hand, tracking loss, range and invalid poses");
}
