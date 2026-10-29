// SPDX-License-Identifier: MIT


#include "NewtXRApp.h"
#include "NewtInternal.h"
#include "include/NewtLog.h"
#include "HandOcclusion.h"
#include "HandBenchmark.h"
#include "HandMask.h"
#include "HandStereo.h"
#include "InteractionGeometry.h"
#include <ctime>
#include <cstdio>
#include <string>
using namespace NewtInternal;

namespace {
constexpr int64_t kStaleFrameNs = 250 * 1000000LL;


constexpr int64_t kStaleMaskNs = 300 * 1000000LL;

constexpr float kCardMargin = 0.06f;
}

bool NewtXR::CameraHandsActive() const {
    return !HandBenchmarkEnabled() && mPassthrough.hands != 0 && mPassthrough.allowed && mCore && mCore->SupportsPassthroughWindow();
}

void NewtXR::SetCameraHands(int mode) {
    if (mode != 0 && !mPassthrough.allowed) {
        mNotice = "Allow camera passthrough in PippinVR Settings on your Mac first";
        mode = 0;
    } else if (mode != 0 && !mCore->SupportsPassthroughWindow()) {
        mNotice = "Camera hands aren't supported on this GPU";
        mode = 0;
    } else {
        mNotice = mode == 1 ? "Camera hands: outline · put the controllers down to see your hands"
                : mode == 3 ? "Camera hands: depth · put the controllers down to see your hands"
                : mode == 2 ? "Camera hands: tracked shape only" : "Camera hands off";
    }
    mPassthrough.hands = mode;
    SavePassthroughSettings(mPassthrough);
    DropHandMask();
    UpdateCameraRequest();
    mRenderedMenuSelected = -1;
    mContentDirty = true;
}


bool NewtXR::HandOutlineActive() const {
    return CameraHandsActive() && (mPassthrough.HandOutline() || mPassthrough.HandDepth());
}

namespace {
Vec3 Apply(const Mat4& m, const Vec3& p) {
    return {m.m[0] * p.x + m.m[4] * p.y + m.m[8] * p.z + m.m[12], m.m[1] * p.x + m.m[5] * p.y + m.m[9] * p.z + m.m[13],
            m.m[2] * p.x + m.m[6] * p.y + m.m[10] * p.z + m.m[14]};
}
bool JointsFromRaw(const float* raw, XrPosef* joints) {
    for (int j = 0; j < XR_HAND_JOINT_COUNT_EXT; ++j) {
        const float* p = raw + j * 7;
        joints[j] = {{p[3], p[4], p[5], p[6]}, {p[0], p[1], p[2]}};
    }
    return true;
}
}



void NewtXR::SubmitHandMask(CVPixelBufferRef left, CVPixelBufferRef right, int64_t captureNs) {
    if (!HandOutlineActive() || captureNs <= 0 || !mCaptureHeadValid || !mHandJointsAt ||
        !EnsurePassthroughCalibration()) return;
    if (mPassthrough.HandDepth()) {
        SubmitHandStereo(left, right, captureNs);
        return;
    }
    HandMaskInput input;
    bool any = false;
    for (int hand = 0; hand < 2; ++hand) {
        float raw[XR_HAND_JOINT_COUNT_EXT * 7];
        XrPosef joints[XR_HAND_JOINT_COUNT_EXT];
        const bool have = mHandJointsAt(hand, captureNs, raw) && JointsFromRaw(raw, joints);

        std::vector<Vec3> samples;
        if (have) {
            for (const auto& joint : joints) samples.push_back(hand_detail::Position(joint));
            for (const auto& bone : hand_detail::kSegments) {
                if (bone.b < 0) continue;
                const Vec3 a = hand_detail::Position(joints[bone.a]), b = hand_detail::Position(joints[bone.b]);
                samples.push_back(a + (b - a) * (1.0f / 3));
                samples.push_back(a + (b - a) * (2.0f / 3));
            }
        }
        for (int camera = 0; camera < 2; ++camera) {
            auto& points = input.hands[camera].emplace_back();
            const PassthroughCamera& c = mPassthroughCameras[camera];
            const LensModel model = LensModelOf(c);
            const Mat4 cameraFromWorld = Multiply(CameraFromHead(c), PoseMatrix(InversePose(mCaptureHead)));
            for (const Vec3& world : samples) {
                const Vec3 p = Apply(cameraFromWorld, world);
                double px, py;
                if (LensProject(c, model, p.x, p.y, p.z, px, py)) points.push_back({px / c.width, py / c.height});
            }
            any = any || !points.empty();
        }
    }
    if (any) HandMaskSubmit(left, right, captureNs, input);
}



void NewtXR::UpdateHandMask() {
    if (!HandOutlineActive()) return;
    HandMaskOutput out;
    if (!(mPassthrough.HandDepth() ? HandStereoCopyLatest(mHandMaskSequence, out)
                                   : HandMaskCopyLatest(mHandMaskSequence, out))) return;
    if (out.captureNs <= 0) return;
    for (int camera = 0; camera < 2; ++camera) {
        mHandMaskTexture[camera] = out.cutout[camera] ? mCore->ImportPixelBuffer(out.cutout[camera]) : Newt::GPUTexture{};
        if (out.cutout[camera]) CVPixelBufferRelease(out.cutout[camera]);
        for (int hand = 0; hand < 2; ++hand) mHandMaskFound[camera][hand] = out.hand[camera][hand] && mHandMaskTexture[camera];
    }
    mHandMaskNs = out.captureNs;
    const int64_t nowNs = static_cast<int64_t>(clock_gettime_nsec_np(CLOCK_MONOTONIC));

    if (mPassthrough.HandDepth() && mHandStereoLogs < 24 && nowNs - mHandStereoLogNs > 5000000000LL) {
        mHandStereoLogNs = nowNs;
        ++mHandStereoLogs;
        auto hand = [&](int camera, int h) {
            static thread_local char text[64];
            if (out.jointsOnMask[camera][h] < 0) std::snprintf(text, sizeof text, "not in view");
            else std::snprintf(text, sizeof text, "%d joints, %.0f%% on mask", out.jointsInView[camera][h],
                               100 * out.jointsOnMask[camera][h]);
            return std::string(text);
        };
        Newt_Logf(NEWT_LOG_INFO, "Hand stereo: %.1f ms (GPU %.1f ms), %.0f ms after capture, depth %.2f-%.2f m | left camera: "
                  "left hand %s, right hand %s | right camera: left hand %s, right hand %s",
                  out.workMs, out.gpuMs, (nowNs - out.captureNs) / 1e6, out.zNear, out.zFar, hand(0, 0).c_str(), hand(0, 1).c_str(),
                  hand(1, 0).c_str(), hand(1, 1).c_str());
    }
    float head[7], raw[XR_HAND_JOINT_COUNT_EXT * 7];
    mHandMaskHeadValid = out.captureNs > 0 && mHeadPoseAt && mHeadPoseAt(out.captureNs, head);
    if (mHandMaskHeadValid) mHandMaskHead = {{head[3], head[4], head[5], head[6]}, {head[0], head[1], head[2]}};
    for (int hand = 0; hand < 2; ++hand)
        mHandMaskJointsValid[hand] = out.captureNs > 0 && mHandJointsAt && mHandJointsAt(hand, out.captureNs, raw) &&
                                     JointsFromRaw(raw, mHandMaskJoints[hand].data());
    if (!mHandMaskLogged && (mHandMaskFound[0][0] || mHandMaskFound[0][1] || mHandMaskFound[1][0] || mHandMaskFound[1][1])) {
        Newt_Logf(NEWT_LOG_INFO, "Camera hands: first outlined hand (%.0f ms after capture)",
                  (static_cast<int64_t>(clock_gettime_nsec_np(CLOCK_MONOTONIC)) - out.captureNs) / 1e6);
        mHandMaskLogged = true;
    }
}




void NewtXR::SubmitHandStereo(CVPixelBufferRef leftFrame, CVPixelBufferRef rightFrame, int64_t captureNs) {
    if (!mStereoRigRequested) {
        mStereoRigRequested = true;
        const PassthroughCamera left = mPassthroughCameras[0], right = mPassthroughCameras[1];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            auto rig = stereo::BuildRig(left, right);
            if (!rig) Newt_Logf(NEWT_LOG_WARNING, "Camera hands: stereo depth unavailable for this calibration");
            HandStereoConfigure(rig);
        });
    }
    if (!HandStereoConfigured()) return;
    if (!mHandStereoReadyLogged) {
        mHandStereoReadyLogged = true;
        Newt_Logf(NEWT_LOG_INFO, "Camera hands: stereo depth ready");
    }
    const XrPosef headFromWorld = InversePose(mCaptureHead);
    HandStereoInput input;
    bool any = false;
    for (int hand = 0; hand < 2; ++hand) {
        float raw[XR_HAND_JOINT_COUNT_EXT * 7];
        if (!mHandJointsAt(hand, captureNs, raw)) continue;
        for (int j = 0; j < XR_HAND_JOINT_COUNT_EXT; ++j) {
            const Vec3 p = Rotate(headFromWorld.orientation, Vec3{raw[j * 7], raw[j * 7 + 1], raw[j * 7 + 2]});
            input.joints[hand].push_back({p.x + headFromWorld.position.x, p.y + headFromWorld.position.y,
                                          p.z + headFromWorld.position.z});
        }
        any = true;
    }
    if (any) HandStereoSubmit(leftFrame, rightFrame, captureNs, input);
}

void NewtXR::DropHandMask() {
    HandMaskReset();
    HandStereoReset();
    for (auto& texture : mHandMaskTexture) texture.reset();
    for (auto& found : mHandMaskFound) found[0] = found[1] = false;
    mHandMaskNs = 0;
}

void NewtXR::DrawCameraHands(VkCommandBuffer cmd, const Mat4& viewProj, int camera) {
    if (!CameraHandsActive() || mHandTubeCount == 0 || (!mHandJointsValid[0] && !mHandJointsValid[1])) return;
    if (!EnsurePassthroughCalibration()) return;
    Newt::Session::PassthroughLens lens;
    if (!LensFor(camera, lens)) return;
    const float everywhere[8] = {-1e4f, 1e4f, 1e4f, 1e4f, 1e4f, -1e4f, -1e4f, -1e4f};
    std::copy(everywhere, everywhere + 8, lens.cutout);
    lens.discardOutside = true;
    const int64_t now = static_cast<int64_t>(clock_gettime_nsec_np(CLOCK_MONOTONIC));
    const Newt::GPUTexture& live = camera == 1 && mCameraRight ? mCameraRight : mCameraLeft;
    const bool liveFresh = live && !(mCaptureNs > 0 && now - mCaptureNs > kStaleFrameNs);
    const bool maskFresh = HandOutlineActive() && mHandMaskTexture[camera] && mHandMaskHeadValid &&
                           now - mHandMaskNs < kStaleMaskNs;
    const Mat4 cameraFromHead = CameraFromHead(mPassthroughCameras[camera]);
    HandPiece current[kMaxHandPieces], then[kMaxHandPieces];
    for (int hand = 0; hand < 2; ++hand) {
        if (!mHandJointsValid[hand]) continue;
        const float scale = HandScale(mHandJoints[hand].data());

        const bool outlined = maskFresh && mHandMaskFound[camera][hand] && mHandMaskJointsValid[hand];
        const float pieceScale = scale;
        const Newt::GPUTexture& texture = outlined ? mHandMaskTexture[camera] : live;
        if (!outlined && (HandOutlineActive() || !liveFresh)) continue;
        if (outlined) {


            Mat4 worldFromCard;
            if (!HandCard(mHandJoints[hand].data(), hand_detail::Position(mViewerPose), kCardMargin, worldFromCard))
                continue;
            const XrPosef& palmNow = mHandJoints[hand][XR_HAND_JOINT_PALM_EXT];
            const XrPosef& palmThen = mHandMaskJoints[hand][XR_HAND_JOINT_PALM_EXT];
            const Mat4 thenFromNow = Multiply(PoseMatrix(palmThen), PoseMatrix(InversePose(palmNow)));
            const Mat4 cameraFromLocal = Multiply(Multiply(cameraFromHead, PoseMatrix(InversePose(mHandMaskHead))),
                                                  Multiply(thenFromNow, worldFromCard));
            mCore->DrawPassthroughWindow(cmd, viewProj, worldFromCard, cameraFromLocal, texture, lens);
            continue;
        }
        const int count = BuildHandPieces(mHandJoints[hand].data(), pieceScale, current);

        float raw[XR_HAND_JOINT_COUNT_EXT * 7];
        XrPosef joints[XR_HAND_JOINT_COUNT_EXT];
        const XrPosef* capturedJoints = nullptr;
        XrPosef captureHead = mCaptureHead;
        if (outlined) {
            capturedJoints = mHandMaskJoints[hand].data();
            captureHead = mHandMaskHead;
        } else if (mCaptureNs > 0 && mCaptureHeadValid && mHandJointsAt && mHandJointsAt(hand, mCaptureNs, raw) &&
                   JointsFromRaw(raw, joints)) {
            capturedJoints = joints;
        }
        Mat4 cameraFromWorld;
        if (capturedJoints) {
            BuildHandPieces(capturedJoints, pieceScale, then);
            cameraFromWorld = Multiply(cameraFromHead, PoseMatrix(InversePose(captureHead)));
        } else {

            const XrPosef head = mCaptureHeadValid && mStageFromRuntimeValid ? ComposePose(mStageFromRuntime, mCaptureHead)
                                                                             : mViewerPose;
            cameraFromWorld = Multiply(cameraFromHead, PoseMatrix(InversePose(head)));
        }
        if (!mCameraHandsLogged) {
            Newt_Logf(NEWT_LOG_INFO, "Camera hands: textured from %s", capturedJoints ? "capture-time hand poses"
                                                                                     : "current hand poses (no hand history)");
            mCameraHandsLogged = true;
        }
        for (int k = 0; k < count; ++k) {
            const Mat4 cameraFromLocal = Multiply(cameraFromWorld, (capturedJoints ? then[k] : current[k]).worldFromLocal);
            mCore->DrawPassthroughWindow(cmd, viewProj, current[k].worldFromLocal, cameraFromLocal, texture, lens,
                                         current[k].sphere ? &mHandBall : &mHandTube,
                                         current[k].sphere ? mHandBallCount : mHandTubeCount);
        }
    }
}
