#include "Input.h"
#include "Log.h"

#include <cstring>
#include <vector>

namespace pippinvr {
namespace {

constexpr float kGrabThreshold = 0.6f;
constexpr float kStickDeadzone = 0.15f;

bool xrOk(XrResult result, const char* what) {
    if (XR_SUCCEEDED(result)) return true;
    LOGE("%s failed: XrResult %d", what, static_cast<int>(result));
    return false;
}

XrPath pathFor(XrInstance instance, const char* text) {
    XrPath path = XR_NULL_PATH;
    xrStringToPath(instance, text, &path);
    return path;
}

}  // namespace

bool Input::init(XrInstance instance) {
    instance_ = instance;

    XrActionSetCreateInfo setInfo{XR_TYPE_ACTION_SET_CREATE_INFO};
    std::strncpy(setInfo.actionSetName, "panels", XR_MAX_ACTION_SET_NAME_SIZE - 1);
    std::strncpy(setInfo.localizedActionSetName, "Panel Control",
                 XR_MAX_LOCALIZED_ACTION_SET_NAME_SIZE - 1);
    setInfo.priority = 0;
    if (!xrOk(xrCreateActionSet(instance_, &setInfo, &actionSet_),
              "xrCreateActionSet")) {
        return false;
    }

    handPaths_[0] = pathFor(instance_, "/user/hand/left");
    handPaths_[1] = pathFor(instance_, "/user/hand/right");

    auto makeAction = [&](const char* name, const char* localized,
                          XrActionType type, XrAction* out) {
        XrActionCreateInfo info{XR_TYPE_ACTION_CREATE_INFO};
        std::strncpy(info.actionName, name, XR_MAX_ACTION_NAME_SIZE - 1);
        std::strncpy(info.localizedActionName, localized,
                     XR_MAX_LOCALIZED_ACTION_NAME_SIZE - 1);
        info.actionType = type;
        info.countSubactionPaths = static_cast<uint32_t>(handPaths_.size());
        info.subactionPaths = handPaths_.data();
        return xrOk(xrCreateAction(actionSet_, &info, out), name);
    };

    if (!makeAction("aim_pose", "Aim", XR_ACTION_TYPE_POSE_INPUT, &aimPoseAction_)) return false;
    if (!makeAction("grab", "Grab Panel", XR_ACTION_TYPE_FLOAT_INPUT, &grabAction_)) return false;
    if (!makeAction("push_pull", "Push/Pull Panel", XR_ACTION_TYPE_VECTOR2F_INPUT,
                    &thumbstickAction_)) return false;
    if (!makeAction("cycle_bg", "Cycle Background", XR_ACTION_TYPE_BOOLEAN_INPUT,
                    &backgroundCycleAction_)) return false;
    if (!makeAction("reset_layout", "Reset Layout", XR_ACTION_TYPE_BOOLEAN_INPUT,
                    &layoutResetAction_)) return false;

    {
        std::vector<XrActionSuggestedBinding> bindings = {
            {aimPoseAction_, pathFor(instance_, "/user/hand/left/input/aim/pose")},
            {aimPoseAction_, pathFor(instance_, "/user/hand/right/input/aim/pose")},
            {grabAction_, pathFor(instance_, "/user/hand/left/input/trigger/value")},
            {grabAction_, pathFor(instance_, "/user/hand/right/input/trigger/value")},
            {thumbstickAction_, pathFor(instance_, "/user/hand/left/input/thumbstick")},
            {thumbstickAction_, pathFor(instance_, "/user/hand/right/input/thumbstick")},
            // B and Y cycle the background / reset the layout.
            {backgroundCycleAction_, pathFor(instance_, "/user/hand/right/input/b/click")},
            {layoutResetAction_, pathFor(instance_, "/user/hand/left/input/y/click")},
        };

        XrInteractionProfileSuggestedBinding suggested{
            XR_TYPE_INTERACTION_PROFILE_SUGGESTED_BINDING};
        suggested.interactionProfile =
            pathFor(instance_, "/interaction_profiles/oculus/touch_controller");
        suggested.suggestedBindings = bindings.data();
        suggested.countSuggestedBindings = static_cast<uint32_t>(bindings.size());
        xrOk(xrSuggestInteractionProfileBindings(instance_, &suggested),
             "suggest touch bindings");
    }

    {
        std::vector<XrActionSuggestedBinding> bindings = {
            {aimPoseAction_, pathFor(instance_, "/user/hand/left/input/aim/pose")},
            {aimPoseAction_, pathFor(instance_, "/user/hand/right/input/aim/pose")},
            {grabAction_, pathFor(instance_, "/user/hand/left/input/select/click")},
            {grabAction_, pathFor(instance_, "/user/hand/right/input/select/click")},
            {backgroundCycleAction_, pathFor(instance_, "/user/hand/right/input/menu/click")},
            {layoutResetAction_, pathFor(instance_, "/user/hand/left/input/menu/click")},
        };

        XrInteractionProfileSuggestedBinding suggested{
            XR_TYPE_INTERACTION_PROFILE_SUGGESTED_BINDING};
        suggested.interactionProfile =
            pathFor(instance_, "/interaction_profiles/khr/simple_controller");
        suggested.suggestedBindings = bindings.data();
        suggested.countSuggestedBindings = static_cast<uint32_t>(bindings.size());
        xrOk(xrSuggestInteractionProfileBindings(instance_, &suggested),
             "suggest simple bindings");
    }

    return true;
}

bool Input::attach(XrSession session, XrSpace baseSpace) {
    session_ = session;
    baseSpace_ = baseSpace;

    for (size_t i = 0; i < handPaths_.size(); ++i) {
        XrActionSpaceCreateInfo info{XR_TYPE_ACTION_SPACE_CREATE_INFO};
        info.action = aimPoseAction_;
        info.subactionPath = handPaths_[i];
        info.poseInActionSpace.orientation.w = 1.0f;
        if (!xrOk(xrCreateActionSpace(session_, &info, &aimSpaces_[i]),
                  "xrCreateActionSpace")) {
            return false;
        }
    }

    XrSessionActionSetsAttachInfo attachInfo{XR_TYPE_SESSION_ACTION_SETS_ATTACH_INFO};
    attachInfo.countActionSets = 1;
    attachInfo.actionSets = &actionSet_;
    if (!xrOk(xrAttachSessionActionSets(session_, &attachInfo),
              "xrAttachSessionActionSets")) {
        return false;
    }

    attached_ = true;
    LOGI("input: action set attached");
    return true;
}

void Input::shutdown() {
    for (XrSpace& space : aimSpaces_) {
        if (space != XR_NULL_HANDLE) {
            xrDestroySpace(space);
            space = XR_NULL_HANDLE;
        }
    }
    if (actionSet_ != XR_NULL_HANDLE) {
        xrDestroyActionSet(actionSet_);
        actionSet_ = XR_NULL_HANDLE;
    }
    attached_ = false;
}

void Input::update(XrSession session, XrTime predictedDisplayTime) {
    backgroundCyclePressed_ = false;
    layoutResetPressed_ = false;
    if (!attached_) return;

    XrActiveActionSet active{actionSet_, XR_NULL_PATH};
    XrActionsSyncInfo syncInfo{XR_TYPE_ACTIONS_SYNC_INFO};
    syncInfo.countActiveActionSets = 1;
    syncInfo.activeActionSets = &active;
    if (XR_FAILED(xrSyncActions(session, &syncInfo))) return;

    for (size_t i = 0; i < hands_.size(); ++i) {
        HandState& state = hands_[i];
        const bool wasGrabbing = state.grabbing;

        XrActionStateGetInfo getInfo{XR_TYPE_ACTION_STATE_GET_INFO};
        getInfo.subactionPath = handPaths_[i];

        // Aim pose
        getInfo.action = aimPoseAction_;
        XrActionStatePose poseState{XR_TYPE_ACTION_STATE_POSE};
        xrGetActionStatePose(session, &getInfo, &poseState);

        state.poseValid = false;
        if (poseState.isActive == XR_TRUE) {
            XrSpaceLocation location{XR_TYPE_SPACE_LOCATION};
            if (XR_SUCCEEDED(xrLocateSpace(aimSpaces_[i], baseSpace_,
                                           predictedDisplayTime, &location))) {
                constexpr XrSpaceLocationFlags required =
                    XR_SPACE_LOCATION_POSITION_VALID_BIT |
                    XR_SPACE_LOCATION_ORIENTATION_VALID_BIT;
                if ((location.locationFlags & required) == required) {
                    state.aimPose = location.pose;
                    state.poseValid = true;
                }
            }
        }

        // Grab (trigger)
        getInfo.action = grabAction_;
        XrActionStateFloat grabState{XR_TYPE_ACTION_STATE_FLOAT};
        xrGetActionStateFloat(session, &getInfo, &grabState);
        state.grabbing = grabState.isActive == XR_TRUE &&
                         grabState.currentState > kGrabThreshold;
        state.grabStarted = state.grabbing && !wasGrabbing;
        state.grabEnded = !state.grabbing && wasGrabbing;

        // Thumbstick
        getInfo.action = thumbstickAction_;
        XrActionStateVector2f stickState{XR_TYPE_ACTION_STATE_VECTOR2F};
        xrGetActionStateVector2f(session, &getInfo, &stickState);
        state.thumbstickY = 0.0f;
        state.thumbstickX = 0.0f;
        if (stickState.isActive == XR_TRUE) {
            if (std::abs(stickState.currentState.y) > kStickDeadzone) {
                state.thumbstickY = stickState.currentState.y;
            }
            if (std::abs(stickState.currentState.x) > kStickDeadzone) {
                state.thumbstickX = stickState.currentState.x;
            }
        }

        getInfo.action = backgroundCycleAction_;
        XrActionStateBoolean boolState{XR_TYPE_ACTION_STATE_BOOLEAN};
        if (XR_SUCCEEDED(xrGetActionStateBoolean(session, &getInfo, &boolState)) &&
            boolState.isActive == XR_TRUE && boolState.currentState == XR_TRUE &&
            boolState.changedSinceLastSync == XR_TRUE) {
            backgroundCyclePressed_ = true;
        }

        getInfo.action = layoutResetAction_;
        boolState = XrActionStateBoolean{XR_TYPE_ACTION_STATE_BOOLEAN};
        if (XR_SUCCEEDED(xrGetActionStateBoolean(session, &getInfo, &boolState)) &&
            boolState.isActive == XR_TRUE && boolState.currentState == XR_TRUE &&
            boolState.changedSinceLastSync == XR_TRUE) {
            layoutResetPressed_ = true;
        }
    }
}

}  // namespace pippinvr
