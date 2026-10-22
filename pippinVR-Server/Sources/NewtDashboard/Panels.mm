#include "NewtXRApp.h"
#include "Newt.h"
#include "NewtInternal.h"
#include "InteractionGeometry.h"
#include "Environment.h"
#include <algorithm>
#include <cmath>
#include <cstring>
#include <iostream>
#include <thread>
using namespace NewtInternal;

namespace {

XrVector3f PanelGridPosition(size_t index) {
    const int columns = std::max(3, static_cast<int>(std::ceil(std::sqrt(static_cast<double>(index + 1)))));
    const int col = (static_cast<int>(index) + 1) % columns;
    const int row = static_cast<int>(index) / columns;
    const float x = col * 1.9f - (columns - 1) * 1.9f / 2.0f;
    const float y = 1.45f + static_cast<float>(row) * 1.3f;
    return {x, y, -2.35f};
}
}

void NewtXR::AddPanel(bool camera, uint32_t source, bool displayID, const std::string& cameraID, const std::string& videoPath) {
    if (mPanels.size() >= kMaxPanels) return;
    auto panel = std::make_unique<Panel>();
    mCore->CreateTexture(panel->texture, LiveWidth(), LiveHeight());
    mCore->UpdateTexture(panel->texture, RenderContent(camera ? Page::Media : Page::Screens));
    panel->pose.position = PanelGridPosition(mPanels.size());
    if (camera) {
        panel->camera = std::make_unique<MediaCaptureManager>();
        panel->camera->SetCameraID(cameraID);
        panel->camera->SetVideoPath(videoPath);
        if (source == UINT32_MAX) { panel->camera->SetFPS(mCaptureFPS); panel->camera->Start(); }
        else panel->camera->StartCamera(source, mCaptureFPS);
    } else {
        panel->screen = std::make_unique<ScreenCaptureManager>();
        if (displayID) panel->screen->SetDisplayID(source);
        panel->screen->Start(displayID ? 0 : source, mCaptureFPS);
    }
    mPanels.push_back(std::move(panel));
    mActivePanel = static_cast<int>(mPanels.size() - 1);
}

void NewtXR::ApplyCommands() {
    auto pending = TakeCommands();
    for (const auto& command : pending) {
        if (command.rfind("stereo:",0)==0 && !mPanels.empty()) {
            const std::string mode=command.substr(7);
            if (mode=="0" || mode=="1" || mode=="2" || mode=="3" || mode=="4") mPanels[mActivePanel]->stereoMode=std::stoi(mode);
            continue;
        }
        if (command.rfind("notice:", 0) == 0) {
            mNotice = command.substr(7); mRenderedMenuSelected = -1; continue;
        }
        if (command == "stop") { gFadeRequested.store(true); continue; }
        if (command.rfind("add-device:", 0) == 0) { AddPanel(true, 0, false, command.substr(11)); continue; }
        if (command.rfind("add-media-file:",0)==0) { AddPanel(true, UINT32_MAX, false, "", command.substr(15)); continue; }
        if (command.rfind("environment:", 0) == 0) {
            const PixelImage img = LoadImageFile(command.substr(12));
            if (img.width > 0 && img.height > 0) {
                CheckVk(vkDeviceWaitIdle(mCore->Device()), "environment load");
                if (mHasEnvironment) { mCore->DestroyTexture(mEnvironmentTexture); }
                mCore->CreateTexture(mEnvironmentTexture, img.width, img.height);
                mCore->UpdateTexture(mEnvironmentTexture, img);
                mEnvironmentImage = img;
                if (mEnvironmentMeshCount == 0) {
                    const auto vertices = MakeEnvironmentSphere();
                    mEnvironmentMesh = mCore->CreateBuffer(vertices.size()*sizeof(VertexPC), VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
                    mCore->UploadBuffer(mEnvironmentMesh, vertices.data(), vertices.size()*sizeof(VertexPC));
                    mEnvironmentMeshCount = static_cast<uint32_t>(vertices.size());
                }
                mHasEnvironment = true;
                mNotice = "Environment image set";
            } else {
                mNotice = "Could not load that image";
            }
            continue;
        }
        if (command == "environment-clear" && mHasEnvironment) {
            mCore->DestroyTexture(mEnvironmentTexture);
            mEnvironmentImage = PixelImage{};
            mHasEnvironment = false;
            mNotice = "Environment image cleared";
            continue;
        }
        if ((command == "environment-flip-v" || command == "environment-flip-h") && mHasEnvironment) {
            if (command == "environment-flip-v") FlipImageVertical(mEnvironmentImage);
            else FlipImageHorizontal(mEnvironmentImage);
            mCore->UpdateTexture(mEnvironmentTexture, mEnvironmentImage);
            mNotice = command == "environment-flip-v" ? "Environment flipped vertically" : "Environment flipped horizontally";
            continue;
        }
        if (command == "add-media") { AddPanel(true, UINT32_MAX); continue; }
        if (command.rfind("add-screen:", 0) == 0 || command.rfind("add-camera:", 0) == 0 || command.rfind("add-display:", 0) == 0) {
            const auto value = command.substr(command.find(':') + 1);
            if (!value.empty() && value.find_first_not_of("0123456789") == std::string::npos && value.size() <= 10 && std::stoull(value) <= UINT32_MAX)
                AddPanel(command.rfind("add-camera:", 0) == 0, static_cast<uint32_t>(std::stoull(value)), command.rfind("add-display:", 0) == 0);
        } else if (command == "remove-media" && !mPanels.empty()) {
            int found = -1;
            for (int p = static_cast<int>(mPanels.size()) - 1; p >= 0; --p) {
                if (mPanels[p]->camera) { found = p; break; }
            }
            if (found < 0) { mNotice = "No video/media panel to remove"; continue; }
            mActivePanel = found;
            CheckVk(vkDeviceWaitIdle(mCore->Device()), "remove panel");
            mCore->DestroyTexture(mPanels[mActivePanel]->texture);
            mCore->DestroyTexture(mPanels[mActivePanel]->badgeTexture);
            mPanels[mActivePanel]->gpuTexture.reset();
            for(auto& b:mPanels[mActivePanel]->meshes) mCore->DestroyBuffer(b);
            mPanels.erase(mPanels.begin() + mActivePanel);
            mActivePanel = 0;
            mGrabbedPanel = -1;
            mGrabHand = -1;
        } else if ((command == "remove" || command == "remove-last") && !mPanels.empty()) {
            if (command == "remove-last") mActivePanel = static_cast<int>(mPanels.size() - 1);
            CheckVk(vkDeviceWaitIdle(mCore->Device()), "remove panel");
            mCore->DestroyTexture(mPanels[mActivePanel]->texture);
            mCore->DestroyTexture(mPanels[mActivePanel]->badgeTexture);
            mPanels[mActivePanel]->gpuTexture.reset();
            for(auto& b:mPanels[mActivePanel]->meshes) mCore->DestroyBuffer(b);
            mPanels.erase(mPanels.begin() + mActivePanel);
            mActivePanel = 0;
            mGrabbedPanel = -1;
            mGrabHand = -1;
        } else if (command == "reset") {
            for (size_t p = 0; p < mPanels.size(); ++p) {
                mPanels[p]->pose = IdentityPose();
                mPanels[p]->pose.position = PanelGridPosition(p);
                mPanels[p]->width = 1.8f;
            }
        } else if (command == "resolution:1024" || command == "resolution:1536" || command == "resolution:2048") {
            CheckVk(vkDeviceWaitIdle(mCore->Device()), "panel resolution");
            SetLiveResolution(static_cast<uint32_t>(std::stoi(command.substr(11))));
            for (auto& panel : mPanels) {
                mCore->DestroyTexture(panel->texture); mCore->DestroyTexture(panel->badgeTexture); panel->gpuTexture.reset();
                mCore->CreateTexture(panel->texture, LiveWidth(), LiveHeight());
                mCore->UpdateTexture(panel->texture, RenderContent(panel->camera ? Page::Media : Page::Screens));
                if (panel->screen) panel->screen->SetFPS(mCaptureFPS);
            }
        } else if (command == "fps:15" || command == "fps:30" || command == "fps:60") {
            mCaptureFPS = static_cast<uint32_t>(std::stoi(command.substr(4)));
            for (auto& panel : mPanels) {
                if (panel->screen) panel->screen->SetFPS(mCaptureFPS);
                if (panel->camera) panel->camera->SetFPS(mCaptureFPS);
            }
        }
    }
}

int NewtXR::PanelHit(const XrPosef& ray, int& panelIndex, float& distance, bool barsOnly) {
    int zone=-1; panelIndex=-1; distance=1000;
    for (size_t i=0;i<mPanels.size();++i) {
        const auto& panel=*mPanels[i]; float t,u;
        if (RayScreen(ray,PanelBarPose(panel.pose,panel.height),panel.width,panel.curvature,t,u,0.075f) && t<distance) {
            distance=t;panelIndex=static_cast<int>(i);zone=PanelBarZone(u);
        }
    }
    if (zone>=0 || barsOnly) return zone;
    for(size_t i=0;i<mPanels.size();++i) {
        const auto& panel=*mPanels[i]; float t,u;
        if(RayScreen(ray,panel.pose,panel.width,panel.curvature,t,u,panel.height) && t<distance) {
            distance=t;panelIndex=static_cast<int>(i);zone=1;
        }
    }
    return zone;
}

int NewtXR::MenuHit(const XrPosef& pose, Vec3& hitPoint) {
    if (!mMenuOpen) return -1;
    const auto inverse = Conjugate(mDashboardPose.orientation);
    const Vec3 origin = Rotate(inverse, {pose.position.x - mDashboardPose.position.x,
        pose.position.y - mDashboardPose.position.y, pose.position.z - mDashboardPose.position.z});
    const Vec3 dir = Rotate(inverse, Rotate(pose.orientation, Vec3{0, 0, -1}));
    float distance, u, v;
    if(mPage==Page::Settings || mPage==Page::Games) {
        auto local=IdentityPose(); local.position={mContentCenter.x,mContentCenter.y,mContentCenter.z};
        auto content=ComposePose(mDashboardPose,local);
        if(RayQuad(pose,content,mContentWidth,mContentHeight,distance,u)) {
            Vec3 h=origin+dir*distance;
            float py=(0.5f-(h.y-mContentCenter.y)/mContentHeight)*640;
            hitPoint=Rotate(mDashboardPose.orientation,h)+Vec3{mDashboardPose.position.x,mDashboardPose.position.y,mDashboardPose.position.z};
            return mPage==Page::Settings ? GridControlAt(u*1024,py)
                                         : AppsRowAt(u*1024,py,static_cast<int>(mApps.size()));
        }
    }
    for(int button=0;button<9;++button) {
        if(RayDock(origin,dir,distance,u,v,ButtonRadius(button==mSelected)) &&
            u*1024>=148+button*95 && u*1024<=148+button*95+88 && v*160>=46 && v*160<=128) {
            hitPoint=Vec3{pose.position.x,pose.position.y,pose.position.z}+Rotate(pose.orientation,{0,0,-1})*distance;
            return button;
        }
    }
    if (!RayDock(origin, dir, distance, u, v)) return -1;
    const Vec3 hit = origin + dir * distance;
    const Vec3 world = Rotate(mDashboardPose.orientation, hit);
    hitPoint = world + Vec3{mDashboardPose.position.x, mDashboardPose.position.y, mDashboardPose.position.z};
    return -1;
}

void NewtXR::SelectItem(int index) {
    if(index>=110) {
        const int app=index-110;
        if(app < static_cast<int>(mApps.size())) {
            RequestHost(100+app);
            mNotice = "Launching " + mApps[app] + "…";
            mRenderedMenuSelected = -1;
        }
        return;
    }
    if(index==100 || index==102) return;
    if(index==103) { mGridColor.enabled=!mGridColor.enabled; mContentDirty=true; return; }
    if(index==101) { mMediaVolume=mMediaVolume>=0.99f?0:std::min(1.0f,mMediaVolume+0.1f); SetMediaVolume(mMediaVolume); mContentDirty=true; return; }
    if (index < 0 || index >= static_cast<int>(kMenuItems.size())) return;
    mSelected = index;
    switch (index) {
    case 0: mPage = Page::Screens; break;
    case 1:
        if (mPanels.size() < kMaxPanels) { RequestHost(1); mNotice = "Creating virtual screen…"; }
        else mNotice = "Panel limit reached";
        break;
    case 2: RequestHost(2); mNotice = "Removing last panel…"; break;
    case 3: mRecenterMenu = true; Newt_Command("reset"); mNotice = "Layout reset"; break;
    case 4: mPage = Page::Settings; break;
    case 5: mMenuOpen = false; mPage = Page::Screens; break;
    case 6: gFadeRequested.store(true); break;
    case 7:
        if (!mApps.empty()) { mPage = Page::Games; mNotice = "Pick an app to launch"; }
        else { RequestHost(3); mNotice = "Choose a native OpenXR app on your Mac"; }
        break;
    case 8: RequestHost(4); mNotice = "Choose a video on your Mac"; break;
    }
    mRenderedMenuSelected = -1;
    mContentDirty = true;
}
