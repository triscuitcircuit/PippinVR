#include "NewtXRApp.h"
#include "NewtInternal.h"
#include "include/NewtLog.h"
#include <algorithm>
#include <fstream>
#include <csignal>
#include <cstring>
#include "SystemCheck.h"
using namespace NewtInternal;
void NewtXR::Run() {
    auto raySetting = [](const char* key, double fallback, double min, double max) {
        const char* raw = std::getenv(key);
        if (!raw) return fallback;
        char* end = nullptr;
        const double value = std::strtod(raw, &end);
        return end != raw && *end == '\0' && std::isfinite(value) && value >= min && value <= max ? value : fallback;
    };
    for (auto& ray : mRayActivity) {
        ray.idleSeconds = raySetting("NEWT_RAY_IDLE_SECONDS", 2, 0, 60);
        ray.wakeDistanceMeters = raySetting("NEWT_RAY_WAKE_METERS", 0.02, 0.001, 0.5);
        ray.wakeAngleDegrees = raySetting("NEWT_RAY_WAKE_DEGREES", 3, 0.1, 90);
    }
    if (const char* value = std::getenv("NEWT_CAPTURE_FPS")) {
        const int fps = std::atoi(value);
        if (fps == 15 || fps == 30 || fps == 60) mCaptureFPS = fps;
    }
    uint32_t width = 1024;
    if (const char* value = std::getenv("NEWT_PANEL_WIDTH")) {
        const int requested = std::atoi(value);
        if (requested == 1024 || requested == 1536 || requested == 2048) width = requested;
    }
    SetLiveResolution(width);
    if (const char* appsPath = std::getenv("NEWT_APPS_FILE")) {
        std::ifstream in(appsPath);
        std::string line;
        while (std::getline(in, line)) {
            if (!line.empty() && line.back() == '\r') line.pop_back();
            if (!line.empty()) mApps.push_back(line);
        }
        Newt_Logf(NEWT_LOG_INFO, "%zu launchable app(s)", mApps.size());
    }
    std::signal(SIGINT, HandleSignal);
    std::signal(SIGTERM, HandleSignal);
    mCore->Run(*this);
}
void NewtXR::OnReady(Newt::Session&) {
    CreateRenderAssets();
    AddPanel(false,0);
}
bool NewtXR::OnTick(Newt::Session& session) {
    if (mFadeAlpha >= 1.0f) return false;
    ApplyCommands();
    if(gQuitRequested.load()) return false;
    if(gFadeRequested.load()) {
        if(!session.Running()) return false;
        if(mFadeStart.time_since_epoch().count()==0) mFadeStart=std::chrono::steady_clock::now();
        mFadeAlpha=std::min(1.0f,std::chrono::duration<float>(std::chrono::steady_clock::now()-mFadeStart).count()/0.4f);
    }
    return true;
}
void NewtXR::OnSessionState(XrSessionState state) {
    SetMediaVolume(state==XR_SESSION_STATE_FOCUSED?mMediaVolume:0);
    if(state!=XR_SESSION_STATE_FOCUSED) {
        mGrabHand=-1; mGrabbedPanel=-1; mGrabbing={false,false};
        mPrevSelect={false,false};mPrevMenu={false,false};mLastInput={};
        mAimValid={false,false};mGripValid={false,false};
    }
}
void NewtXR::OnStopping(Newt::Session&) noexcept {
    for (auto& panel : mPanels) {
        if (panel->screen) panel->screen->Stop();
        if (panel->camera) panel->camera->Stop();
    }

    if (mCore->Device() != VK_NULL_HANDLE) vkDeviceWaitIdle(mCore->Device());

    for(auto& t:mButtonTextures) mCore->DestroyTexture(t);
    mCore->DestroyTexture(mMenuTexture);
    mCore->DestroyTexture(mLogoTexture);
    mCore->DestroyTexture(mBarTexture);
    mCore->DestroyBuffer(mDockBuffer);
    for(auto& b:mButtonFaces) mCore->DestroyBuffer(b);
    for(auto& b:mButtonBodies) mCore->DestroyBuffer(b);
    for (auto& panel : mPanels) { mCore->DestroyTexture(panel->texture); mCore->DestroyTexture(panel->badgeTexture); panel->gpuTexture.reset(); for(auto& b:panel->meshes) mCore->DestroyBuffer(b); }
    mPanels.clear();
    mCore->DestroyTexture(mContentTexture);
    mCore->DestroyBuffer(mCubeBuffer);
    mCore->DestroyBuffer(mGridBuffer);
    mCore->DestroyBuffer(mRayBuffer);

}

void NewtXR::OnSystem(const XrSystemProperties& systemProperties) {
    const char* allowSimulated = std::getenv("NEWT_ALLOW_SIMULATED");
    if (IsSimulatedSystemName(systemProperties.systemName) &&
        !(allowSimulated && std::strcmp(allowSimulated, "1") == 0)) {
        Newt_Logf(NEWT_LOG_ERROR,
                  "fatal: OpenXR fell back to simulated system '%s'. Is another application "
                  "holding the headset? Set NEWT_ALLOW_SIMULATED=1 to render to it anyway.",
                  systemProperties.systemName);
        if (Newt_IsEmbedded()) throw SimulatedRefused{};
        std::_Exit(2);
    }
}
