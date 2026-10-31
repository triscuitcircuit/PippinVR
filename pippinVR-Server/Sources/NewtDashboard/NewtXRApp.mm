#include "NewtXRApp.h"
#include "NewtInternal.h"
#include "include/NewtLog.h"
#include <algorithm>
#include <fstream>
#include <csignal>
#include <cstring>
#include <dlfcn.h>
#include "SystemCheck.h"
#include "Metrics.h"
#include "HandBenchmark.h"
#include "AddonAudioBridge.h"
#include "AddonCameraBridge.h"
#include "AddonInputBridge.h"
#include "ScreenLabelPreferences.h"
using namespace NewtInternal;
void NewtXR::Run() {
    LoadMetalFXSettings();
    SetScreenCaptureBadgeVisible(LoadScreenLabelPreference());
    mClockSettings = LoadWristClockSettings();
    mPassthrough = LoadPassthroughSettings();
    if (const char* value = std::getenv("NEWT_WRIST_CLOCK")) mClockSettings.enabled = std::strcmp(value, "0") != 0;
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
    if (const char* value = std::getenv("NEWT_METRICS")) {
        mShowMetrics = std::strcmp(value, "0") != 0;
    }
    if (const char* value = std::getenv("QL_METRICS_FILE")) {
        mMetricsFilePath = value;
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
    HandBenchmarkStart(mPassthrough.allowed);
    StartAddonAudioBridge();
    StartAddonCameraBridge();
    StartAddonInputBridge();
    CreateRenderAssets();
    AddPanel(false,0);
    if (mPassthrough.enabled) SetPassthroughShown(true);
    else if (CameraHandsActive() || HandBenchmarkNeedsFrames()) UpdateCameraRequest();
    RestoreScene();
}
bool NewtXR::OnTick(Newt::Session& session) {
    if (mFadeAlpha >= 1.0f) return false;
    ApplyCommands();
    if (HandBenchmarkEnabled()) {
        HandBenchmarkTick();
        UpdateCameraRequest();
    }
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
        mClockHand = -1;
        for (auto& gesture : mWristGestures) gesture.Reset();
        mGrabHand=-1; mGrabbedPanel=-1; mGrabbedModel=-1; mGrabbing={false,false};
        mModelPopupModel=-1; mModelPopupHoveredButton=-1;
        mStretchActive=false; mStretchPanel=-1; mStretchModel=-1;
        mPrevSelect={false,false};mPrevMenu={false,false};mLastInput={};
        mAimValid={false,false};mGripValid={false,false};
    }
}
void NewtXR::OnStopping(Newt::Session&) noexcept {
    mAddonModelRequests.clear();
    mAddonModelsLastScan = {};
    StopAddonInputBridge();
    StopAddonCameraBridge();
    StopAddonAudioBridge();
    HandBenchmarkStop();
    SaveSceneIfChanged(true);
    mSceneRestored = false;
    if (const int portal = PassthroughPanel(); portal >= 0) {
        StorePassthroughPlacement(*mPanels[portal]);
        SavePassthroughSettings(mPassthrough);
    }
    ReleasePassthroughRuntime();
    ReleaseRecenterRuntime();
    mControllerBatteryPercent = nullptr;
    if (mBatteryRuntime) dlclose(mBatteryRuntime);
    mBatteryRuntime = nullptr;
    mControllerBattery[0] = mControllerBattery[1] = -1;
    mBatteryPoll = {};
    ReleaseSystemAudio();
    for (auto& panel : mPanels) {
        if (panel->screen) panel->screen->Stop();
        if (panel->camera) panel->camera->Stop();
    }

    if (mCore->Device() != VK_NULL_HANDLE) vkDeviceWaitIdle(mCore->Device());
    mHandBenchmarkImages[0].reset();
    mHandBenchmarkImages[1].reset();
    mCore->DestroyTexture(mHandBenchmarkStatus);
    mHandBenchmarkPreviewSequence = 0;

    for(auto& t:mButtonTextures) mCore->DestroyTexture(t);
    mCore->DestroyTexture(mMenuTexture);
    mCore->DestroyTexture(mModelPopupTexture);
    mCore->DestroyTexture(mMetricsTexture);
    mCore->DestroyTexture(mWristClockTexture);
    mCore->DestroyTexture(mTraceTexture);
    mTraceRenderedPrompt.clear();
    mPassthrough.tracing = false;
    mCore->DestroyTexture(mLogoTexture);
    mCore->DestroyTexture(mBarTexture);
    mCore->DestroyBuffer(mDockBuffer);
    for(auto& b:mButtonFaces) mCore->DestroyBuffer(b);
    for(auto& b:mButtonBodies) mCore->DestroyBuffer(b);
    for (auto& panel : mPanels) {
        mCore->DestroyTexture(panel->texture);
        mCore->DestroyTexture(panel->badgeTexture);
        panel->gpuTexture.reset();
        panel->gpuTextureRight.reset();
        for(auto& b:panel->meshes) mCore->DestroyBuffer(b);
        for(auto& b:panel->lensMeshes) mCore->DestroyBuffer(b);
    }
    mPanels.clear();
    if (mHasEnvironment) {
        mCore->DestroyTexture(mEnvironmentTexture);
        mHasEnvironment = false;
    }
    mCore->DestroyBuffer(mEnvironmentMesh);
    mEnvironmentMeshCount = 0;
    mEnvironmentPath.clear();
    mEnvironmentFlipV = mEnvironmentFlipH = false;
    ClearEnvironmentModel();
    for (auto& alert : mAlerts) mCore->DestroyTexture(alert.texture);
    mAlerts.clear();
    for (auto& panel : mCustomPanels) mCore->DestroyTexture(panel.texture);
    mCustomPanels.clear();
    mCore->DestroyTexture(mRecenterRingTexture);
    mAlertDrag = {-1, -1};
    mCore->DestroyTexture(mContentTexture);
    mCore->DestroyBuffer(mFractalCubeEdges);
    mCore->DestroyBuffer(mFractalCube);
    mCore->DestroyBuffer(mCutCubeEdges);
    mCore->DestroyBuffer(mCutCube);
    mCore->DestroyBuffer(mCubeEdges);
    mCore->DestroyBuffer(mCubeBuffer);
    mCore->DestroyBuffer(mGridBuffer);
    mCore->DestroyBuffer(mRayBuffer);
    mCore->DestroyBuffer(mHandTube);
    mCore->DestroyBuffer(mHandBall);
    mHandTubeCount = mHandBallCount = 0;

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
