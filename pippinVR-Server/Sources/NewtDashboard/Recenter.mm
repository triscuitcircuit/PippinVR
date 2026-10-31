// SPDX-License-Identifier: MIT


#include "NewtXRApp.h"
#include "NewtInternal.h"
#include "include/NewtLog.h"
#include "Recenter.h"
#include <algorithm>
#include <cstring>
#include <dlfcn.h>
#include <mach-o/dyld.h>
using namespace NewtInternal;

void NewtXR::PollRecenterButton() {
    if (!mSystemHolds) {


        const auto now = std::chrono::steady_clock::now();
        if (now - mSystemHoldsLookup < std::chrono::seconds(2)) return;
        mSystemHoldsLookup = now;
        for (uint32_t i = 0; i < _dyld_image_count() && !mSystemHolds; ++i) {
            const char* name = _dyld_get_image_name(i);
            if (!name || !std::strstr(name, "libopenxr_monado")) continue;
            void* handle = dlopen(name, RTLD_LAZY | RTLD_LOCAL | RTLD_NOLOAD);
            if (!handle) continue;
            mSystemHolds = reinterpret_cast<uint32_t (*)()>(dlsym(handle, "ql_system_button_holds"));

            mSystemHoldProgress = reinterpret_cast<float (*)(int)>(dlsym(handle, "ql_system_button_hold_progress"));
            if (mSystemHolds) mRecenterRuntime = handle;
            else dlclose(handle);
        }
        if (!mSystemHolds) return;
        mSystemHoldsSeen = mSystemHolds();
        return;
    }
    UpdateRecenterRing();
    const uint32_t holds = mSystemHolds();
    if (holds == mSystemHoldsSeen) return;
    mSystemHoldsSeen = holds;
    RecenterContent();
    mRecenterDoneAt = std::chrono::steady_clock::now();
}



void NewtXR::UpdateRecenterRing() {
    constexpr float kShowAfter = 0.15f;
    float progress = -1;
    for (int hand = 0; hand < 2; ++hand) {
        const float p = mSystemHoldProgress ? mSystemHoldProgress(hand) : -1;

        if (p >= kShowAfter && mRecenterHandProgress[hand] < kShowAfter) mCore->PulseHaptic(hand, 0.12f);
        mRecenterHandProgress[hand] = p;
        progress = std::max(progress, p);
    }
    const auto now = std::chrono::steady_clock::now();
    const bool done = now - mRecenterDoneAt < std::chrono::milliseconds(500);

    int step = -1;
    if (done) step = kRecenterSteps + 1;
    else if (progress >= kShowAfter && progress < 1) step = int(progress * kRecenterSteps);
    mRecenterRingStep = step;
}


void NewtXR::ReleaseRecenterRuntime() {
    mSystemHolds = nullptr;
    mSystemHoldProgress = nullptr;
    mRecenterRingStep = mRecenterRenderedStep = -1;
    if (mRecenterRuntime) dlclose(mRecenterRuntime);
    mRecenterRuntime = nullptr;
}



void NewtXR::RecenterContent() {
    if (!mLastViewerValid) return;
    const recenter::Home to = recenter::ViewerHome(mViewerPose);
    const XrPosef delta = recenter::Delta(mContentHome, to);
    for (int i = 0; i < static_cast<int>(mPanels.size()); ++i) {
        if (PanelLocked(i)) continue;
        auto& panel = *mPanels[i];
        panel.pose = recenter::Apply(delta, panel.pose);
        if (panel.passthrough) StorePassthroughPlacement(panel);
    }
    for (auto& model : mModels) model->pose = recenter::Apply(delta, model->pose);
    for (auto& panel : mCustomPanels)
        if (panel.spec.anchor == customui::Anchor::World && panel.placed) panel.worldPose = recenter::Apply(delta, panel.worldPose);
    mContentHome = to;
    mFollowValid = false;
    mRecenterMenu = true;
    mGrabHand = -1;
    mGrabbedPanel = -1;
    mGrabbedModel = -1;
    mStretchActive = false;
    for (int hand = 0; hand < 2; ++hand) mCore->PulseHaptic(hand, 0.25f);
    mNotice = "Recentered";
    mRenderedMenuSelected = -1;
    SaveSceneIfChanged(true);
    Newt_Logf(NEWT_LOG_INFO, "Recentered (Meta button held)");
}



void NewtXR::RenderRecenterRing() {
    if (mRecenterRingStep < 0 || mRecenterRingStep == mRecenterRenderedStep) return;
    if (!mRecenterRingTexture.initialized) mCore->CreateTexture(mRecenterRingTexture, 256, 300);
    const int step = mRecenterRingStep;
    const bool done = step > kRecenterSteps;
    const CGFloat fraction = done ? 1.0 : CGFloat(step) / kRecenterSteps;
    mCore->UpdateTexture(mRecenterRingTexture, MakeImage(^(NSRect) {
        const NSPoint c = NSMakePoint(128, 118);
        FillRounded(NSMakeRect(28, 18, 200, 200), 100, RGB(0.05f, 0.06f, 0.08f, 0.72f));
        NSBezierPath* track = [NSBezierPath bezierPath];
        [track appendBezierPathWithArcWithCenter:c radius:78 startAngle:0 endAngle:360];
        track.lineWidth = 14;
        [RGB(1, 1, 1, 0.18f) setStroke];
        [track stroke];

        NSBezierPath* arc = [NSBezierPath bezierPath];
        [arc appendBezierPathWithArcWithCenter:c radius:78 startAngle:-90 endAngle:-90 + 360 * fraction clockwise:NO];
        arc.lineWidth = 14;
        arc.lineCapStyle = NSLineCapStyleRound;
        [(done ? RGB(0.45f, 0.85f, 0.72f) : RGB(0.95f, 0.96f, 0.98f)) setStroke];
        if (fraction > 0) [arc stroke];
        if (done) {
            NSBezierPath* check = [NSBezierPath bezierPath];
            [check moveToPoint:NSMakePoint(96, 120)];
            [check lineToPoint:NSMakePoint(119, 143)];
            [check lineToPoint:NSMakePoint(162, 96)];
            check.lineWidth = 14;
            check.lineCapStyle = NSLineCapStyleRound;
            check.lineJoinStyle = NSLineJoinStyleRound;
            [RGB(0.45f, 0.85f, 0.72f) setStroke];
            [check stroke];
        }
        DrawText(done ? @"Recentered" : @"Hold to recenter", NSMakeRect(0, 236, 256, 40), 26, YES,
                 RGB(0.95f, 0.96f, 0.98f), NSTextAlignmentCenter);
    }, 256, 300));
    mRecenterRenderedStep = step;
}


void NewtXR::DrawRecenterRing(const Newt::EyeFrame& eye) {
    if (mRecenterRingStep < 0 || !mRecenterRingTexture.initialized) return;
    VkClearAttachment depth{};
    depth.aspectMask = VK_IMAGE_ASPECT_DEPTH_BIT;
    depth.clearValue.depthStencil.depth = 1.0f;
    VkClearRect rect{};
    rect.rect.extent = {eye.width, eye.height};
    rect.layerCount = 1;
    vkCmdClearAttachments(eye.command, 1, &depth, 1, &rect);
    const Mat4 pose = Multiply(PoseMatrix(mViewerPose), Multiply(Translation({0, -0.04f, -0.7f}), Scale({0.16f, 0.1875f, 1})));
    mCore->DrawTextured(eye.command, eye.viewProjection, pose, mRecenterRingTexture);
}
