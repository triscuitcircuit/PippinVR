#include "NewtXRApp.h"
#include "Newt.h"
#include "NewtInternal.h"
#include "InteractionGeometry.h"
#include "Environment.h"
#include "EnvironmentModel.h"
#include "Metrics.h"
#include "ScreenLabelPreferences.h"
#include <algorithm>
#include <cmath>
#include <cstdio>
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

XrVector3f ModelGridPosition(size_t index) {
    const int columns = std::max(3, static_cast<int>(std::ceil(std::sqrt(static_cast<double>(index + 1)))));
    const int col = (static_cast<int>(index) + 1) % columns;
    const int row = static_cast<int>(index) / columns;
    const float x = col * 1.35f - (columns - 1) * 1.35f / 2.0f;
    const float y = 0.65f + static_cast<float>(row) * 1.15f;
    return {x, y, -2.1f};
}
}

void NewtXR::RemoveModel(int index) {
    if (index < 0 || index >= static_cast<int>(mModels.size())) return;
    if (!mModels[index]->addonID.empty())
        ReportAddonModel(mModels[index]->addonID, mModels[index]->addonRevision, "removed");
    for (auto& part : mModels[index]->parts) {
        mCore->DestroyBuffer(part.mesh);
        mCore->DestroyTexture(part.texture);
    }
    mModels.erase(mModels.begin() + index);
    if (mModels.empty()) {
        mActiveModel = 0;
    } else if (mActiveModel > index) {
        mActiveModel--;
    } else if (mActiveModel >= static_cast<int>(mModels.size())) {
        mActiveModel = static_cast<int>(mModels.size()) - 1;
    }
    if (mModelPopupModel == index) mModelPopupModel = -1;
    else if (mModelPopupModel > index) mModelPopupModel--;
    mModelPopupHoveredButton = -1;
    mGrabbedModel = -1;
    mStretchModel = -1;
}

void NewtXR::ClearEnvironmentModel() {
    for (const auto& model : mModels)
        if (!model->addonID.empty()) ReportAddonModel(model->addonID, model->addonRevision, "removed");
    for (auto& model : mModels) {
        for (auto& part : model->parts) {
            mCore->DestroyBuffer(part.mesh);
            mCore->DestroyTexture(part.texture);
        }
    }
    mModels.clear();
    mActiveModel = 0;
    mGrabbedModel = -1;
    mStretchModel = -1;
    mModelPopupModel = -1;
    mModelPopupHoveredButton = -1;
}

XrPosef NewtXR::ModelPopupPose(const ModelInstance& model) {
    const float extent = 2.0f * std::max(model.halfExtents.x, model.halfExtents.z) * model.scale;
    mModelPopupWidth = std::clamp(extent * 1.15f, 0.52f, 1.25f);
    mModelPopupHeight = mModelPopupWidth * 0.25f;

    const Vec3 localTop{
        model.localCenter.x * model.scale,
        (model.localCenter.y + model.halfExtents.y) * model.scale,
        model.localCenter.z * model.scale};
    const Vec3 top = Vec3{model.pose.position.x, model.pose.position.y, model.pose.position.z}
        + Rotate(model.pose.orientation, localTop);

    XrPosef popup = IdentityPose();
    popup.position = {top.x, top.y + mModelPopupHeight * 0.62f + 0.06f, top.z};
    const float dx = mViewerPose.position.x - popup.position.x;
    const float dz = mViewerPose.position.z - popup.position.z;
    const float yaw = std::atan2(dx, dz);
    popup.orientation = {0.0f, std::sin(yaw * 0.5f), 0.0f, std::cos(yaw * 0.5f)};
    return popup;
}

int NewtXR::ModelPopupHit(const XrPosef& ray, int& modelIndex, int& button, float& distance) {
    modelIndex = -1;
    button = -1;
    distance = 1000.0f;
    if (mMenuOpen || mModelPopupModel < 0 || mModelPopupModel >= static_cast<int>(mModels.size())) return -1;

    const XrPosef popup = ModelPopupPose(*mModels[mModelPopupModel]);
    const auto inverse = Conjugate(popup.orientation);
    const Vec3 origin = Rotate(inverse, {
        ray.position.x - popup.position.x,
        ray.position.y - popup.position.y,
        ray.position.z - popup.position.z});
    const Vec3 direction = Rotate(inverse, Rotate(ray.orientation, {0, 0, -1}));
    if (std::abs(direction.z) < 1e-6f) return -1;
    const float t = -origin.z / direction.z;
    if (t <= 0) return -1;
    const Vec3 hit = origin + direction * t;
    if (std::abs(hit.x) > mModelPopupWidth * 0.5f || std::abs(hit.y) > mModelPopupHeight * 0.5f) return -1;
    distance = t;
    modelIndex = mModelPopupModel;
    if (hit.y > mModelPopupHeight * 0.22f) return -2;

    const float px = (hit.x / mModelPopupWidth + 0.5f) * 1024.0f;
    const int candidate = static_cast<int>((px - 24.0f) / 196.0f);
    if (candidate < 0 || candidate >= 5) return -2;
    const float localX = px - 24.0f - candidate * 196.0f;
    if (localX < 0.0f || localX > 184.0f) return -2;
    button = candidate;
    return button;
}

void NewtXR::ActivateModelPopupButton(int modelIndex, int button, int hand) {
    if (modelIndex < 0 || modelIndex >= static_cast<int>(mModels.size())) return;
    mActiveModel = modelIndex;
    auto& model = *mModels[modelIndex];
    if (hand >= 0) mCore->PulseHaptic(hand, 0.45f);
    switch (button) {
    case 0:
        model.scale = std::max(0.02f, model.scale / 1.4f);
        mNotice = "Selected 3D model scaled down";
        break;
    case 1:
        model.scale = std::min(50.0f, model.scale * 1.4f);
        mNotice = "Selected 3D model scaled up";
        break;
    case 2: {
        model.yaw += 0.785398163f;
        const float halfStep = 0.785398163f * 0.5f;
        const XrQuaternionf yawStep{0.0f, std::sin(halfStep), 0.0f, std::cos(halfStep)};
        model.pose.orientation = QuaternionProduct(yawStep, model.pose.orientation);
        mNotice = "Selected 3D model rotated 45°";
        break;
    }
    case 3:
        model.inFront = !model.inFront;
        model.pose = IdentityPose();
        model.pose.position = model.inFront
            ? ModelGridPosition(static_cast<size_t>(modelIndex))
            : XrVector3f{0.0f, 0.0f, 0.0f};
        mNotice = model.inFront ? "Selected 3D model placed in front" : "Selected 3D model centered on room floor";
        break;
    case 4:
        CheckVk(vkDeviceWaitIdle(mCore->Device()), "remove model popup");
        RemoveModel(modelIndex);
        mNotice = mModels.empty() ? "Last 3D model removed" : "3D model removed";
        mRenderedMenuSelected = -1;
        return;
    default:
        return;
    }
    mRenderedMenuSelected = -1;
}

void NewtXR::UpdateModelPopupCandidate() {
    if (mMenuOpen || mModels.empty()) {
        mModelPopupModel = -1;
        mModelPopupHoveredButton = -1;
        return;
    }

    for (int hand = 0; hand < 2; ++hand) {
        if (!mAimValid[hand]) continue;
        int hitModel = -1, hitButton = -1;
        float hitDistance = 1000.0f;
        if (ModelPopupHit(mAimPoses[hand], hitModel, hitButton, hitDistance) != -1 && hitModel >= 0) {
            mModelPopupHoveredButton = hitButton;
            return;
        }
    }

    int candidate = -1;
    float bestDistance = 1000.0f;
    for (int hand = 0; hand < 2; ++hand) {
        if (!mAimValid[hand]) continue;
        int hitModel = -1;
        float hitDistance = 1000.0f;
        if (ModelHit(mAimPoses[hand], hitModel, hitDistance) >= 0 && hitDistance < bestDistance) {
            candidate = hitModel;
            bestDistance = hitDistance;
        }
    }
    if (mGrabbedModel >= 0 && mGrabbedModel < static_cast<int>(mModels.size())) candidate = mGrabbedModel;
    else if (mStretchModel >= 0 && mStretchModel < static_cast<int>(mModels.size())) candidate = mStretchModel;
    mModelPopupModel = candidate;
    mModelPopupHoveredButton = -1;
}

void NewtXR::AddPanel(bool camera, uint32_t source, bool displayID, const std::string& cameraID, const std::string& videoPath) {
    if (mPanels.size() >= kMaxPanels) {
        mNotice = std::to_string(kMaxPanels) + "-panel limit reached";
        mRenderedMenuSelected = -1;
        return;
    }
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
        if (displayID) panel->displaySourceID = source;
        if (displayID) panel->screen->SetDisplayID(source);
        panel->screen->Start(displayID ? 0 : source, mCaptureFPS);
    }
    mPanels.push_back(std::move(panel));
    mActivePanel = static_cast<int>(mPanels.size() - 1);
}

NewtXR::ModelInstance* NewtXR::AddModelFromFile(const std::string& path) {
    if (mModels.size() >= kMaxModels) return nullptr;
    EnvironmentModel model = LoadModelFile(path);
    if (!model.loaded || model.parts.empty()) return nullptr;
    CheckVk(vkDeviceWaitIdle(mCore->Device()), "environment model load");
    auto instance = std::make_unique<ModelInstance>();
    for (const auto& srcPart : model.parts) {
        if (srcPart.vertices.empty() || srcPart.texture.width == 0 || srcPart.texture.height == 0) continue;
        LoadedModelPart gpuPart;
        gpuPart.vertexCount = static_cast<uint32_t>(srcPart.vertices.size());
        gpuPart.mesh = mCore->CreateBuffer(srcPart.vertices.size() * sizeof(VertexPC),
                                           VK_BUFFER_USAGE_VERTEX_BUFFER_BIT);
        mCore->UploadBuffer(gpuPart.mesh,
                            srcPart.vertices.data(),
                            srcPart.vertices.size() * sizeof(VertexPC));
        mCore->CreateTexture(gpuPart.texture, srcPart.texture.width, srcPart.texture.height);
        mCore->UpdateTexture(gpuPart.texture, srcPart.texture);
        instance->parts.push_back(std::move(gpuPart));
    }
    instance->path = path;
    instance->scale = model.defaultScale;
    instance->defaultScale = model.defaultScale;
    instance->yaw = 0.0f;
    instance->inFront = true;
    instance->localCenter = model.localCenter;
    instance->halfExtents = model.halfExtents;
    instance->summary = model.summary;
    instance->pose = IdentityPose();
    instance->pose.position = ModelGridPosition(mModels.size());
    mModels.push_back(std::move(instance));
    mActiveModel = static_cast<int>(mModels.size() - 1);
    return mModels.back().get();
}

bool NewtXR::LoadEnvironmentImage(const std::string& path) {
    const PixelImage img = LoadImageFile(path);
    if (img.width == 0 || img.height == 0) return false;
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
    mEnvironmentPath = path;
    mEnvironmentFlipV = mEnvironmentFlipH = false;
    return true;
}

void NewtXR::ApplyCommands() {
    auto pending = TakeCommands();
    for (const auto& command : pending) {
        if (command.rfind("stereo:",0)==0 && !mPanels.empty()) {
            const std::string mode=command.substr(7);
            if (mode=="0" || mode=="1" || mode=="2" || mode=="3" || mode=="4" || mode=="5" || mode=="6") mPanels[mActivePanel]->stereoMode=std::stoi(mode);
            continue;
        }
        if (command.rfind("stereo-align:", 0) == 0 && !mPanels.empty()) {
            const std::string value = command.substr(13);
            const std::vector<std::string> allowed = {"-30", "-25", "-20", "-15", "-10", "-5", "0", "5", "10", "15", "20", "25", "30"};
            if (std::find(allowed.begin(), allowed.end(), value) != allowed.end()) {
                mPanels[mActivePanel]->stereoAlignment = std::stoi(value) / 100.0f;
                mNotice = "Stereo alignment " + value + "%";
                mRenderedMenuSelected = -1;
            }
            continue;
        }
        if (command.rfind("notice:", 0) == 0) {
            mNotice = command.substr(7); mRenderedMenuSelected = -1; continue;
        }
        if (command == "screen-labels:reload") {
            SetScreenCaptureBadgeVisible(LoadScreenLabelPreference());
            mRenderedMenuSelected = -1; mContentDirty = true;
            continue;
        }
        if (command == "stop") { gFadeRequested.store(true); continue; }
        if (command.rfind("add-device:", 0) == 0) { AddPanel(true, 0, false, command.substr(11)); continue; }
        if (command.rfind("add-media-file:",0)==0) { AddPanel(true, UINT32_MAX, false, "", command.substr(15)); continue; }
        if (command.rfind("environment-model:", 0) == 0 ||
            (command.rfind("environment:", 0) == 0 && IsModelFilePath(command.substr(12)))) {
            if (mModels.size() >= kMaxModels) {
                mNotice = "3D model limit reached";
                mRenderedMenuSelected = -1;
                continue;
            }
            const std::string path = command.rfind("environment-model:", 0) == 0
                ? command.substr(18)
                : command.substr(12);
            if (ModelInstance* model = AddModelFromFile(path)) {
                mNotice = "3D Model #" + std::to_string(mModels.size()) + " added (aim & grip to move/rotate, two grips to scale): " + model->summary;
            } else {
                mNotice = "Could not load 3D model (.usdz/.obj/.gltf/.glb)";
            }
            mRenderedMenuSelected = -1;
            continue;
        }
        if (command == "remove-model" && !mModels.empty()) {
            CheckVk(vkDeviceWaitIdle(mCore->Device()), "remove model");
            RemoveModel(mActiveModel);
            mNotice = mModels.empty()
                ? "Last 3D model removed"
                : ("3D model removed (" + std::to_string(mModels.size()) + " remaining)");
            mRenderedMenuSelected = -1;
            continue;
        }
        if (command.rfind("environment:", 0) == 0) {
            mNotice = LoadEnvironmentImage(command.substr(12)) ? "Environment image set" : "Could not load that image";
            continue;
        }
        if (command == "environment-clear") {
            CheckVk(vkDeviceWaitIdle(mCore->Device()), "environment clear");
            if (mHasEnvironment) {
                mCore->DestroyTexture(mEnvironmentTexture);
                mEnvironmentImage = PixelImage{};
                mHasEnvironment = false;
            }
            mEnvironmentPath.clear();
            mEnvironmentFlipV = mEnvironmentFlipH = false;
            ClearEnvironmentModel();
            mNotice = "Environment cleared";
            mRenderedMenuSelected = -1;
            continue;
        }
        if (command == "environment-scale-up" && !mModels.empty()) {
            auto& active = *mModels[mActiveModel];
            active.scale = std::min(50.0f, active.scale * 1.4f);
            mNotice = "Selected 3D model scaled up";
            mRenderedMenuSelected = -1;
            continue;
        }
        if (command == "environment-scale-down" && !mModels.empty()) {
            auto& active = *mModels[mActiveModel];
            active.scale = std::max(0.02f, active.scale / 1.4f);
            mNotice = "Selected 3D model scaled down";
            mRenderedMenuSelected = -1;
            continue;
        }
        if (command == "environment-rotate-y" && !mModels.empty()) {
            auto& active = *mModels[mActiveModel];
            active.yaw += 0.785398163f;
            const float halfStep = 0.785398163f * 0.5f;
            const XrQuaternionf yawStep{0.0f, std::sin(halfStep), 0.0f, std::cos(halfStep)};
            active.pose.orientation = QuaternionProduct(yawStep, active.pose.orientation);
            mNotice = "Selected 3D model rotated 45°";
            mRenderedMenuSelected = -1;
            continue;
        }
        if (command == "environment-toggle-origin" && !mModels.empty()) {
            auto& active = *mModels[mActiveModel];
            active.inFront = !active.inFront;
            active.pose = IdentityPose();
            active.pose.position = active.inFront
                ? ModelGridPosition(static_cast<size_t>(mActiveModel))
                : XrVector3f{0.0f, 0.0f, 0.0f};
            mNotice = active.inFront ? "Selected 3D model placed in front" : "Selected 3D model centered on room floor";
            mRenderedMenuSelected = -1;
            continue;
        }
        if ((command == "environment-flip-v" || command == "environment-flip-h") && mHasEnvironment) {
            if (command == "environment-flip-v") { FlipImageVertical(mEnvironmentImage); mEnvironmentFlipV = !mEnvironmentFlipV; }
            else { FlipImageHorizontal(mEnvironmentImage); mEnvironmentFlipH = !mEnvironmentFlipH; }
            mCore->UpdateTexture(mEnvironmentTexture, mEnvironmentImage);
            mNotice = command == "environment-flip-v" ? "Environment flipped vertically" : "Environment flipped horizontally";
            continue;
        }
        if (command == "audio:reload") {
            ReloadAudioSettings();
            continue;
        }
        if (command == "passthrough:reload") {

            const PassthroughSettings saved = LoadPassthroughSettings();
            mPassthrough.allowed = saved.allowed;
            mPassthrough.enabled = saved.enabled;
            SetPassthroughShown(mPassthrough.enabled);
            mContentDirty = true;
            continue;
        }
        if (command == "wrist-clock:1" || command == "wrist-clock:0") {
            mClockSettings.enabled = command == "wrist-clock:1";
            ClockSettingsChanged();
            continue;
        }
        if (command == "metrics:1" || command == "metrics:0") {
            mShowMetrics = command == "metrics:1";
            mNotice = mShowMetrics ? "Metrics graph shown" : "Metrics graph hidden";
            mRenderedMenuSelected = -1;
            continue;
        }
        if (command == "metalfx-scale:0" || command == "metalfx-scale:1.25" ||
            command == "metalfx-scale:1.5" || command == "metalfx-scale:2") {
            SetMetalFXScale(std::stof(command.substr(14)));
            mNotice = "MetalFX scale updated";
            mRenderedMenuSelected = -1;
            continue;
        }
        if (command == "metalfx:1" || command == "metalfx:0") {
            SetMetalFXUpscaleEnabled(command == "metalfx:1");
            mNotice = command == "metalfx:1" ? "MetalFX spatial upscaling on" : "MetalFX spatial upscaling off";
            mRenderedMenuSelected = -1;
            continue;
        }
        if (command == "add-media") { RequestHost(4); mNotice = "Choose a video on your Mac"; mRenderedMenuSelected = -1; continue; }
        if (command.rfind("add-demo-display:", 0) == 0) {
            unsigned id = 0, index = 0;
            if (std::sscanf(command.c_str(), "add-demo-display:%u:%u", &id, &index) == 2 && index < 24 && mPanels.size() < kMaxPanels) {
                const bool hasOrbit = std::any_of(mPanels.begin(), mPanels.end(), [](const auto& p) { return p->demoOrbitIndex >= 0; });
                if (!hasOrbit) {
                    mDemoOrbitCenter = mViewerPose.position;
                    const Vec3 forward = Rotate(mViewerPose.orientation, {0, 0, -1});
                    mDemoOrbitHeading = std::atan2(forward.x, -forward.z);
                    mDemoOrbitStarted = std::chrono::steady_clock::now();
                }
                AddPanel(false, id, true);
                auto& panel = *mPanels.back();
                panel.demoOrbitIndex = static_cast<int>(index);
                panel.width = 0.68f; panel.height = 0.425f;
            }
        } else if (command.rfind("remove-display:", 0) == 0) {
            const auto value = command.substr(15);
            if (value.empty() || value.find_first_not_of("0123456789") != std::string::npos || value.size() > 10 || std::stoull(value) > UINT32_MAX) continue;
            const auto id = static_cast<uint32_t>(std::stoull(value));
            auto it = std::find_if(mPanels.begin(), mPanels.end(), [id](const auto& p) { return id != 0 && p->displaySourceID == id; });
            if (it == mPanels.end()) continue;
            CheckVk(vkDeviceWaitIdle(mCore->Device()), "remove display panel");
            mCore->DestroyTexture((*it)->texture); mCore->DestroyTexture((*it)->badgeTexture);
            (*it)->gpuTexture.reset(); (*it)->gpuTextureRight.reset();
            for (auto& b : (*it)->meshes) mCore->DestroyBuffer(b);
            mPanels.erase(it); mActivePanel = 0; mGrabbedPanel = -1; mGrabHand = -1;
        } else if (command.rfind("add-screen:", 0) == 0 || command.rfind("add-camera:", 0) == 0 || command.rfind("add-display:", 0) == 0) {
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
            mPanels[mActivePanel]->gpuTextureRight.reset();
            for(auto& b:mPanels[mActivePanel]->meshes) mCore->DestroyBuffer(b);
            mPanels.erase(mPanels.begin() + mActivePanel);
            mActivePanel = 0;
            mGrabbedPanel = -1;
            mGrabHand = -1;
        } else if ((command == "remove" || command == "remove-last") && !mPanels.empty()) {
            const bool last = command == "remove-last" || mPanels[mActivePanel]->passthrough;
            if (last) {
                int found = -1;
                for (int p = static_cast<int>(mPanels.size()) - 1; p >= 0 && found < 0; --p)
                    if (!mPanels[p]->passthrough) found = p;
                if (found < 0) continue;
                mActivePanel = found;
            }
            CheckVk(vkDeviceWaitIdle(mCore->Device()), "remove panel");
            mCore->DestroyTexture(mPanels[mActivePanel]->texture);
            mCore->DestroyTexture(mPanels[mActivePanel]->badgeTexture);
            mPanels[mActivePanel]->gpuTexture.reset();
            mPanels[mActivePanel]->gpuTextureRight.reset();
            for(auto& b:mPanels[mActivePanel]->meshes) mCore->DestroyBuffer(b);
            mPanels.erase(mPanels.begin() + mActivePanel);
            mActivePanel = 0;
            mGrabbedPanel = -1;
            mGrabHand = -1;
        } else if (command == "reset") {
            for (size_t p = 0; p < mPanels.size(); ++p) {
                if (PanelLocked(static_cast<int>(p))) continue;
                mPanels[p]->pose = IdentityPose();
                mPanels[p]->pose.position = PanelGridPosition(p);
                mPanels[p]->width = 1.8f;
            }
            for (size_t m = 0; m < mModels.size(); ++m) {
                mModels[m]->pose = IdentityPose();
                mModels[m]->pose.position = ModelGridPosition(m);
                mModels[m]->scale = mModels[m]->defaultScale;
                mModels[m]->inFront = true;
            }
        } else if (command == "resolution:1024" || command == "resolution:1536" || command == "resolution:2048") {
            CheckVk(vkDeviceWaitIdle(mCore->Device()), "panel resolution");
            SetLiveResolution(static_cast<uint32_t>(std::stoi(command.substr(11))));
            for (auto& panel : mPanels) {
                mCore->DestroyTexture(panel->texture); mCore->DestroyTexture(panel->badgeTexture);
                panel->gpuTexture.reset(); panel->gpuTextureRight.reset();
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
        if (PanelLocked(static_cast<int>(i))) continue;
        const auto& panel=*mPanels[i]; float t,u;
        if (RayScreen(ray,PanelBarPose(panel.pose,panel.height),panel.width,panel.curvature,t,u,0.075f) && t<distance) {
            distance=t;panelIndex=static_cast<int>(i);zone=PanelBarZone(u);
        }
    }
    if (zone>=0 || barsOnly) return zone;
    for(size_t i=0;i<mPanels.size();++i) {
        if (PanelLocked(static_cast<int>(i))) continue;
        const auto& panel=*mPanels[i]; float t,u;
        if(RayScreen(ray,panel.pose,panel.width,panel.curvature,t,u,panel.height) && t<distance) {
            distance=t;panelIndex=static_cast<int>(i);zone=1;
        }
    }
    return zone;
}

int NewtXR::ModelHit(const XrPosef& ray, int& modelIndex, float& distance) {
    modelIndex = -1;
    distance = 1000.0f;
    for (size_t i = 0; i < mModels.size(); ++i) {
        const auto& model = *mModels[i];
        if (!model.addonParentPanel.empty()) continue;
        const float s = std::max(0.01f, model.scale);
        const auto inv = Conjugate(model.pose.orientation);
        const Vec3 origin = Rotate(inv, {
            ray.position.x - model.pose.position.x,
            ray.position.y - model.pose.position.y,
            ray.position.z - model.pose.position.z
        });
        const Vec3 dir = Rotate(inv, Rotate(ray.orientation, Vec3{0, 0, -1}));
        const float orig[3] = {origin.x, origin.y, origin.z};
        const float d[3] = {dir.x, dir.y, dir.z};
        const float bmin[3] = {
            (model.localCenter.x - model.halfExtents.x) * s,
            (model.localCenter.y - model.halfExtents.y) * s,
            (model.localCenter.z - model.halfExtents.z) * s
        };
        const float bmax[3] = {
            (model.localCenter.x + model.halfExtents.x) * s,
            (model.localCenter.y + model.halfExtents.y) * s,
            (model.localCenter.z + model.halfExtents.z) * s
        };
        float tmin = 0.05f;
        float tmax = distance;
        bool hit = true;
        for (int axis = 0; axis < 3; ++axis) {
            if (std::fabs(d[axis]) < 1e-6f) {
                if (orig[axis] < bmin[axis] || orig[axis] > bmax[axis]) {
                    hit = false;
                    break;
                }
            } else {
                float t1 = (bmin[axis] - orig[axis]) / d[axis];
                float t2 = (bmax[axis] - orig[axis]) / d[axis];
                if (t1 > t2) std::swap(t1, t2);
                tmin = std::max(tmin, t1);
                tmax = std::min(tmax, t2);
                if (tmin > tmax) {
                    hit = false;
                    break;
                }
            }
        }
        if (hit && tmin < distance) {
            distance = tmin;
            modelIndex = static_cast<int>(i);
        }
    }
    return modelIndex >= 0 ? 1 : -1;
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
            return mPage==Page::Settings ? HeadsetSettingsControlAt(u*1024,py,mSettingsTab)
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

void NewtXR::ClockSettingsChanged() {
    mClockHand = -1;
    for (auto& gesture : mWristGestures) gesture.Reset();
    mClockRenderedText.clear();
    mLastClockUpdate = {};
    mContentDirty = true;
    const bool saved = SaveWristClockSettings(mClockSettings);
    mNotice = saved ? "Wrist clock preferences saved" : "Clock updated; could not save preferences";
    mRenderedMenuSelected = -1;
}

void NewtXR::SelectItem(int index) {
    if (mPage == Page::Settings) {
        if (index >= 104 && index <= 106) {
            mSettingsTab = index - 104;
            if (mSettingsTab == 2) mPassthrough.allowed = LoadPassthroughSettings().allowed;
            mContentDirty = true;
            return;
        }
        if (mSettingsTab == 1 && mClockSettings.Select(index)) {
            ClockSettingsChanged();
            return;
        }
        if (mSettingsTab == 2 && mPassthrough.locked && (index == 302 || index == 307) && PassthroughPanel() >= 0) {
            mNotice = "The portal is locked in place · unlock it under Position first";
            mRenderedMenuSelected = -1;
            return;
        }
        if (mSettingsTab == 2 && index == 311) {
            SetCameraHands(PassthroughSettings::NextHands(mPassthrough.hands));
            return;
        }
        if (mSettingsTab == 2 && index == 310) {
            SetPassthroughLocked(!mPassthrough.locked);
            SavePassthroughSettings(mPassthrough);
            mRenderedMenuSelected = -1;
            mContentDirty = true;
            return;
        }
        if (mSettingsTab == 2 && index == 308) {
            if (mPassthrough.tracing) StopTracing("Tracing cancelled");
            else StartTracing();
            return;
        }
        if (mSettingsTab == 2 && mPassthrough.Select(index)) {
            if (index == 305) mFollowValid = false;
            if (index == 307) {
                if (const int portal = PassthroughPanel(); portal >= 0) PlacePassthroughForDirection(*mPanels[portal]);
            }
            if (index == 300) {
                SetPassthroughShown(mPassthrough.enabled);
            } else if (const int portal = PassthroughPanel(); portal >= 0) {
                auto& panel = *mPanels[portal];
                if (index == 302) { panel.width = mPassthrough.width; panel.height = mPassthrough.height; }
                if (index == 301 && !mPassthrough.stereo) panel.gpuTextureRight.reset();
            }
            if (index != 300) mNotice = SavePassthroughSettings(mPassthrough) ? "Passthrough preferences saved"
                                                                               : "Could not save passthrough preferences";
            mContentDirty = true;
            mRenderedMenuSelected = -1;
            return;
        }
    }
    if(mPage == Page::Games && index>=110) {
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
    if(index==111) {
        const bool visible = !ScreenCaptureBadgeVisible();
        if (SaveScreenLabelPreference(visible)) {
            SetScreenCaptureBadgeVisible(visible);
            mNotice = visible ? "Screen labels on" : "Screen labels off";
        } else {
            mNotice = "Could not save screen label preference";
        }
        mRenderedMenuSelected = -1;
        mContentDirty = true;
        return;
    }
    if(index==107) { SetAudioMode(systemaudio::NextMode(mAudio.mode)); return; }
    if(index==108) { RequestHost(5); mNotice = "Recording: check the VR View on your Mac"; mRenderedMenuSelected = -1; return; }
    if(index==109) { RequestHost(6); mNotice = "Changing recording view…"; mRenderedMenuSelected = -1; return; }
    if(index==110) { RequestHost(7); mNotice = "Changing headset desktop view…"; mRenderedMenuSelected = -1; return; }
    if(index==101) { mMediaVolume=mMediaVolume>=0.99f?0:std::min(1.0f,mMediaVolume+0.1f); SetMediaVolume(mMediaVolume); mContentDirty=true; return; }
    if (index < 0 || index >= static_cast<int>(kMenuItems.size())) return;
    mSelected = index;
    switch (index) {
    case 0: mPage = Page::Screens; break;
    case 1:
        if (mPanels.size() < kMaxPanels) { RequestHost(1); mNotice = "Creating virtual screen…"; }
        else mNotice = std::to_string(kMaxPanels) + "-panel limit reached";
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
