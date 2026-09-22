
#ifndef PIPPINVR_INPUT_H
#define PIPPINVR_INPUT_H

#include <array>
#include <cstdint>

#include <openxr/openxr.h>

namespace pippinvr {

enum class Hand : uint32_t { Left = 0, Right = 1, Count = 2 };

struct HandState {
    bool poseValid = false;
    XrPosef aimPose{};
    bool grabbing = false;
    bool grabStarted = false;
    bool grabEnded = false;
    float thumbstickY = 0.0f;
    float thumbstickX = 0.0f;
};

class Input {
public:
    Input() = default;
    ~Input() = default;

    Input(const Input&) = delete;
    Input& operator=(const Input&) = delete;

    bool init(XrInstance instance);
    bool attach(XrSession session, XrSpace baseSpace);
    void shutdown();

    void update(XrSession session, XrTime predictedDisplayTime);

    const HandState& hand(Hand which) const {
        return hands_[static_cast<size_t>(which)];
    }

    bool backgroundCyclePressed() const { return backgroundCyclePressed_; }
    bool layoutResetPressed() const { return layoutResetPressed_; }

private:
    XrInstance instance_ = XR_NULL_HANDLE;
    XrSession session_ = XR_NULL_HANDLE;
    XrSpace baseSpace_ = XR_NULL_HANDLE;

    XrActionSet actionSet_ = XR_NULL_HANDLE;
    XrAction aimPoseAction_ = XR_NULL_HANDLE;
    XrAction grabAction_ = XR_NULL_HANDLE;
    XrAction thumbstickAction_ = XR_NULL_HANDLE;
    XrAction backgroundCycleAction_ = XR_NULL_HANDLE;
    XrAction layoutResetAction_ = XR_NULL_HANDLE;

    std::array<XrPath, 2> handPaths_{};
    std::array<XrSpace, 2> aimSpaces_{XR_NULL_HANDLE, XR_NULL_HANDLE};
    std::array<HandState, 2> hands_{};

    bool backgroundCyclePressed_ = false;
    bool layoutResetPressed_ = false;
    bool attached_ = false;
};

}  // namespace pippinvr

#endif  // PIPPINVR_INPUT_H
