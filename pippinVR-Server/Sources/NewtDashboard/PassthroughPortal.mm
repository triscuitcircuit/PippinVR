// SPDX-License-Identifier: MIT
#include "NewtXRApp.h"
#include "NewtInternal.h"
#include "include/NewtLog.h"
#include "InteractionGeometry.h"
#include "HandBenchmark.h"
#include "AddonCameraBridge.h"
#import <CoreVideo/CoreVideo.h>
#include <algorithm>
#include <cmath>
#include <cstring>
#include <dlfcn.h>
#include <mach-o/dyld.h>
using namespace NewtInternal;

namespace {
float YawOf(const XrQuaternionf& q) {
    const Vec3 f = Rotate(q, Vec3{0, 0, -1});
    return std::atan2(-f.x, -f.z);
}
XrQuaternionf YawQuaternion(float yaw) { return {0, std::sin(yaw / 2), 0, std::cos(yaw / 2)}; }
Vec3 RotateYaw(float yaw, const Vec3& v) {
    const float c = std::cos(yaw), s = std::sin(yaw);
    return {c * v.x + s * v.z, v.y, -s * v.x + c * v.z};
}
float WrapAngle(float a) { return std::remainder(a, 2.0f * static_cast<float>(M_PI)); }
}

int NewtXR::PassthroughPanel() const {
    for (size_t p = 0; p < mPanels.size(); ++p)
        if (mPanels[p]->passthrough) return static_cast<int>(p);
    return -1;
}

bool NewtXR::PanelLocked(int index) const {
    return mPassthrough.locked && index >= 0 && index < static_cast<int>(mPanels.size()) &&
           mPanels[index]->passthrough;
}

void NewtXR::SetPassthroughLocked(bool locked) {
    mPassthrough.locked = locked;
    mFollowValid = false;
    if (const int portal = PassthroughPanel(); locked && portal >= 0) {
        if (mGrabbedPanel == portal) { mGrabbedPanel = -1; mGrabHand = -1; }
        if (mStretchPanel == portal) { mStretchActive = false; mStretchPanel = -1; }
        if (mActivePanel == portal) {
            mActivePanel = 0;
            for (int p = 0; p < static_cast<int>(mPanels.size()); ++p)
                if (!PanelLocked(p)) { mActivePanel = p; break; }
        }
    }
    mNotice = locked ? "Portal locked in place" : "Portal can be moved again";
}

bool NewtXR::ResolvePassthroughRuntime() {
    if (mPassthroughCopy && mPassthroughRequest) return true;
    for (uint32_t i = 0; i < _dyld_image_count(); ++i) {
        const char* name = _dyld_get_image_name(i);
        if (!name || !std::strstr(name, "libopenxr_monado")) continue;
        void* handle = dlopen(name, RTLD_LAZY | RTLD_LOCAL | RTLD_NOLOAD);
        if (!handle) continue;
        auto copy = reinterpret_cast<bool (*)(uint64_t*, void**, void**)>(dlsym(handle, "ql_passthrough_copy_latest"));
        auto request = reinterpret_cast<void (*)(bool)>(dlsym(handle, "ql_passthrough_set_requested"));
        if (copy && request) {
            mPassthroughRuntime = handle;
            mPassthroughCopy = copy;
            mPassthroughRequest = request;
            mPassthroughCamera = reinterpret_cast<bool (*)(int, PassthroughCamera*)>(
                dlsym(handle, "ql_passthrough_copy_camera"));
            mPassthroughCopyEx = reinterpret_cast<bool (*)(uint64_t*, void**, void**, int64_t*)>(
                dlsym(handle, "ql_passthrough_copy_latest_ex"));
            mHeadPoseAt = reinterpret_cast<bool (*)(int64_t, float*)>(dlsym(handle, "ql_passthrough_head_pose_at"));
            mHeadLatest = reinterpret_cast<bool (*)(int64_t*, float*, float*)>(dlsym(handle, "ql_passthrough_head_latest"));
            mHandJointsAt = reinterpret_cast<bool (*)(int, int64_t, float*)>(dlsym(handle, "ql_passthrough_hand_joints_at"));
            mCopyFloat = reinterpret_cast<bool (*)(int, uint64_t*, float*, int, int*, int*, int64_t*)>(
                dlsym(handle, "ql_passthrough_copy_float"));
            return true;
        }
        dlclose(handle);
    }
    return false;
}

void NewtXR::ReleasePassthroughRuntime() {
    if (mPassthroughRequest) mPassthroughRequest(false);
    if (mPassthroughRuntime) dlclose(mPassthroughRuntime);
    mPassthroughRuntime = nullptr;
    mPassthroughCopy = nullptr;
    mPassthroughRequest = nullptr;
    mPassthroughCamera = nullptr;
    mPassthroughCalibrated = false;
    mPassthroughCopyEx = nullptr;
    mHeadPoseAt = nullptr;
    mHeadLatest = nullptr;
    mHandJointsAt = nullptr;
    mCopyFloat = nullptr;
    mStereoRigRequested = false;
    mCaptureHeadValid = false;
    mStageFromRuntimeValid = false;
    mCameraLeft.reset();
    mCameraRight.reset();
    mCaptureNs = 0;
    mCameraReceivedAt = {};
    DropHandMask();
}

void NewtXR::UpdateCameraRequest() {
    const bool wanted = PassthroughPanel() >= 0 || CameraHandsActive() ||
                        (mPassthrough.allowed && HandBenchmarkNeedsFrames());
    if (ResolvePassthroughRuntime()) mPassthroughRequest(wanted);
    else if (wanted) Newt_Logf(NEWT_LOG_WARNING, "Passthrough: runtime camera interface not found");
    if (!wanted) {
        mCameraLeft.reset();
        mCameraRight.reset();
        mCaptureNs = 0;
        mCameraReceivedAt = {};
        DropHandMask();
    }
}

void NewtXR::RemovePanelAt(int index) {
    if (index < 0 || index >= static_cast<int>(mPanels.size())) return;
    CheckVk(vkDeviceWaitIdle(mCore->Device()), "remove panel");
    auto& panel = *mPanels[index];
    mCore->DestroyTexture(panel.texture);
    mCore->DestroyTexture(panel.badgeTexture);
    panel.gpuTexture.reset();
    panel.gpuTextureRight.reset();
    for (auto& b : panel.meshes) mCore->DestroyBuffer(b);
    for (auto& b : panel.lensMeshes) mCore->DestroyBuffer(b);
    mPanels.erase(mPanels.begin() + index);
    mActivePanel = 0;
    mGrabbedPanel = -1;
    mGrabHand = -1;
    mStretchActive = false;
    mStretchPanel = -1;
}

void NewtXR::SetPassthroughShown(bool shown) {
    const int index = PassthroughPanel();
    if (shown && !mPassthrough.allowed) {
        mPassthrough.enabled = false;
        mNotice = "Allow camera passthrough in PippinVR Settings on your Mac first";
        shown = false;
    }
    if (shown && index < 0) {
        if (mPanels.size() >= kMaxPanels) {
            mPassthrough.enabled = false;
            mNotice = std::to_string(kMaxPanels) + "-panel limit reached";
            mRenderedMenuSelected = -1;
            return;
        }
        auto panel = std::make_unique<Panel>();
        panel->passthrough = true;
        mCore->CreateTexture(panel->texture, LiveWidth(), LiveHeight());
        mCore->UpdateTexture(panel->texture, RenderPassthroughPlaceholder());
        if (mPassthrough.hasPose) {
            panel->pose.position = {mPassthrough.position[0], mPassthrough.position[1], mPassthrough.position[2]};
            panel->pose.orientation = {mPassthrough.orientation[0], mPassthrough.orientation[1],
                                       mPassthrough.orientation[2], mPassthrough.orientation[3]};
        } else {
            panel->pose.position = {0.0f, 1.1f, -1.6f};
        }
        mFollowValid = false;
        panel->width = mPassthrough.width;
        panel->height = mPassthrough.height;
        mPanels.push_back(std::move(panel));
        mPassthroughSeq = 0;
        mNotice = "Passthrough portal on";
    } else if (!shown && index >= 0) {
        StorePassthroughPlacement(*mPanels[index]);
        RemovePanelAt(index);
        mNotice = "Passthrough portal off";
    }
    mPassthrough.enabled = shown;
    UpdateCameraRequest();
    SavePassthroughSettings(mPassthrough);
    mRenderedMenuSelected = -1;
    mContentDirty = true;
}

void NewtXR::UpdatePassthroughPanel(Panel& panel) {
    if (std::fabs(panel.width - mPassthrough.width) > 0.005f || std::fabs(panel.height - mPassthrough.height) > 0.005f) {
        mPassthrough.width = panel.width;
        mPassthrough.height = panel.height;
        if (mMenuOpen && mPage == Page::Settings && mSettingsTab == 2) mContentDirty = true;
    }
    if (!mCameraLeft) {
        panel.gpuTexture.reset();
        panel.gpuTextureRight.reset();
        return;
    }
    panel.gpuTexture = mCameraLeft;
    panel.gpuWidth = mCameraWidth;
    panel.gpuHeight = mCameraHeight;
    if (mPassthrough.stereo && mCameraRight) {
        panel.gpuTextureRight = mCameraRight;
        panel.gpuRightWidth = mCameraWidth;
        panel.gpuRightHeight = mCameraHeight;
    } else {
        panel.gpuTextureRight.reset();
    }
}

bool NewtXR::FetchCameraFrames() {
    const auto now = std::chrono::steady_clock::now();
    if (mCameraLeft && now - mCameraReceivedAt > std::chrono::milliseconds(500)) {
        mCameraLeft.reset();
        mCameraRight.reset();
        mCaptureNs = 0;
        mCaptureHeadValid = false;
        DropHandMask();
        Newt_Logf(NEWT_LOG_WARNING, "Passthrough: no fresh camera pair for 500 ms; hiding stale image");
    }
    if (!ResolvePassthroughRuntime()) return false;
    void* left = nullptr;
    void* right = nullptr;
    int64_t captureNs = 0;
    const bool copied = mPassthroughCopyEx ? mPassthroughCopyEx(&mPassthroughSeq, &left, &right, &captureNs)
                                           : mPassthroughCopy(&mPassthroughSeq, &left, &right);
    if (!copied) return false;
    if (mPassthrough.allowed && PassthroughPanel() >= 0)
        SubmitAddonCameraFrames(static_cast<CVPixelBufferRef>(left), static_cast<CVPixelBufferRef>(right), captureNs);
    HandBenchmarkSubmit(static_cast<CVPixelBufferRef>(left), static_cast<CVPixelBufferRef>(right), captureNs);
    if (HandBenchmarkEnabled() && PassthroughPanel() < 0 && !CameraHandsActive()) {

        CVPixelBufferRelease(static_cast<CVPixelBufferRef>(left));
        CVPixelBufferRelease(static_cast<CVPixelBufferRef>(right));
        return true;
    }
    float head[7];
    mCaptureHeadValid = captureNs > 0 && mHeadPoseAt && mHeadPoseAt(captureNs, head);
    if (mCaptureHeadValid) mCaptureHead = {{head[3], head[4], head[5], head[6]}, {head[0], head[1], head[2]}};
    SubmitHandMask(static_cast<CVPixelBufferRef>(left), static_cast<CVPixelBufferRef>(right), captureNs);
    const bool wantRight = mPassthrough.stereo || CameraHandsActive();
    auto leftTexture = mCore->ImportPixelBuffer(static_cast<CVPixelBufferRef>(left));
    auto rightTexture = wantRight ? mCore->ImportPixelBuffer(static_cast<CVPixelBufferRef>(right)) : Newt::GPUTexture{};
    const uint32_t width = static_cast<uint32_t>(CVPixelBufferGetWidth(static_cast<CVPixelBufferRef>(left)));
    const uint32_t height = static_cast<uint32_t>(CVPixelBufferGetHeight(static_cast<CVPixelBufferRef>(left)));
    CVPixelBufferRelease(static_cast<CVPixelBufferRef>(left));
    CVPixelBufferRelease(static_cast<CVPixelBufferRef>(right));
    if (!leftTexture) return false;
    mCameraLeft = std::move(leftTexture);
    mCameraRight = std::move(rightTexture);
    mCameraWidth = width;
    mCameraHeight = height;
    mCaptureNs = captureNs;
    mCameraReceivedAt = now;
    if (!mPassthroughLogged) {
        Newt_Logf(NEWT_LOG_INFO, "Passthrough: first camera frames %ux%u (%s)", width, height,
                  mCameraRight ? "stereo" : "left camera");
        mPassthroughLogged = true;
    }
    return true;
}

void NewtXR::StorePassthroughPlacement(const Panel& panel) {
    mPassthrough.width = panel.width;
    mPassthrough.height = panel.height;
    mPassthrough.hasPose = true;
    mPassthrough.position[0] = panel.pose.position.x;
    mPassthrough.position[1] = panel.pose.position.y;
    mPassthrough.position[2] = panel.pose.position.z;
    mPassthrough.orientation[0] = panel.pose.orientation.x;
    mPassthrough.orientation[1] = panel.pose.orientation.y;
    mPassthrough.orientation[2] = panel.pose.orientation.z;
    mPassthrough.orientation[3] = panel.pose.orientation.w;
}


bool NewtXR::EnsurePassthroughCalibration() {
    if (mPassthroughCalibrated) return true;
    if (!mPassthroughCamera) return false;
    for (int eye = 0; eye < 2; ++eye) {
        mPassthroughCameras[eye] = PassthroughCamera{};
        if (!mPassthroughCamera(eye, &mPassthroughCameras[eye])) return false;
    }
    mPassthroughCalibrated = true;
    Newt_Logf(NEWT_LOG_INFO, "Passthrough lens: %s / %s, %dx%d; see-through window %s",
              mPassthroughCameras[0].projection_model, mPassthroughCameras[0].distortion_model,
              mPassthroughCameras[0].width, mPassthroughCameras[0].height,
              mCore->SupportsPassthroughWindow() ? "available" : "unavailable");
    return true;
}

void NewtXR::UpdatePassthroughLens(Panel& panel) {
    if (!EnsurePassthroughCalibration() || !mPassthrough.Corrected() || panel.lensFov == -2) return;
    const float aspect = panel.width / std::max(0.05f, panel.height);
    const bool built = panel.lensVertexCount > 0 && panel.lensFov == mPassthrough.fov &&
                       panel.lensDirection == mPassthrough.direction;
    if (built) {
        if (std::fabs(aspect - panel.lensAspect) <= 0.02f * aspect) {
            panel.lensAspectChanged = {};
            return;
        }
        const auto now = std::chrono::steady_clock::now();
        if (panel.lensAspectChanged.time_since_epoch().count() == 0) panel.lensAspectChanged = now;
        if (now - panel.lensAspectChanged < std::chrono::milliseconds(150)) return;
    }
    std::array<std::vector<VertexPC>, 2> meshes;
    for (int eye = 0; eye < 2; ++eye) {
        meshes[eye] = MakeLensCorrectedQuad(mPassthroughCameras[eye], mPassthrough.FovDegrees(), aspect,
                                            mPassthrough.PitchDownDegrees());
        if (meshes[eye].empty() || meshes[eye].size() != meshes[0].size()) {
            Newt_Logf(NEWT_LOG_WARNING, "Passthrough lens: unsupported camera model '%s'; showing the fisheye image",
                      mPassthroughCameras[eye].distortion_model);
            panel.lensFov = -2;
            panel.lensVertexCount = 0;
            return;
        }
    }
    CheckVk(vkDeviceWaitIdle(mCore->Device()), "passthrough lens mesh");
    const VkDeviceSize bytes = meshes[0].size() * sizeof(VertexPC);
    for (int eye = 0; eye < 2; ++eye) {
        if (panel.lensMeshes[eye].buffer == VK_NULL_HANDLE)
            panel.lensMeshes[eye] = mCore->CreateBuffer(bytes, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
        mCore->UploadBuffer(panel.lensMeshes[eye], meshes[eye].data(), bytes);
    }
    panel.lensVertexCount = static_cast<uint32_t>(meshes[0].size());
    panel.lensAspect = aspect;
    panel.lensFov = mPassthrough.fov;
    panel.lensDirection = mPassthrough.direction;
    panel.lensAspectChanged = {};
}





void NewtXR::UpdateStageFromRuntime(const Newt::InputState& input) {
    if (!mHeadLatest || !input.viewerValid) return;
    int64_t ns = 0;
    float pose[7], angularSpeed = 0;
    if (!mHeadLatest(&ns, pose, &angularSpeed) || angularSpeed > 0.15f) return;
    const XrPosef runtimeHead{{pose[3], pose[4], pose[5], pose[6]}, {pose[0], pose[1], pose[2]}};
    const XrPosef sample = ComposePose(input.viewer, InversePose(runtimeHead));
    if (!mStageFromRuntimeValid) {
        mStageFromRuntime = sample;
        mStageFromRuntimeValid = true;
        return;
    }
    XrQuaternionf q = sample.orientation, c = mStageFromRuntime.orientation;
    float dot = q.x * c.x + q.y * c.y + q.z * c.z + q.w * c.w;
    if (dot < 0) { q = {-q.x, -q.y, -q.z, -q.w}; dot = -dot; }
    const float dx = sample.position.x - mStageFromRuntime.position.x, dy = sample.position.y - mStageFromRuntime.position.y,
                dz = sample.position.z - mStageFromRuntime.position.z;
    if (std::sqrt(dx * dx + dy * dy + dz * dz) > 0.10f || dot < std::cos(5.0f * static_cast<float>(M_PI) / 360.0f)) {
        mStageFromRuntime = sample;
        return;
    }
    const float a = 0.05f;
    mStageFromRuntime.position = {mStageFromRuntime.position.x + dx * a, mStageFromRuntime.position.y + dy * a,
                                  mStageFromRuntime.position.z + dz * a};
    XrQuaternionf blended{c.x + (q.x - c.x) * a, c.y + (q.y - c.y) * a, c.z + (q.z - c.z) * a, c.w + (q.w - c.w) * a};
    const float n = std::sqrt(blended.x * blended.x + blended.y * blended.y + blended.z * blended.z + blended.w * blended.w);
    mStageFromRuntime.orientation = {blended.x / n, blended.y / n, blended.z / n, blended.w / n};
}

void NewtXR::UpdatePassthroughAnchor(const Newt::InputState& input) {
    if (input.viewerValid) { mLastViewer = input.viewer; mLastViewerValid = true; }
    if (PassthroughPanel() >= 0 || CameraHandsActive()) UpdateStageFromRuntime(input);
    const int index = PassthroughPanel();
    if (index < 0 || mPassthrough.anchor != 1 || mPassthrough.locked || !input.viewerValid) {
        mFollowValid = false;
        return;
    }
    Panel& panel = *mPanels[index];
    const auto now = std::chrono::steady_clock::now();
    const float dt = mFollowLast.time_since_epoch().count() == 0
        ? 0.0f : std::min(0.05f, std::chrono::duration<float>(now - mFollowLast).count());
    mFollowLast = now;
    const XrVector3f& head = input.viewer.position;
    const float headYaw = YawOf(input.viewer.orientation);
    const bool held = (mGrabHand >= 0 && mGrabbedPanel == index) || (mStretchActive && mStretchPanel == index);
    if (held || !mFollowValid) {
        mFollowOffset = RotateYaw(-headYaw, Vec3{panel.pose.position.x - head.x, panel.pose.position.y - head.y,
                                                 panel.pose.position.z - head.z});
        mFollowYaw = WrapAngle(YawOf(panel.pose.orientation) - headYaw);
        mFollowValid = true;
        mFollowMoving = false;
        return;
    }
    const Vec3 offset = RotateYaw(headYaw, mFollowOffset);
    const Vec3 target{head.x + offset.x, head.y + offset.y, head.z + offset.z};
    const Vec3 error{target.x - panel.pose.position.x, target.y - panel.pose.position.y,
                     target.z - panel.pose.position.z};
    const float distance = std::sqrt(error.x * error.x + error.y * error.y + error.z * error.z);
    const float yawError = WrapAngle(headYaw + mFollowYaw - YawOf(panel.pose.orientation));
    if (!mFollowMoving && (distance > 0.35f || std::fabs(yawError) > 25.0f * static_cast<float>(M_PI) / 180.0f))
        mFollowMoving = true;
    if (!mFollowMoving) return;
    const float t = std::clamp(dt * 4.0f, 0.0f, 1.0f);
    panel.pose.position.x += error.x * t;
    panel.pose.position.y += error.y * t;
    panel.pose.position.z += error.z * t;
    const float yaw = YawOf(panel.pose.orientation);
    const XrQuaternionf tilt = QuaternionProduct(YawQuaternion(-yaw), panel.pose.orientation);
    panel.pose.orientation = QuaternionProduct(YawQuaternion(yaw + yawError * t), tilt);
    if (distance < 0.02f && std::fabs(yawError) < 0.02f) mFollowMoving = false;
}


void NewtXR::DrawPassthroughFrame(VkCommandBuffer cmd, const Mat4& viewProj, const Panel& panel) {
    const Vec4 colors[4] = {{0.72f, 0.79f, 0.60f, 1}, {0.58f, 0.65f, 0.49f, 1},
                            {0.50f, 0.57f, 0.43f, 1}, {0.62f, 0.69f, 0.52f, 1}};
    DrawPassthroughEdges(cmd, viewProj, panel,
                         mPassthrough.SeeThrough() ? mPassthrough.shape : PassthroughSettings::kWholePortal, 0.06f,
                         -0.10f, 0.012f, colors);
}

void NewtXR::DrawPassthroughEdges(VkCommandBuffer cmd, const Mat4& viewProj, const Panel& panel, const float* quad,
                                  float border, float back, float front, const Vec4 colors[4]) {
    const float depth = front - back, z = (front + back) / 2;
    for (int i = 0; i < 4; ++i) {
        const int j = (i + 1) % 4;
        const float ax = quad[2 * i] * panel.width, ay = quad[2 * i + 1] * panel.height;
        const float bx = quad[2 * j] * panel.width, by = quad[2 * j + 1] * panel.height;
        const float dx = bx - ax, dy = by - ay, length = std::sqrt(dx * dx + dy * dy);
        if (length < 1e-4f) continue;
        const float nx = -dy / length, ny = dx / length;
        auto local = IdentityPose();
        local.position = {(ax + bx) / 2 + nx * border / 2, (ay + by) / 2 + ny * border / 2, z};
        const float angle = std::atan2(dy, dx);
        local.orientation = {0, 0, std::sin(angle / 2), std::cos(angle / 2)};
        mCore->DrawColor(cmd, viewProj,
                         Multiply(PoseMatrix(ComposePose(panel.pose, local)), Scale(Vec3{length + border, border, depth})),
                         mCubeBuffer, mCubeCount, colors[i], false);
    }
}

void NewtXR::PlacePassthroughForDirection(Panel& panel) {
    if (!mLastViewerValid) return;
    const float yaw = YawOf(mLastViewer.orientation);
    const bool desk = mPassthrough.direction == 1;
    const Vec3 forward = RotateYaw(yaw, Vec3{0, 0, desk ? -0.55f : -1.6f});
    panel.pose.position = {mLastViewer.position.x + forward.x, mLastViewer.position.y + (desk ? -0.45f : -0.3f),
                           mLastViewer.position.z + forward.z};
    const float tilt = desk ? -mPassthrough.kDeskPitchDegrees * static_cast<float>(M_PI) / 180.0f : 0.0f;
    const XrQuaternionf pitch{std::sin(tilt / 2), 0, 0, std::cos(tilt / 2)};
    panel.pose.orientation = QuaternionProduct(YawQuaternion(yaw), pitch);
    mFollowValid = false;
}

bool NewtXR::LensFor(int camera, Newt::Session::PassthroughLens& lens) const {
    const PassthroughCamera& c = mPassthroughCameras[camera];
    if (c.projection_count != 3 || c.distortion_count < 8) return false;
    lens.focal = static_cast<float>(c.projection[0]);
    lens.cx = static_cast<float>(c.projection[1]);
    lens.cy = static_cast<float>(c.projection[2]);
    lens.width = static_cast<float>(c.width);
    lens.height = static_cast<float>(c.height);
    for (int i = 0; i < 6; ++i) lens.k[i] = static_cast<float>(c.distortion[i]);
    lens.p[0] = static_cast<float>(c.distortion[6]);
    lens.p[1] = static_cast<float>(c.distortion[7]);
    return true;
}

void NewtXR::DrawPassthroughSeeThrough(VkCommandBuffer cmd, const Mat4& viewProj, const XrPosef& eyePose,
                                       const XrPosef& pose, const Panel& panel, int camera) {
    const Newt::GPUTexture& texture = camera == 1 && panel.gpuTextureRight ? panel.gpuTextureRight : panel.gpuTexture;
    const PassthroughCamera& c = mPassthroughCameras[camera];
    Newt::Session::PassthroughLens lens;
    if (!texture || !LensFor(camera, lens)) return;
    std::copy(mPassthrough.shape, mPassthrough.shape + 8, lens.cutout);
    (void)eyePose;
    const XrPosef head = mCaptureHeadValid && mStageFromRuntimeValid ? ComposePose(mStageFromRuntime, mCaptureHead)
                                                                     : mViewerPose;
    const Mat4 worldFromLocal = PoseMatrix(pose, {panel.width, panel.height, panel.width});
    const Mat4 cameraFromLocal =
        Multiply(CameraFromHead(c), Multiply(PoseMatrix(InversePose(head)), worldFromLocal));
    mCore->DrawPassthroughWindow(cmd, viewProj, worldFromLocal, cameraFromLocal, texture, lens, &panel.meshes[0],
                                 48 * 6);
}

void NewtXR::StartTracing() {
    if (!mPassthrough.allowed) {
        mNotice = "Allow camera passthrough in PippinVR Settings on your Mac first";
        mRenderedMenuSelected = -1;
        return;
    }
    mPassthrough.tracing = true;
    mTracePoints.clear();
    mTraceHand = -1;
    mTracePrevSelect = {true, true};
    mTracePrevGrip = {true, true};
    UpdateTracePrompt();
    mMenuOpen = false;
    mContentDirty = true;
    mRenderedMenuSelected = -1;
}

void NewtXR::StopTracing(const std::string& notice) {
    mPassthrough.tracing = false;
    mTracePoints.clear();
    mTraceHand = -1;
    mTraceCursorValid = {false, false};
    mTraceHold = {true, true};
    mNotice = notice;
    OpenPassthroughSettings();
}

void NewtXR::OpenPassthroughSettings() {
    mMenuOpen = true;
    mRecenterMenu = true;
    mSelected = 4;
    mPage = Page::Settings;
    mSettingsTab = 2;
    mGrabHand = -1; mGrabbedPanel = -1; mGrabbedModel = -1;
    mContentDirty = true;
    mRenderedMenuSelected = -1;
}

void NewtXR::UpdateTracePrompt(const char* lead) {
    const size_t next = mTracePoints.size() + 1;
    mTracePrompt = (lead ? std::string(lead) + " · " : std::string()) + "Corner " + std::to_string(next) +
                   " of 4\nTouch it with a controller tip and pull the trigger · grip: undo · menu: cancel";
}

void NewtXR::UpdateTracing(Newt::InputState& input) {
    if (!mPassthrough.tracing) {
        for (int hand = 0; hand < 2; ++hand) {
            if (!mTraceHold[hand]) continue;
            const bool grip = input.grab[hand].isActive && input.grab[hand].currentState > 0.7f;
            if (input.select[hand] || grip) {
                input.select[hand] = false;
                input.grab[hand].currentState = 0;
            } else {
                mTraceHold[hand] = false;
            }
        }
        return;
    }
    if (mMenuOpen) {
        StopTracing("Tracing cancelled");
        return;
    }
    const std::array<bool, 2> raw = input.select;
    for (int hand = 0; hand < 2; ++hand) {
        mTraceCursorValid[hand] = input.aimValid[hand];
        const auto& p = input.aim[hand].position;
        mTraceCursor[hand] = {p.x, p.y, p.z};
        if (raw[hand] && !mTracePrevSelect[hand] && input.aimValid[hand] && mTracePoints.size() < 4) {
            mTracePoints.push_back(mTraceCursor[hand]);
            mTraceHand = hand;
            mCore->PulseHaptic(hand);
            if (mTracePoints.size() < 4) UpdateTracePrompt("Placed");
        }
        const bool grip = input.grab[hand].isActive && input.grab[hand].currentState > 0.7f;
        if (grip && !mTracePrevGrip[hand] && !mTracePoints.empty()) {
            mTracePoints.pop_back();
            mCore->PulseHaptic(hand, 0.15f);
            UpdateTracePrompt("Undone");
        }
        mTracePrevGrip[hand] = grip;
        input.select[hand] = false;
        input.grab[hand].currentState = 0;
    }
    mTracePrevSelect = raw;
    if (mTracePoints.size() == 4) FinishTracing();
}

void NewtXR::FinishTracing() {
    TracedPortal traced;
    const Vec3 viewer{mViewerPose.position.x, mViewerPose.position.y, mViewerPose.position.z};
    if (!FitTracedPortal({mTracePoints[0], mTracePoints[1], mTracePoints[2], mTracePoints[3]}, viewer, traced)) {
        mTracePoints.clear();
        UpdateTracePrompt("Those corners don't make a surface, try again");
        return;
    }
    if (PassthroughPanel() < 0) SetPassthroughShown(true);
    const int index = PassthroughPanel();
    if (index < 0) { StopTracing(mNotice); return; }
    Panel& panel = *mPanels[index];
    panel.pose = traced.pose;
    panel.width = traced.width;
    panel.height = traced.height;
    panel.curvature = 0;
    std::copy(traced.shape, traced.shape + 8, mPassthrough.shape);
    mPassthrough.lensMode = 2;
    mPassthrough.anchor = 0;
    SetPassthroughLocked(true);
    mFollowValid = false;
    StorePassthroughPlacement(panel);
    SavePassthroughSettings(mPassthrough);
    Newt_Logf(NEWT_LOG_INFO, "Passthrough portal traced: %.2f x %.2f m, corners within %.1f cm of a plane",
              traced.width, traced.height, traced.flatness * 100);
    char notice[96];
    std::snprintf(notice, sizeof(notice), "Portal traced: %.0f × %.0f cm", traced.width * 100, traced.height * 100);
    StopTracing(notice);
}

void NewtXR::DrawWorldSegment(VkCommandBuffer cmd, const Mat4& viewProj, const Vec3& a, const Vec3& b, float thickness,
                              const Vec4& color) {
    const Vec3 d = b - a;
    const float length = std::sqrt(d.x * d.x + d.y * d.y + d.z * d.z);
    if (length < 1e-4f) return;
    const Vec3 dir = d * (1.0f / length);
    XrQuaternionf q{0, 0, 0, 1};
    const float c = dir.x;
    if (c < -0.9999f) {
        q = {0, 0, 1, 0};
    } else {
        const Vec3 axis{0, -dir.z, dir.y};
        const float s = std::sqrt((1 + c) * 2);
        q = {axis.x / s, axis.y / s, axis.z / s, s / 2};
    }
    XrPosef pose{q, {(a.x + b.x) / 2, (a.y + b.y) / 2, (a.z + b.z) / 2}};
    mCore->DrawColor(cmd, viewProj, Multiply(PoseMatrix(pose), Scale(Vec3{length, thickness, thickness})), mCubeBuffer,
                     mCubeCount, color, false);
}

void NewtXR::DrawTracing(VkCommandBuffer cmd, const Mat4& viewProj) {
    const Vec4 placed{0.30f, 0.85f, 0.65f, 1}, pending{0.95f, 0.68f, 0.20f, 1};
    auto cube = [&](const Vec3& p, float size, const Vec4& color) {
        XrPosef pose = IdentityPose();
        pose.position = {p.x, p.y, p.z};
        mCore->DrawColor(cmd, viewProj, Multiply(PoseMatrix(pose), Scale(Vec3{size, size, size})), mCubeBuffer,
                         mCubeCount, color, false);
    };
    for (size_t i = 0; i < mTracePoints.size(); ++i) {
        cube(mTracePoints[i], 0.03f, placed);
        if (i > 0) DrawWorldSegment(cmd, viewProj, mTracePoints[i - 1], mTracePoints[i], 0.006f, placed);
    }

    for (int hand = 0; hand < 2; ++hand) {
        if (!mTraceCursorValid[hand]) continue;
        cube(mTraceCursor[hand], 0.018f, pending);
        if (hand != mTraceHand || mTracePoints.empty()) continue;
        DrawWorldSegment(cmd, viewProj, mTracePoints.back(), mTraceCursor[hand], 0.003f, pending);
        if (mTracePoints.size() == 3) DrawWorldSegment(cmd, viewProj, mTraceCursor[hand], mTracePoints[0], 0.003f, pending);
    }
    if (mTraceTexture.initialized) {
        XrPosef prompt = mViewerPose;
        const Vec3 offset = Rotate(mViewerPose.orientation, Vec3{0, -0.14f, -0.75f});
        prompt.position = {prompt.position.x + offset.x, prompt.position.y + offset.y, prompt.position.z + offset.z};
        mCore->DrawTextured(cmd, viewProj, PoseMatrix(prompt, {0.46f, 0.46f * 240 / 1024, 1}), mTraceTexture);
    }
}
