// SPDX-License-Identifier: MIT


#include "NewtXRApp.h"
#include "NewtInternal.h"
#include "HandBenchmark.h"
using namespace NewtInternal;

void NewtXR::UpdateHandBenchmarkOverlay() {
    if (!HandBenchmarkEnabled()) return;
    CVPixelBufferRef left = nullptr, right = nullptr;
    std::string status;
    if (!HandBenchmarkCopyPreview(mHandBenchmarkPreviewSequence, left, right, status)) return;
    CVPixelBufferRef buffers[2] = {left, right};
    for (int i = 0; i < 2; ++i) {
        if (buffers[i]) {
            mHandBenchmarkImages[i] = mCore->ImportPixelBuffer(buffers[i]);
            mHandBenchmarkAspect[i] = float(CVPixelBufferGetWidth(buffers[i])) /
                                     std::max(1.0f, float(CVPixelBufferGetHeight(buffers[i])));
            CVPixelBufferRelease(buffers[i]);
            if (!mHandBenchmarkImages[i]) status += " Headset image import failed; check the Mac preview.";
        } else {
            mHandBenchmarkImages[i].reset();
        }
    }
    if (!mHandBenchmarkStatus.initialized) mCore->CreateTexture(mHandBenchmarkStatus, 1024, 240);
    NSString* detail = [NSString stringWithUTF8String:status.c_str()];
    mCore->UpdateTexture(mHandBenchmarkStatus, MakeImage(^(NSRect bounds) {
        FillRounded(bounds, 22, RGB(0.035f, 0.05f, 0.07f, 0.98f));
        DrawText(@"HAND BENCHMARK  ·  LEFT CAMERA / RIGHT CAMERA", NSMakeRect(24, 14, 976, 42),
                 28, YES, RGB(0.65f, 0.95f, 0.82f), NSTextAlignmentCenter);
        DrawText(detail, NSMakeRect(30, 66, 964, 118), 26, NO, RGB(0.95f, 0.95f, 0.95f), NSTextAlignmentCenter);
        DrawText(@"Camera preview · green marks selected regions · 2 updates/sec · not depth occlusion",
                 NSMakeRect(24, 198, 976, 28), 18, NO, RGB(0.73f, 0.79f, 0.83f), NSTextAlignmentCenter);
    }, 1024, 240));
}

void NewtXR::DrawHandBenchmarkOverlay(const Newt::EyeFrame& eye) {
    if (!HandBenchmarkEnabled() || !mHandBenchmarkStatus.initialized) return;


    VkClearAttachment depth{};
    depth.aspectMask = VK_IMAGE_ASPECT_DEPTH_BIT;
    depth.clearValue.depthStencil.depth = 1.0f;
    VkClearRect rect{};
    rect.rect.extent = {eye.width, eye.height};
    rect.layerCount = 1;
    vkCmdClearAttachments(eye.command, 1, &depth, 1, &rect);
    const Mat4 head = PoseMatrix(mViewerPose);
    for (int i = 0; i < 2; ++i) {
        if (!mHandBenchmarkImages[i]) continue;
        const float x = i == 0 ? -0.32f : 0.32f;
        const Mat4 pose = Multiply(head, Multiply(Translation({x, 0.12f, -1.0f}),
            Scale({0.62f, 0.62f / mHandBenchmarkAspect[i], 1.0f})));


        mCore->DrawGPUTexture(eye.command, eye.viewProjection, pose, mHandBenchmarkImages[i]);
    }
    mCore->DrawTextured(eye.command, eye.viewProjection,
        Multiply(head, Multiply(Translation({0, -0.30f, -0.99f}), Scale({1.28f, 0.30f, 1}))),
        mHandBenchmarkStatus);
}
