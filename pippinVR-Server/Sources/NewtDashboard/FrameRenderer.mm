#include "NewtXRApp.h"
#include "InteractionGeometry.h"
#include "Newt/CaptureInternal.h"
#include "include/NewtLog.h"
void NewtXR::OnPrepareFrame(const XrFrameState& frameState) {
    for(auto& panel:mPanels) if(panel->curvature!=panel->builtCurvature) {
        CheckVk(vkDeviceWaitIdle(mCore->Device()),"screen mesh update");
        for(int mode=0;mode<6;++mode) {
            auto vertices=mode==5?MakePanelBar(panel->curvature):MakeScreen(panel->curvature,mode);
            if(panel->meshes[mode].buffer==VK_NULL_HANDLE) panel->meshes[mode]=mCore->CreateBuffer(vertices.size()*sizeof(VertexPC),VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
            mCore->UploadBuffer(panel->meshes[mode],vertices.data(),vertices.size()*sizeof(VertexPC));
        }
        panel->builtCurvature=panel->curvature;
    }
    mCore->BeginUploads();
    if (mSelected != mRenderedMenuSelected) {
        mCore->UpdateTexture(mMenuTexture, RenderMenu(mSelected, mNotice.c_str(), false));
        for(int i=0;i<9;++i) mCore->UpdateTexture(mButtonTextures[i],RenderDockButton(i,i==mSelected));
        mRenderedMenuSelected = mSelected;
    }

    // Capture callbacks retain only the latest frame. Hidden dashboard pages do not upload.
    if (frameState.shouldRender) {
        for (auto& panel : mPanels) {
            RetainedObject pixels;
            std::string label;
            if (panel->screen && panel->screen->GetLatestPixelBuffer(panel->sequence, pixels, label)) {
                auto buffer = static_cast<CVPixelBufferRef>(pixels.get());
                auto texture = mCore->ImportPixelBuffer(buffer);
                if (texture) {
                    panel->gpuTexture = std::move(texture);
                    const float aspect = float(CVPixelBufferGetWidth(buffer)) / CVPixelBufferGetHeight(buffer);
                    const float target = 1.6f;
                    const float width = std::min(1.0f, aspect / target);
                    const float height = std::min(1.0f, target / aspect);
                    panel->gpuRegion.destination = {(1-width)/2, (1-height)/2, width, height};
                    if (!panel->gpuPathLogged) {
                        Newt_Logf(NEWT_LOG_INFO, "Desktop GPU capture active (IOSurface, no CPU pixel copy)");
                        panel->gpuPathLogged = true;
                    }
                    if (panel->badgeLabel != label || !panel->badgeTexture.initialized) {
                        if (!panel->badgeTexture.initialized) mCore->CreateTexture(panel->badgeTexture);
                        NSString* text = [NSString stringWithUTF8String:label.c_str()];
                        auto badge = MakeImage(^(NSRect) {
                            FillRounded(NSMakeRect(24,18,460,38),10,RGB(0.05f,0.07f,0.09f,0.78f));
                            DrawText(text,NSMakeRect(38,24,432,26),18,YES,RGB(0.48f,0.88f,0.78f));
                        });
                        mCore->UpdateTexture(panel->badgeTexture, badge);
                        panel->badgeLabel = label;
                    }
                    continue;
                }
                panel->gpuTexture.reset();
                mCore->UpdateTexture(panel->texture, NewtCaptureInternal::PixelImageFromCVPixelBuffer(buffer, label));
            } else {
                PixelImage image;
                if (panel->Source().GetLatestFrame(panel->sequence, image)) {
                    panel->gpuTexture.reset();
                    mCore->UpdateTexture(panel->texture, image);
                }
            }
        }
    }
    if (mContentDirty || mPage != mRenderedPage) {
        mCore->UpdateTexture(mContentTexture, RenderContent(mPage,mGridColor,mMediaVolume,mApps));
        mRenderedPage = mPage;
        mContentDirty = false;
    }

    mCore->FlushUploads();
}

void NewtXR::OnDrawEye(const Newt::EyeFrame& eye) {
    const auto cmd = eye.command;
    const auto& viewProj = eye.viewProjection;
    const auto i = eye.index;
            if (mHasEnvironment && mEnvironmentMeshCount > 0) {
                mCore->DrawTextured(cmd, viewProj, Scale(Vec3{40.0f, 40.0f, 40.0f}),
                    mEnvironmentTexture, &mEnvironmentMesh, mEnvironmentMeshCount);
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
                    if (static_cast<int>(p) == mActivePanel) {
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
                    const Buffer* eyeMesh = &panel.meshes[0];
                    if (panel.stereoMode > 0) {
                        const bool vertical = panel.stereoMode >= 3;
                        const bool reverse = panel.stereoMode == 2 || panel.stereoMode == 4;
                        const int eye = (i % 2) ^ (reverse ? 1 : 0);
                        eyeMesh = &panel.meshes[(vertical ? 3 : 1) + eye];
                    }
                    if (panel.gpuTexture) {
                        mCore->DrawGPUTexture(cmd, viewProj, PoseMatrix(pose,
                            {panel.width,panel.height,panel.width}), panel.gpuTexture, panel.gpuRegion, eyeMesh,48*6);
                        // A small local normal offset puts the badge above its curved surface.
                        XrPosef badgePose = pose;
                        badgePose.position.x += normal.x * 0.1f;
                        badgePose.position.y += normal.y * 0.1f;
                        badgePose.position.z += normal.z * 0.1f;
                        mCore->DrawTextured(cmd, viewProj, PoseMatrix(badgePose,
                            {panel.width,panel.height,panel.width}), panel.badgeTexture, &panel.meshes[0],48*6);
                    } else {
                        mCore->DrawTextured(cmd, viewProj, PoseMatrix(pose,
                            {panel.width, panel.height, panel.width}), panel.texture, eyeMesh, 48*6);
                    }

                }
            }
            {
                VkClearAttachment clear{};clear.aspectMask=VK_IMAGE_ASPECT_DEPTH_BIT;clear.clearValue.depthStencil={1,0};
                VkClearRect rect{};rect.rect.extent={eye.width,eye.height};rect.layerCount=1;
                vkCmdClearAttachments(cmd,1,&clear,1,&rect);
                for(const auto& panel:mPanels) mCore->DrawTextured(cmd,viewProj,PoseMatrix(PanelBarPose(panel->pose,panel->height),{panel->width,1,panel->width}),mBarTexture,&panel->meshes[5],48*6);
            }
            if (mMenuOpen) {
                // Dashboard stays reachable even when a desktop is dragged in front of it.
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
                    int panel; float distance;
                    if (PanelHit(mAimPoses[h], panel, distance) >= 0) {
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

            if (mFadeAlpha > 0) {
                const Mat4 front = Multiply(PoseMatrix(eye.view.pose),
                    Multiply(Translation({0, 0, -0.08f}), Scale({1, 1, 0.001f})));
                mCore->DrawColor(cmd, viewProj, front, mCubeBuffer, mCubeCount, {0, 0, 0, mFadeAlpha}, false);
            }
}
