#include "NewtXRApp.h"
#include "InteractionGeometry.h"
#include "Metrics.h"
#include "HandBenchmark.h"
#include "StereoLayout.h"
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <fstream>
#include <filesystem>
#include <sstream>
#include "SpatialVideoOutput.h"
#include "Newt/CaptureInternal.h"
#include "include/NewtLog.h"

void NewtXR::OnPrepareFrame(const XrFrameState& frameState) {
    if (HandBenchmarkEnabled()) HandBenchmarkRenderFrame(frameState.shouldRender);
    const auto prepareNow = std::chrono::steady_clock::now();
    mFrameBudgetMs = static_cast<float>(frameState.predictedDisplayPeriod / 1e6);
    if (mHaveLastPrepareStart) {
        mLastPeriodMs = std::chrono::duration<float, std::milli>(prepareNow - mLastPrepareStart).count();
    }
    mLastPrepareStart = prepareNow;
    mPrepareStart = prepareNow;
    mHaveLastPrepareStart = true;
    const float orbitElapsed = std::chrono::duration<float>(prepareNow - mDemoOrbitStarted).count();
    for (size_t index = 0; index < mPanels.size(); ++index) {
        auto& panel = *mPanels[index];
        if (panel.demoOrbitIndex < 0 || int(index) == mGrabbedPanel || int(index) == mStretchPanel) continue;
        const float angle = mDemoOrbitHeading + float(panel.demoOrbitIndex % 9) * (2.0f * 3.14159265358979323846f / 9.0f) + orbitElapsed * (3.14159265358979323846f / 90.0f);
        const float dx = std::sin(angle) * 1.65f, dz = -std::cos(angle) * 1.65f;
        panel.pose.position = {mDemoOrbitCenter.x + dx, mDemoOrbitCenter.y + 0.25f - float(panel.demoOrbitIndex / 9) * 0.55f, mDemoOrbitCenter.z + dz};
        const float yaw = std::atan2(-dx, -dz);
        panel.pose.orientation = {0, std::sin(yaw * 0.5f), 0, std::cos(yaw * 0.5f)};
    }
    for(auto& panel:mPanels) if(panel->curvature!=panel->builtCurvature) {
        CheckVk(vkDeviceWaitIdle(mCore->Device()),"screen mesh update");
        for(int mode=0;mode<6;++mode) {
            auto vertices=mode==5?MakePanelBar(panel->curvature):MakeScreen(panel->curvature,mode);
            if(panel->meshes[mode].buffer==VK_NULL_HANDLE) panel->meshes[mode]=mCore->CreateBuffer(vertices.size()*sizeof(VertexPC),VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
            mCore->UploadBuffer(panel->meshes[mode],vertices.data(),vertices.size()*sizeof(VertexPC));
        }
        panel->builtCurvature=panel->curvature;
    }
    for(auto& panel:mPanels) if(panel->passthrough) UpdatePassthroughLens(*panel);
    PruneAlerts();
    PruneCustomPanels();
    PollAddonModels();
    AnimateAddonModels();
    SaveSceneIfChanged();
    mCore->BeginUploads();
    UpdateHandBenchmarkOverlay();
    if (mMenuOpen && prepareNow - mBatteryPoll >= std::chrono::seconds(2)) {
        mBatteryPoll = prepareNow;
        if (!mControllerBatteryPercent) {
            for (uint32_t i = 0; i < _dyld_image_count(); ++i) {
                const char* name = _dyld_get_image_name(i);
                if (!name || !std::strstr(name, "libopenxr_monado")) continue;
                void* handle = dlopen(name, RTLD_LAZY | RTLD_LOCAL | RTLD_NOLOAD);
                if (!handle) continue;
                auto fn = reinterpret_cast<int (*)(int)>(dlsym(handle, "ql_controller_battery_percent"));
                if (fn) { mBatteryRuntime = handle; mControllerBatteryPercent = fn; break; }
                dlclose(handle);
            }
        }
        for (int hand = 0; hand < 2; ++hand) {
            const int battery = mControllerBatteryPercent ? mControllerBatteryPercent(hand) : -1;
            if (battery != mControllerBattery[hand]) {
                mControllerBattery[hand] = battery;
                mRenderedMenuSelected = -1;
            }
        }
    }
    if (mSelected != mRenderedMenuSelected) {
        mCore->UpdateTexture(mMenuTexture, RenderMenu(mSelected, mNotice.c_str(), false, mControllerBattery[0], mControllerBattery[1]));
        for(int i=0;i<9;++i) mCore->UpdateTexture(mButtonTextures[i],RenderDockButton(i,i==mSelected));
        mRenderedMenuSelected = mSelected;
    }

    auto updateBadgeIfNeeded = [&](Panel& panel, const std::string& label) {
        if (panel.badgeLabel != label || !panel.badgeTexture.initialized) {
            if (!panel.badgeTexture.initialized) mCore->CreateTexture(panel.badgeTexture);
            NSString* text = [NSString stringWithUTF8String:label.c_str()];
            auto badge = MakeImage(^(NSRect) {
                FillRounded(NSMakeRect(24,18,460,38),10,RGB(0.05f,0.07f,0.09f,0.78f));
                DrawText(text,NSMakeRect(38,24,432,26),18,YES,RGB(0.48f,0.88f,0.78f));
            });
            mCore->UpdateTexture(panel.badgeTexture, badge);
            panel.badgeLabel = label;
        }
    };


    if (frameState.shouldRender) {
        if (PassthroughPanel() >= 0 || CameraHandsActive() || HandBenchmarkNeedsFrames()) FetchCameraFrames();
        UpdateHandMask();
        ProbeFloatDepth();
        for (auto& panel : mPanels) {
            if (panel->passthrough) { UpdatePassthroughPanel(*panel); continue; }
            RetainedObject pixels;
            RetainedObject pixelsRight;
            std::string label;
            int autoStereoMode = 0;
            if (panel->screen && panel->screen->GetLatestPixelBuffer(panel->sequence, pixels, label)) {
                auto buffer = static_cast<CVPixelBufferRef>(pixels.get());
                auto texture = mCore->ImportPixelBuffer(buffer);
                if (texture) {
                    panel->gpuTexture = std::move(texture);
                    panel->gpuTextureRight.reset();
                    panel->gpuWidth = static_cast<uint32_t>(CVPixelBufferGetWidth(buffer));
                    panel->gpuHeight = static_cast<uint32_t>(CVPixelBufferGetHeight(buffer));
                    panel->gpuRightWidth = 0;
                    panel->gpuRightHeight = 0;
                    if (!panel->gpuPathLogged) {
                        Newt_Logf(NEWT_LOG_INFO, "Desktop GPU capture active (IOSurface, no CPU pixel copy)");
                        panel->gpuPathLogged = true;
                    }
                    updateBadgeIfNeeded(*panel, label);
                    continue;
                }
                panel->gpuTexture.reset();
                panel->gpuTextureRight.reset();
                mCore->UpdateTexture(panel->texture, NewtCaptureInternal::PixelImageFromCVPixelBuffer(buffer, ScreenCaptureBadgeVisible() ? label : ""));
            } else if (panel->camera &&
                       GetLatestMediaPixelBuffers(panel->camera.get(),
                                                  panel->sequence,
                                                  pixels,
                                                  pixelsRight,
                                                  label,
                                                  autoStereoMode)) {
                auto leftBuf = static_cast<CVPixelBufferRef>(pixels.get());
                auto leftTex = mCore->ImportPixelBuffer(leftBuf);
                if (leftTex) {
                    panel->gpuTexture = std::move(leftTex);
                    panel->gpuWidth = static_cast<uint32_t>(CVPixelBufferGetWidth(leftBuf));
                    panel->gpuHeight = static_cast<uint32_t>(CVPixelBufferGetHeight(leftBuf));
                    if (pixelsRight) {
                        auto rightBuf = static_cast<CVPixelBufferRef>(pixelsRight.get());
                        auto rightTex = mCore->ImportPixelBuffer(rightBuf);
                        if (rightTex) {
                            panel->gpuTextureRight = std::move(rightTex);
                            panel->gpuRightWidth = static_cast<uint32_t>(CVPixelBufferGetWidth(rightBuf));
                            panel->gpuRightHeight = static_cast<uint32_t>(CVPixelBufferGetHeight(rightBuf));
                        } else {
                            panel->gpuTextureRight.reset();
                        }
                    } else {
                        panel->gpuTextureRight.reset();
                    }
                    if (autoStereoMode > 0 && panel->stereoMode == 0) {
                        panel->stereoMode = autoStereoMode;
                    }
                    if (!panel->gpuPathLogged) {
                        Newt_Logf(NEWT_LOG_INFO, "Media GPU capture active (IOSurface%s)",
                                  panel->gpuTextureRight ? ", MV-HEVC Stereoscopic" : "");
                        panel->gpuPathLogged = true;
                    }
                    updateBadgeIfNeeded(*panel, label);
                    continue;
                }
                panel->gpuTexture.reset();
                panel->gpuTextureRight.reset();
                mCore->UpdateTexture(panel->texture, NewtCaptureInternal::PixelImageFromCVPixelBuffer(leftBuf, label));
            } else {
                PixelImage image;
                if (panel->Source().GetLatestFrame(panel->sequence, image)) {
                    panel->gpuTexture.reset();
                    panel->gpuTextureRight.reset();
                    mCore->UpdateTexture(panel->texture, image);
                }
            }
        }
    }
    if (!mMenuOpen && mModelPopupModel >= 0 && mModelPopupModel < static_cast<int>(mModels.size())) {
        const auto& popupModel = *mModels[mModelPopupModel];
        const float roundedScale = std::round(popupModel.scale * 100.0f) * 0.01f;
        if (mRenderedModelPopupModel != mModelPopupModel ||
            mRenderedModelPopupButton != mModelPopupHoveredButton ||
            mRenderedModelPopupScale != roundedScale ||
            mRenderedModelPopupInFront != popupModel.inFront) {
            mCore->UpdateTexture(mModelPopupTexture,
                                 RenderModelPopup(mModelPopupHoveredButton, popupModel.scale, popupModel.inFront));
            mRenderedModelPopupModel = mModelPopupModel;
            mRenderedModelPopupButton = mModelPopupHoveredButton;
            mRenderedModelPopupScale = roundedScale;
            mRenderedModelPopupInFront = popupModel.inFront;
        }
    }
    if (mContentDirty || mPage != mRenderedPage) {
        mCore->UpdateTexture(mContentTexture, RenderContent(mPage,mGridColor,mMediaVolume,mApps,mClockSettings,mSettingsTab,mPassthrough,mAudio.mode));
        mRenderedPage = mPage;
        mContentDirty = false;
    }
    RenderAlerts();
    RenderCustomPanels();
    RenderRecenterRing();
    if (mPassthrough.tracing && mTracePrompt != mTraceRenderedPrompt) {
        if (!mTraceTexture.initialized) mCore->CreateTexture(mTraceTexture, 1024, 240);
        const auto split = mTracePrompt.find('\n');
        mCore->UpdateTexture(mTraceTexture, RenderTracePrompt(
            [NSString stringWithUTF8String:mTracePrompt.substr(0, split).c_str()],
            [NSString stringWithUTF8String:split == std::string::npos ? "" : mTracePrompt.substr(split + 1).c_str()],
            static_cast<int>(mTracePoints.size())));
        mTraceRenderedPrompt = mTracePrompt;
    }

    if (mClockHand >= 0 && (mLastClockUpdate.time_since_epoch().count() == 0 ||
        std::chrono::duration<float>(prepareNow - mLastClockUpdate).count() >= 1.0f)) {
        mLastClockUpdate = prepareNow;
        NSString* text = WristClockText(mClockSettings);
        if (mClockRenderedText != text.UTF8String) {
            mClockRenderedText = text.UTF8String;
            mCore->UpdateTexture(mWristClockTexture, RenderWristClock(text, mClockSettings));
        }
    }

    if (mShowMetrics && (mLastMetricsUpdate.time_since_epoch().count() == 0 ||
        std::chrono::duration<float>(prepareNow - mLastMetricsUpdate).count() >= 0.25f)) {
        mLastMetricsUpdate = prepareNow;
        PollQuestLinkMetrics();
        mCore->UpdateTexture(mMetricsTexture, RenderMetricsGraph(MakeMetricsSnapshot()));
    }
    mCore->FlushUploads();
    if (frameState.shouldRender) {
        mLastPrepareMs = std::chrono::duration<float, std::milli>(
            std::chrono::steady_clock::now() - mPrepareStart).count();
        PushMetricSample();
    }
}

void NewtXR::PushMetricSample() {
    mMetricsFramesPrepared++;
    if (mLastPeriodMs <= 0) return;
    const auto now = std::chrono::steady_clock::now();
    if (mMetricBucketStart.time_since_epoch().count() == 0) mMetricBucketStart = now;
    mMetricPeriodSum += mLastPeriodMs;
    mMetricDrawSum += mLastDrawMs;
    mMetricPrepareSum += mLastPrepareMs;
    mMetricBucketCount++;
    if (std::chrono::duration<float>(now - mMetricBucketStart).count() < 0.25f) return;
    mAveragePeriodMs = mMetricPeriodSum / mMetricBucketCount;
    mAverageDrawMs = mMetricDrawSum / mMetricBucketCount;
    mAveragePrepareMs = mMetricPrepareSum / mMetricBucketCount;
    mMetricTimeHistory[mMetricHistoryNext] = std::chrono::duration<double>(now.time_since_epoch()).count();
    mMetricPeriodHistory[mMetricHistoryNext] = mAveragePeriodMs;
    mMetricDrawHistory[mMetricHistoryNext] = mAverageDrawMs;
    const bool encodeLive = mLatestEncodeTime.time_since_epoch().count() != 0 &&
        std::chrono::duration<float>(now - mLatestEncodeTime).count() < 5.0f;
    mMetricEncodeHistory[mMetricHistoryNext] = encodeLive ? mLatestEncodeStageMs : -1.0f;
    mMetricHistoryNext = (mMetricHistoryNext + 1) % mMetricPeriodHistory.size();
    if (mMetricHistoryCount < mMetricPeriodHistory.size()) mMetricHistoryCount++;
    mMetricBucketStart = now;
    mMetricBucketCount = 0;
    mMetricPeriodSum = mMetricDrawSum = mMetricPrepareSum = 0;
}

void NewtXR::PollQuestLinkMetrics() {
    if (mMetricsFilePath.empty()) return;
    std::ifstream in(mMetricsFilePath, std::ios::binary);
    if (!in) return;
    in.seekg(0, std::ios::end);
    const auto end = in.tellg();
    if (end < 0) return;
    const uint64_t size = static_cast<uint64_t>(end);
    if (!mMetricsFilePrimed) {

        mMetricsFileOffset = size;
        mMetricsFilePrimed = true;
        return;
    }
    if (mMetricsFileOffset > size) {
        mMetricsFileOffset = 0;
        mMetricsPartialLine.clear();
    }
    if (mMetricsFileOffset == size) return;

    if (size - mMetricsFileOffset > 64 * 1024) {
        mMetricsFileOffset = size - 64 * 1024;
        mMetricsPartialLine.clear();
        in.seekg(static_cast<std::streamoff>(mMetricsFileOffset));
        std::string discarded;
        std::getline(in, discarded);
        const auto offset = in.tellg();
        if (offset < 0) { mMetricsFileOffset = size; return; }
        mMetricsFileOffset = static_cast<uint64_t>(offset);
    }
    in.seekg(static_cast<std::streamoff>(mMetricsFileOffset));
    std::string chunk((std::istreambuf_iterator<char>(in)), std::istreambuf_iterator<char>());
    mMetricsFileOffset = size;
    mMetricsPartialLine += chunk;

    auto numberAfter = [](const std::string& line, const char* key, double& out) {
        const auto pos = line.find(key);
        if (pos == std::string::npos) return false;
        const auto colon = line.find(':', pos);
        if (colon == std::string::npos) return false;
        const char* begin = line.c_str() + colon + 1;
        char* end = nullptr;
        out = std::strtod(begin, &end);
        return end != begin && std::isfinite(out) && out >= 0;
    };

    size_t start = 0;
    while (true) {
        const auto newline = mMetricsPartialLine.find('\n', start);
        if (newline == std::string::npos) {
            mMetricsPartialLine.erase(0, start);
            break;
        }
        const std::string line = mMetricsPartialLine.substr(start, newline - start);
        start = newline + 1;
        double stage = -1, tx = -1, encoded = -1;
        if (numberAfter(line, "\"stage_ms\"", stage) && numberAfter(line, "\"tx_ms\"", tx)) {
            mLatestEncodeStageMs = static_cast<float>(stage);
            mLatestTxMs = static_cast<float>(tx);

            std::error_code error;
            const auto modified = std::filesystem::last_write_time(mMetricsFilePath, error);
            if (!error && std::filesystem::file_time_type::clock::now() - modified < std::chrono::seconds(5))
                mLatestEncodeTime = std::chrono::steady_clock::now();
        }
        if (numberAfter(line, "\"encoded\"", encoded) && encoded >= 0) {
            mLatestEncodedFrames = static_cast<uint64_t>(encoded);
        }
    }
    if (mMetricsPartialLine.size() > 64 * 1024) mMetricsPartialLine.clear();
}

MetricsSnapshot NewtXR::MakeMetricsSnapshot() const {
    MetricsSnapshot snapshot;
    snapshot.framesPrepared = mMetricsFramesPrepared;
    snapshot.periodMs = mAveragePeriodMs;
    snapshot.prepareMs = mAveragePrepareMs;
    snapshot.drawMs = mAverageDrawMs;
    snapshot.budgetMs = mFrameBudgetMs;
    snapshot.fps = mAveragePeriodMs > 0.01f ? 1000.0f / mAveragePeriodMs : 0.0f;
    snapshot.metalFXEnabled = MetalFXUpscaleEnabled();
    snapshot.metalFXActive = MetalFXUpscaleActive();
    GetMetalFXDimensions(snapshot.metalFXInputWidth, snapshot.metalFXInputHeight,
                         snapshot.metalFXOutputWidth, snapshot.metalFXOutputHeight);
    const auto now = std::chrono::steady_clock::now();
    const bool encodeLive = mLatestEncodeTime.time_since_epoch().count() != 0 &&
        std::chrono::duration<float>(now - mLatestEncodeTime).count() < 5.0f;
    snapshot.encodeStageMs = encodeLive ? mLatestEncodeStageMs : -1.0f;
    snapshot.txMs = encodeLive ? mLatestTxMs : -1.0f;
    snapshot.encodedFrames = mLatestEncodedFrames;
    const size_t first = mMetricHistoryCount < mMetricPeriodHistory.size() ? 0 : mMetricHistoryNext;
    for (size_t i = 0; i < mMetricHistoryCount; ++i) {
        const size_t index = (first + i) % mMetricPeriodHistory.size();
        snapshot.ageHistory.push_back(std::chrono::duration<double>(now.time_since_epoch()).count() - mMetricTimeHistory[index]);
        snapshot.periodHistory.push_back(mMetricPeriodHistory[index]);
        snapshot.drawHistory.push_back(mMetricDrawHistory[index]);
        snapshot.encodeHistory.push_back(mMetricEncodeHistory[index]);
    }
    return snapshot;
}

void NewtXR::OnDrawEye(const Newt::EyeFrame& eye) {
    const auto drawStart = std::chrono::steady_clock::now();
    const auto cmd = eye.command;
    const auto& viewProj = eye.viewProjection;
    const auto i = eye.index;
            if (mHasEnvironment && mEnvironmentMeshCount > 0) {
                mCore->DrawTextured(cmd, viewProj, Scale(Vec3{40.0f, 40.0f, 40.0f}),
                    mEnvironmentTexture, &mEnvironmentMesh, mEnvironmentMeshCount);
            }
            for (size_t m = 0; m < mModels.size(); ++m) {
                const auto& model = *mModels[m];
                if (!model.addonParentPanel.empty()) continue;
                if (static_cast<int>(m) == mActiveModel) {
                    auto local = IdentityPose();
                    local.position = {
                        model.localCenter.x * model.scale,
                        (model.localCenter.y + model.halfExtents.y) * model.scale + 0.08f,
                        model.localCenter.z * model.scale
                    };
                    mCore->DrawColor(cmd, viewProj,
                        Multiply(PoseMatrix(ComposePose(model.pose, local)), Scale(Vec3{0.05f, 0.05f, 0.05f})),
                        mCubeBuffer, mCubeCount, {0.2f, 0.75f, 0.65f, 1}, false);
                }
                const Mat4 modelMat = PoseMatrix(model.pose,
                    {model.scale, model.scale, model.scale});
                for (const auto& part : model.parts) {
                    if (part.vertexCount == 0) continue;
                    mCore->DrawTextured(cmd, viewProj, modelMat,
                                        part.texture, &part.mesh, part.vertexCount);
                }
            }
            if (!mMenuOpen && mModelPopupModel >= 0 && mModelPopupModel < static_cast<int>(mModels.size())) {
                const auto& popupModel = *mModels[mModelPopupModel];
                const XrPosef popupPose = ModelPopupPose(popupModel);
                mCore->DrawColor(cmd, viewProj,
                                 PoseMatrix(popupPose, {mModelPopupWidth + 0.015f, mModelPopupHeight + 0.015f, 0.012f}),
                                 mCubeBuffer, mCubeCount, {0.045f, 0.06f, 0.075f, 0.97f}, false);
                auto front = IdentityPose();
                front.position.z = 0.009f;
                mCore->DrawTextured(cmd, viewProj,
                                    PoseMatrix(ComposePose(popupPose, front), {mModelPopupWidth, mModelPopupHeight, 1.0f}),
                                    mModelPopupTexture);
            }
            const auto grid=mGridColor.rgb();
            if(mGridColor.enabled) mCore->DrawColor(cmd,viewProj,Identity(),mGridBuffer,mGridCount,{grid[0],grid[1],grid[2],1},true);
            mCore->DrawColor(cmd, viewProj,
                      Multiply(Translation(Vec3{ 0.9f, 0.5f, -2.2f }),
                               Scale(Vec3{ 0.18f, 0.18f, 0.18f })),
                      mCubeBuffer, mCubeCount, Vec4{ 0.92f, 0.68f, 0.22f, 1.0f }, false);
            {
                for (size_t p = 0; p < mPanels.size(); ++p) {
                    const auto& panel = *mPanels[p];
                    if (static_cast<int>(p) == mActivePanel && !PanelLocked(static_cast<int>(p))) {
                        if (panel.curvature<0.001f)
                            mCore->DrawColor(cmd, viewProj, PoseMatrix(panel.pose,
                                {panel.width + 0.025f, panel.height + 0.025f, 0.005f}),
                                mCubeBuffer, mCubeCount, {0.2f, 0.75f, 0.65f, 1}, false);
                        else {


                            auto local = IdentityPose(); local.position = {0, panel.height/2 + 0.08f, 0};
                            mCore->DrawColor(cmd, viewProj,
                                Multiply(PoseMatrix(ComposePose(panel.pose, local)), Scale(Vec3{0.05f, 0.05f, 0.05f})),
                                mCubeBuffer, mCubeCount, {0.2f, 0.75f, 0.65f, 1}, false);
                        }
                    }
                    XrPosef pose = panel.pose;
                    const Vec3 normal = Rotate(pose.orientation, {0, 0, 0.01f});
                    pose.position.x += normal.x; pose.position.y += normal.y; pose.position.z += normal.z;
                    const bool isStereo = (panel.stereoMode > 0) || (panel.gpuTextureRight != nullptr);
                    const bool reverseEyes = (panel.stereoMode == 2 || panel.stereoMode == 4 || panel.stereoMode == 6);
                    const int stereoEye = (i % 2) ^ (reverseEyes ? 1 : 0);

                    if (panel.gpuTexture) {
                        const float panelAspect = panel.width / std::max(0.05f, panel.height);
                        Newt::TextureRegion region{};
                        const Newt::GPUTexture* activeTex = &panel.gpuTexture;

                        if (panel.gpuTextureRight) {
                            activeTex = (stereoEye == 0) ? &panel.gpuTexture : &panel.gpuTextureRight;
                            const uint32_t tw = (stereoEye == 0) ? panel.gpuWidth : panel.gpuRightWidth;
                            const uint32_t th = (stereoEye == 0) ? panel.gpuHeight : panel.gpuRightHeight;
                            const float eyeAspect = (tw > 0 && th > 0) ? (float(tw) / float(th)) : panelAspect;
                            const float w = std::min(1.0f, eyeAspect / panelAspect);
                            const float h = std::min(1.0f, panelAspect / eyeAspect);
                            region.source = {0.0f, 0.0f, 1.0f, 1.0f};
                            region.destination = {(1.0f - w) * 0.5f, (1.0f - h) * 0.5f, w, h};
                        } else if (panel.stereoMode > 0) {
                            const float fullAspect = (panel.gpuWidth > 0 && panel.gpuHeight > 0)
                                ? (float(panel.gpuWidth) / float(panel.gpuHeight)) : panelAspect;
                            const auto layout = CalculateStereoLayout(panel.stereoMode, stereoEye, fullAspect, panelAspect, panel.stereoAlignment);
                            region.source = {layout.sourceX, layout.sourceY, layout.sourceWidth, layout.sourceHeight};
                            region.destination = {layout.destinationX, layout.destinationY, layout.destinationWidth, layout.destinationHeight};
                        } else {
                            const float aspect = (panel.gpuWidth > 0 && panel.gpuHeight > 0)
                                ? (float(panel.gpuWidth) / float(panel.gpuHeight))
                                : panelAspect;
                            const float w = std::min(1.0f, aspect / panelAspect);
                            const float h = std::min(1.0f, panelAspect / aspect);
                            region.source = {0.0f, 0.0f, 1.0f, 1.0f};
                            region.destination = {(1.0f - w) * 0.5f, (1.0f - h) * 0.5f, w, h};
                        }

                        const Buffer* textureMesh = &panel.meshes[0];
                        uint32_t textureVertices = 48 * 6;
                        if (panel.passthrough && mPassthrough.SeeThrough() && mPassthroughCalibrated &&
                            mCore->SupportsPassthroughWindow()) {
                            DrawPassthroughSeeThrough(cmd, viewProj, eye.view.pose, pose, panel,
                                                      activeTex == &panel.gpuTextureRight ? 1 : 0);
                            if (panel.passthrough && mPassthrough.frame) DrawPassthroughFrame(cmd, viewProj, panel);
                            continue;
                        }
                        if (panel.passthrough && mPassthrough.Corrected() && panel.lensVertexCount > 0) {

                            const int camera = activeTex == &panel.gpuTextureRight ? 1 : 0;
                            textureMesh = &panel.lensMeshes[camera];
                            textureVertices = panel.lensVertexCount;
                            region = Newt::TextureRegion{};
                        }
                        mCore->DrawGPUTexture(cmd, viewProj, PoseMatrix(pose,
                            {panel.width, panel.height, panel.width}), *activeTex, region, textureMesh, textureVertices);


                        if (!isStereo && !panel.passthrough && panel.badgeTexture.initialized &&
                            (!panel.screen || ScreenCaptureBadgeVisible())) {
                            XrPosef badgePose = pose;
                            badgePose.position.x += normal.x * 0.1f;
                            badgePose.position.y += normal.y * 0.1f;
                            badgePose.position.z += normal.z * 0.1f;
                            mCore->DrawTextured(cmd, viewProj, PoseMatrix(badgePose,
                                {panel.width, panel.height, panel.width}), panel.badgeTexture, &panel.meshes[0], 48 * 6);
                        }
                    } else {
                        const Buffer* eyeMesh = &panel.meshes[0];
                        if (panel.stereoMode > 0) {
                            const bool vertical = panel.stereoMode == 3 || panel.stereoMode == 4;
                            eyeMesh = &panel.meshes[(vertical ? 3 : 1) + stereoEye];
                        }
                        mCore->DrawTextured(cmd, viewProj, PoseMatrix(pose,
                            {panel.width, panel.height, panel.width}), panel.texture, eyeMesh, 48*6);
                    }
                    if (panel.passthrough && mPassthrough.frame) DrawPassthroughFrame(cmd, viewProj, panel);

                }
            }
            if (mPassthrough.tracing) DrawTracing(cmd, viewProj);
            DrawAlerts(cmd, viewProj);
            DrawCustomPanels(eye, false);
            for(size_t p=0;p<mPanels.size();++p) {
                if (PanelLocked(static_cast<int>(p))) continue;
                const auto& panel=mPanels[p];
                mCore->DrawTextured(cmd,viewProj,PoseMatrix(PanelBarPose(panel->pose,panel->height),{panel->width,1,panel->width}),mBarTexture,&panel->meshes[5],48*6);
            }
            if (mMenuOpen) {
                VkClearAttachment clear{}; clear.aspectMask = VK_IMAGE_ASPECT_DEPTH_BIT;
                clear.clearValue.depthStencil = {1.0f, 0};
                VkClearRect rect{}; rect.rect.extent = {eye.width, eye.height}; rect.layerCount = 1;
                vkCmdClearAttachments(cmd, 1, &clear, 1, &rect);
                if (mPage == Page::Settings || mPage == Page::Games)
                    mCore->DrawTextured(cmd, viewProj, Multiply(PoseMatrix(mDashboardPose),
                        Multiply(Translation(mContentCenter), Scale({mContentWidth, mContentHeight, 1}))), mContentTexture);
                for (int segment=0; segment<kDockSegments; ++segment) {
                    const auto pose = ComposePose(mDashboardPose, DockPose((segment+0.5f)/kDockSegments, kDockRadius+0.025f));
                    mCore->DrawColor(cmd, viewProj, PoseMatrix(pose, {kDockRadius*kDockArc/kDockSegments+0.003f,kDockHeight,0.045f}),
                        mCubeBuffer, mCubeCount, {0.055f,0.06f,0.07f,1}, false);
                }
                mCore->DrawTextured(cmd, viewProj, PoseMatrix(mDashboardPose), mMenuTexture, &mDockBuffer, kDockSegments*6);
                for(int button=0;button<9;++button) {
                    const int mesh=button*2+(button==mSelected?1:0);
                    mCore->DrawColor(cmd,viewProj,PoseMatrix(mDashboardPose),mButtonBodies[mesh],kButtonBodyCount,{.08f,.085f,.095f,1},false);
                    mCore->DrawTextured(cmd,viewProj,PoseMatrix(mDashboardPose),mButtonTextures[button],&mButtonFaces[mesh],kButtonFaceCount);
                }
                auto logoPose = ComposePose(mDashboardPose, DockPose(0.072f, kDockRadius-0.06f));
                mCore->DrawColor(cmd, viewProj, PoseMatrix(logoPose,{0.20f,0.20f,0.055f}),mCubeBuffer,mCubeCount,{0.10f,0.14f,0.15f,1},false);
                auto front = IdentityPose(); front.position.z=0.03f;
                mCore->DrawTextured(cmd,viewProj,PoseMatrix(ComposePose(logoPose,front),{0.19f,0.19f,1}),mLogoTexture);
            }
            for (int h = 0; h < 2; ++h) {
                if (!mAimValid[h] || mRayAlpha[h] <= 0) continue;
                constexpr float kMaxRayLength = 20.0f;
                Vec3 hit{0, 0, -999};
                bool didHit = false;
                if (mMenuOpen) {
                    didHit = MenuHit(mAimPoses[h], hit) >= 0;
                } else {
                    int panel = -1, model = -1, popupModel = -1, popupButton = -1;
                    float panelDist = 1000.0f, modelDist = 1000.0f, popupDist = 1000.0f;
                    const bool hitPanel = PanelHit(mAimPoses[h], panel, panelDist) >= 0;
                    const bool hitModel = ModelHit(mAimPoses[h], model, modelDist) >= 0;
                    const bool hitPopup = ModelPopupHit(mAimPoses[h], popupModel, popupButton, popupDist) != -1 && popupModel >= 0;
                    if (hitPanel || hitModel || hitPopup) {
                        float distance = 1000.0f;
                        if (hitPanel) distance = std::min(distance, panelDist);
                        if (hitModel) distance = std::min(distance, modelDist);
                        if (hitPopup) distance = std::min(distance, popupDist);
                        const auto& p = mAimPoses[h].position;
                        hit = Vec3{p.x, p.y, p.z} + Rotate(mAimPoses[h].orientation, {0, 0, -1}) * distance;
                        didHit = true;
                    }
                }
                const auto& pos = mAimPoses[h].position;
                const float length = didHit ? std::sqrt((hit.x-pos.x)*(hit.x-pos.x) +
                    (hit.y-pos.y)*(hit.y-pos.y) + (hit.z-pos.z)*(hit.z-pos.z)) : kMaxRayLength;
                const Mat4 rayModel = Multiply(PoseMatrix(mAimPoses[h]), Scale({1, 1, length}));
                mCore->DrawColor(cmd, viewProj, rayModel, mRayBuffer, 2,
                          Vec4{ 0.55f, 0.85f, 1.0f, mRayAlpha[h] }, true);
            }
            if (mStretchActive && mStretchPanel >= 0 && mStretchPanel < static_cast<int>(mPanels.size())) {
                const auto& panel = *mPanels[mStretchPanel];
                const float w = panel.width, h = panel.height, thickness = 0.015f;
                const Vec4 outlineColor{0.55f, 0.85f, 1.0f, 0.95f};
                auto edge = [&](float cx, float cy, float ex, float ey) {
                    auto local = IdentityPose(); local.position = {cx, cy, 0.02f};
                    mCore->DrawColor(cmd, viewProj, Multiply(PoseMatrix(ComposePose(panel.pose, local)), Scale({ex, ey, thickness})),
                        mCubeBuffer, mCubeCount, outlineColor, false);
                };
                edge(0, h/2, w, thickness);
                edge(0, -h/2, w, thickness);
                edge(-w/2, 0, thickness, h);
                edge(w/2, 0, thickness, h);
            }
            if (mCursorValid && mMenuOpen) {
                mCore->DrawColor(cmd, viewProj,
                          Multiply(Translation(mCursor), Scale(Vec3{ 0.012f, 0.012f, 0.012f })),
                          mCubeBuffer, mCubeCount, Vec4{ 1.0f, 1.0f, 1.0f, mCursorAlpha }, false);
            }


            DrawCameraHands(cmd, viewProj, i == 1 ? 1 : 0);
            if (mClockHand >= 0) {
                mCore->DrawTextured(cmd, viewProj, PoseMatrix(mClockPose, {mClockSettings.Width(), mClockSettings.Width() * 0.375f, 1}), mWristClockTexture);
            }
            if (mShowMetrics) {
                const Mat4 metricsPose = Multiply(
                    PoseMatrix(mViewerPose),
                    Multiply(Translation({0.42f, 0.25f, -1.15f}), Scale({0.74f, 0.37f, 1.0f})));
                mCore->DrawTextured(cmd, viewProj, metricsPose, mMetricsTexture);
            }
            DrawHandBenchmarkOverlay(eye);
            DrawCustomPanels(eye, true);
            DrawRecenterRing(eye);
            if (mFadeAlpha > 0) {
                const Mat4 front = Multiply(PoseMatrix(eye.view.pose),
                    Multiply(Translation({0, 0, -0.08f}), Scale({1, 1, 0.001f})));
                mCore->DrawColor(cmd, viewProj, front, mCubeBuffer, mCubeCount, {0, 0, 0, mFadeAlpha}, false);
            }
    if (eye.index == 0) mLastDrawMs = 0;
    mLastDrawMs += std::chrono::duration<float, std::milli>(
        std::chrono::steady_clock::now() - drawStart).count();
}
