#ifndef NEWT_NEWTXRAPP_H
#define NEWT_NEWTXRAPP_H

#include "Newt/Capture.h"
#include "Newt/Session.h"
#include "UI.h"
#include "RayActivity.h"
#include "WristClock.h"
#include "PassthroughSettings.h"
#include "PassthroughLens.h"
#include "PassthroughTrace.h"
#include "SceneStore.h"
#include "CustomUI.h"
#include "SystemAudio.h"

#include <array>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <string>
#include <vector>
#include <memory>
#include <map>
#include <functional>

extern std::atomic_bool gQuitRequested;
void HandleSignal(int);

class NewtXR final : public Newt::SessionDelegate {
public:
    NewtXR() = default;
    NewtXR(const NewtXR&) = delete;
    NewtXR& operator=(const NewtXR&) = delete;
    void Run();

private:
    void CreateRenderAssets();
    void OnSystem(const XrSystemProperties&) override;
    void OnReady(Newt::Session&) override;
    bool OnTick(Newt::Session&) override;
    void OnInput(const Newt::InputState&) override;
    void OnPrepareFrame(const XrFrameState&) override;
    void OnDrawEye(const Newt::EyeFrame&) override;
    void OnSessionState(XrSessionState) override;
    void OnStopping(Newt::Session&) noexcept override;
    void UpdateHandBenchmarkOverlay();
    void DrawHandBenchmarkOverlay(const Newt::EyeFrame& eye);
    Newt::GPUTexture mHandBenchmarkImages[2];
    Texture mHandBenchmarkStatus;
    uint64_t mHandBenchmarkPreviewSequence = 0;
    float mHandBenchmarkAspect[2] = {4.0f / 3.0f, 4.0f / 3.0f};
    std::unique_ptr<Newt::Session> mCore = std::make_unique<Newt::Session>();
    int PanelHit(const XrPosef& ray, int& panelIndex, float& distance, bool barsOnly = false);
    int MenuHit(const XrPosef& pose, Vec3& hitPoint);
    void SelectItem(int index);
    void ApplyCommands();
    void AddPanel(bool camera, uint32_t source, bool displayID = false, const std::string& cameraID = "", const std::string& videoPath = "");


    static constexpr size_t kMaxPanels = 24;
    struct Panel {
        Texture texture;
        Newt::GPUTexture gpuTexture;
        Newt::GPUTexture gpuTextureRight;
        Newt::TextureRegion gpuRegion;
        uint32_t gpuWidth = 0;
        uint32_t gpuHeight = 0;
        uint32_t gpuRightWidth = 0;
        uint32_t gpuRightHeight = 0;
        Texture badgeTexture;
        std::string badgeLabel;
        bool gpuPathLogged = false;
        std::unique_ptr<ScreenCaptureManager> screen;
        uint32_t displaySourceID = 0;
        int demoOrbitIndex = -1;
        std::unique_ptr<MediaCaptureManager> camera;
        FrameSource& Source() { return screen ? static_cast<FrameSource&>(*screen) : static_cast<FrameSource&>(*camera); }
        uint64_t sequence = 0;
        XrPosef pose = IdentityPose();
        float width = 1.8f;
        float height = 1.8f * 0.625f;
        float curvature = 0, builtCurvature = -1;
        std::array<Buffer,6> meshes;
        int stereoMode = 0;
        float stereoAlignment = 0;


        bool passthrough = false;

        std::array<Buffer, 2> lensMeshes;
        uint32_t lensVertexCount = 0;
        float lensAspect = 0;
        int lensFov = -1;
        int lensDirection = -1;
        std::chrono::steady_clock::time_point lensAspectChanged{};
    };
    std::vector<std::string> mApps;
    std::vector<std::unique_ptr<Panel>> mPanels;
    XrVector3f mDemoOrbitCenter{};
    float mDemoOrbitHeading = 0;
    std::chrono::steady_clock::time_point mDemoOrbitStarted{};
    int mActivePanel = 0;
    uint32_t mCaptureFPS = 30;
    GridColor mGridColor;
    float mMediaVolume = 0.7f;
    std::array<Texture,9> mButtonTextures;
    std::array<bool, 2> mPrevSelect{false, false}, mPrevMenu{false, false};
    std::array<int, 2> mPrevHover{-1, -1};
    std::chrono::steady_clock::time_point mLastAdjust{};

    std::chrono::steady_clock::time_point mFadeStart{};
    float mFadeAlpha = 0;
    Buffer mCubeBuffer, mCubeEdges, mCutCube, mCutCubeEdges, mFractalCube, mFractalCubeEdges, mGridBuffer, mRayBuffer, mDockBuffer;
    uint32_t mCutCubeCount = 0, mCutCubeEdgeCount = 0, mFractalCubeCount = 0, mFractalCubeEdgeCount = 0;
    std::array<Buffer,18> mButtonFaces, mButtonBodies;
    uint32_t mCubeCount = 0, mGridCount = 0;



    Texture mEnvironmentTexture;
    Buffer mEnvironmentMesh;
    uint32_t mEnvironmentMeshCount = 0;
    bool mHasEnvironment = false;


    PixelImage mEnvironmentImage;
    std::string mEnvironmentPath;
    bool mEnvironmentFlipV = false, mEnvironmentFlipH = false;
    bool LoadEnvironmentImage(const std::string& path);

    SavedScene mMissingScene;
    std::string mLastSceneText;
    std::chrono::steady_clock::time_point mLastSceneCheck{};
    bool mSceneRestored = false;
    void RestoreScene();
    void SaveSceneIfChanged(bool force = false);
    SavedScene CurrentScene() const;

    struct DashboardAlert {
        std::string title, detail, key;
        Texture texture;
        bool rendered = false;
        bool dismissed = false;
        float offset = 0;
    };
    std::vector<DashboardAlert> mAlerts;
    std::array<int, 2> mAlertDrag{-1, -1};
    std::array<float, 2> mAlertDragStart{};
    std::array<bool, 2> mAlertPrevSelect{false, false};
    void AddAlert(const std::string& title, const std::string& detail, const std::string& key);

public:

    using CustomPanelHandler = std::function<void(const std::string&, const std::string&, const std::string&)>;

    void ShowCustomPanel(const customui::PanelSpec& spec, CustomPanelHandler handler = {});
    void RemoveCustomPanel(const std::string& id);
private:
    struct CustomPanel {
        customui::PanelSpec spec;
        customui::Layout layout;
        Texture texture;
        CustomPanelHandler handler;
        bool dirty = true, removed = false, hidden = false, placed = false, fromScript = false;
        XrPosef worldPose = IdentityPose();
        std::chrono::steady_clock::time_point rotationStart = std::chrono::steady_clock::now();
        double fileTime = 0;
    };
    std::vector<CustomPanel> mCustomPanels;
    std::map<std::string, double> mCustomPanelErrors;
    std::array<bool, 2> mCustomPrevSelect{false, false};
    std::chrono::steady_clock::time_point mCustomScan{};
    void ScanCustomPanelFiles();
    void PruneCustomPanels();
    void RenderCustomPanels();
    bool CustomPanelPose(CustomPanel& panel, XrPosef& pose, float& width, float& height);
    void UpdateCustomPanels(Newt::InputState& input);
    void DrawCustomPanels(const Newt::EyeFrame& eye, bool headPanels);
    void EmitCustomPanelEvent(CustomPanel& panel, const std::string& event, const std::string& button);
    void DismissAlert(int index);
    void UpdateAlerts(Newt::InputState& input);
    void PruneAlerts();
    void RenderAlerts();
    void DrawAlerts(VkCommandBuffer cmd, const Mat4& viewProj);
    std::vector<int> VisibleAlerts() const;
    XrPosef AlertPose(int slot, float offset) const;
    static constexpr size_t kMaxModels = 16;
    struct LoadedModelPart {
        Buffer mesh;
        Texture texture;
        uint32_t vertexCount = 0;
    };
    struct ModelInstance {
        std::vector<LoadedModelPart> parts;
        XrPosef pose = IdentityPose();
        float scale = 1.0f;
        float defaultScale = 1.0f;
        float yaw = 0.0f;
        bool inFront = true;
        Vec3 localCenter{0.0f, 0.5f, 0.0f};
        Vec3 halfExtents{0.5f, 0.5f, 0.5f};
        std::string summary;
        std::string path;
        std::string addonID, addonRevision, addonParentPanel;
        customui::RotationMode addonRotation = customui::RotationMode::Fixed;
        float addonRotationSpeed = 30;
        XrQuaternionf addonBaseOrientation{0, 0, 0, 1};
        bool addonWasGrabbed = false;
        std::chrono::steady_clock::time_point addonRotationStart{};
    };
    std::vector<std::unique_ptr<ModelInstance>> mModels;
    std::map<std::string, std::string> mAddonModelRequests;
    std::chrono::steady_clock::time_point mAddonModelsLastScan{};
    void PollAddonModels();
    void AnimateAddonModels();
    void ReportAddonModel(const std::string& id, const std::string& revision, const char* state, const char* error = nullptr);
    ModelInstance* AddModelFromFile(const std::string& path);
    int mActiveModel = 0;
    int mGrabbedModel = -1;
    int mStretchModel = -1;
    float mStretchModelStartScale = 1.0f;
    float mStretchModelStartDist = 0.2f;
    int mModelPopupModel = -1;
    int mModelPopupHoveredButton = -1;
    int mRenderedModelPopupModel = -2;
    int mRenderedModelPopupButton = -2;
    float mRenderedModelPopupScale = -1.0f;
    bool mRenderedModelPopupInFront = false;
    float mModelPopupWidth = 0.68f;
    float mModelPopupHeight = 0.17f;
    WristClockSettings mClockSettings;
    int mSettingsTab = 0;
    void ClockSettingsChanged();

    PassthroughSettings mPassthrough;
    int PassthroughPanel() const;
    bool PanelLocked(int index) const;
    void SetPassthroughLocked(bool locked);
    void SetPassthroughShown(bool shown);
    void RemovePanelAt(int index);
    void UpdatePassthroughPanel(Panel& panel);
    void UpdatePassthroughLens(Panel& panel);
    bool EnsurePassthroughCalibration();
    bool LensFor(int camera, Newt::Session::PassthroughLens& lens) const;
    void DrawPassthroughSeeThrough(VkCommandBuffer cmd, const Mat4& viewProj, const XrPosef& eyePose,
                                   const XrPosef& pose, const Panel& panel, int camera);
    void UpdatePassthroughAnchor(const Newt::InputState& input);
    void DrawPassthroughFrame(VkCommandBuffer cmd, const Mat4& viewProj, const Panel& panel);
    void DrawPassthroughEdges(VkCommandBuffer cmd, const Mat4& viewProj, const Panel& panel, const float* quad,
                              float border, float back, float front, const Vec4 colors[4]);
    void HandleInput(const Newt::InputState& input);

    std::vector<Vec3> mTracePoints;
    std::array<Vec3, 2> mTraceCursor{};
    std::array<bool, 2> mTraceCursorValid{false, false};
    int mTraceHand = -1;
    std::array<bool, 2> mTracePrevSelect{false, false};
    Texture mTraceTexture;
    std::string mTracePrompt, mTraceRenderedPrompt;
    std::array<bool, 2> mTracePrevGrip{false, false};
    std::array<bool, 2> mTraceHold{false, false};
    void UpdateTracePrompt(const char* lead = nullptr);
    void OpenPassthroughSettings();
    void StartTracing();
    void StopTracing(const std::string& notice);
    void UpdateTracing(Newt::InputState& input);
    void FinishTracing();
    void DrawTracing(VkCommandBuffer cmd, const Mat4& viewProj);
    void DrawWorldSegment(VkCommandBuffer cmd, const Mat4& viewProj, const Vec3& a, const Vec3& b, float thickness,
                          const Vec4& color);
    void StorePassthroughPlacement(const Panel& panel);
    void PlacePassthroughForDirection(Panel& panel);
    XrPosef mLastViewer = IdentityPose();
    bool mLastViewerValid = false;
    bool (*mPassthroughCamera)(int, PassthroughCamera*) = nullptr;

    bool (*mPassthroughCopyEx)(uint64_t*, void**, void**, int64_t*) = nullptr;
    bool (*mHeadPoseAt)(int64_t, float*) = nullptr;
    bool (*mHeadLatest)(int64_t*, float*, float*) = nullptr;
    XrPosef mCaptureHead = IdentityPose();
    bool mCaptureHeadValid = false;
    XrPosef mStageFromRuntime = IdentityPose();
    bool mStageFromRuntimeValid = false;
    void UpdateStageFromRuntime(const Newt::InputState& input);
    PassthroughCamera mPassthroughCameras[2];
    bool mPassthroughCalibrated = false;

    Newt::GPUTexture mCameraLeft, mCameraRight;
    uint32_t mCameraWidth = 0, mCameraHeight = 0;
    int64_t mCaptureNs = 0;
    std::chrono::steady_clock::time_point mCameraReceivedAt{};
    bool FetchCameraFrames();
    void UpdateCameraRequest();

    bool (*mHandJointsAt)(int, int64_t, float*) = nullptr;
    std::array<std::array<XrPosef, XR_HAND_JOINT_COUNT_EXT>, 2> mHandJoints{};
    std::array<bool, 2> mHandJointsValid{false, false};
    Buffer mHandTube, mHandBall;
    uint32_t mHandTubeCount = 0, mHandBallCount = 0;
    bool mCameraHandsLogged = false;
    bool CameraHandsActive() const;
    void SetCameraHands(int mode);

    std::array<float, 3> mContentHome{0, 0, 0};
    uint32_t (*mSystemHolds)() = nullptr;
    void* mRecenterRuntime = nullptr;
    uint32_t mSystemHoldsSeen = 0;
    std::chrono::steady_clock::time_point mSystemHoldsLookup{};
    void PollRecenterButton();
    void RecenterContent();
    void ReleaseRecenterRuntime();

    systemaudio::Settings mAudio = systemaudio::Load();
    std::unique_ptr<SystemAudio> mSystemAudio;
    void* mSystemAudioRuntime = nullptr;
    std::chrono::steady_clock::time_point mSystemAudioLookup{};
    void PollSystemAudio();
    void SetAudioMode(int mode);
    void ReloadAudioSettings();
    void ReleaseSystemAudio();

    static constexpr int kRecenterSteps = 32;
    float (*mSystemHoldProgress)(int) = nullptr;
    std::array<float, 2> mRecenterHandProgress{-1, -1};
    std::chrono::steady_clock::time_point mRecenterDoneAt{};
    int mRecenterRingStep = -1, mRecenterRenderedStep = -1;
    Texture mRecenterRingTexture;
    void UpdateRecenterRing();
    void RenderRecenterRing();
    void DrawRecenterRing(const Newt::EyeFrame& eye);


    bool HandOutlineActive() const;
    void SubmitHandMask(CVPixelBufferRef left, CVPixelBufferRef right, int64_t captureNs);
    void SubmitHandStereo(CVPixelBufferRef left, CVPixelBufferRef right, int64_t captureNs);
    bool mStereoRigRequested = false;
    bool mHandStereoReadyLogged = false;
    int mHandStereoLogs = 0;
    int64_t mHandStereoLogNs = 0;
    void UpdateHandMask();
    void DropHandMask();
    uint64_t mHandMaskSequence = 0;
    Newt::GPUTexture mHandMaskTexture[2];
    bool mHandMaskFound[2][2] = {};
    int64_t mHandMaskNs = 0;
    XrPosef mHandMaskHead = IdentityPose();
    bool mHandMaskHeadValid = false;
    std::array<std::array<XrPosef, XR_HAND_JOINT_COUNT_EXT>, 2> mHandMaskJoints{};
    std::array<bool, 2> mHandMaskJointsValid{false, false};
    bool mHandMaskLogged = false;

    bool (*mCopyFloat)(int, uint64_t*, float*, int, int*, int*, int64_t*) = nullptr;
    void ProbeFloatDepth();
    uint64_t mFloatProbeSeq[2] = {};
    int64_t mFloatProbeStartNs = 0, mFloatProbeLastNs = 0;
    bool mFloatProbeDone = false;
    void DrawCameraHands(VkCommandBuffer cmd, const Mat4& viewProj, int camera);

    bool mFollowValid = false;
    Vec3 mFollowOffset{};
    float mFollowYaw = 0;
    bool mFollowMoving = false;
    std::chrono::steady_clock::time_point mFollowLast{};
    bool ResolvePassthroughRuntime();
    void ReleasePassthroughRuntime();
    void* mPassthroughRuntime = nullptr;
    bool (*mPassthroughCopy)(uint64_t*, void**, void**) = nullptr;
    void (*mPassthroughRequest)(bool) = nullptr;
    uint64_t mPassthroughSeq = 0;
    bool mPassthroughLogged = false;
    std::array<WristClockGesture, 2> mWristGestures;
    int mClockHand = -1;
    XrPosef mClockPose = IdentityPose();
    Texture mWristClockTexture;
    std::chrono::steady_clock::time_point mLastClockUpdate{};
    std::string mClockRenderedText;
    bool mShowMetrics = false;
    uint64_t mMetricsFramesPrepared = 0;
    std::chrono::steady_clock::time_point mLastPrepareStart{};
    std::chrono::steady_clock::time_point mPrepareStart{};
    bool mHaveLastPrepareStart = false;
    float mLastPeriodMs = 0.0f;
    float mFrameBudgetMs = 0.0f;
    std::chrono::steady_clock::time_point mLastMetricsUpdate{}, mMetricBucketStart{}, mLatestEncodeTime{};
    double mMetricPeriodSum = 0, mMetricDrawSum = 0, mMetricPrepareSum = 0;
    uint32_t mMetricBucketCount = 0;
    float mAveragePeriodMs = 0, mAverageDrawMs = 0, mAveragePrepareMs = 0;
    std::array<double, 120> mMetricTimeHistory{};
    float mLastPrepareMs = 0.0f;
    float mLastDrawMs = 0.0f;
    std::array<float, 120> mMetricPeriodHistory{};
    std::array<float, 120> mMetricDrawHistory{};
    std::array<float, 120> mMetricEncodeHistory{};
    size_t mMetricHistoryCount = 0;
    size_t mMetricHistoryNext = 0;
    std::string mMetricsFilePath;
    uint64_t mMetricsFileOffset = 0;
    bool mMetricsFilePrimed = false;
    std::string mMetricsPartialLine;
    float mLatestEncodeStageMs = -1.0f;
    float mLatestTxMs = -1.0f;
    uint64_t mLatestEncodedFrames = 0;
    int ModelHit(const XrPosef& ray, int& modelIndex, float& distance);
    void RemoveModel(int index);
    void ClearEnvironmentModel();
    XrPosef ModelPopupPose(const ModelInstance& model);
    int ModelPopupHit(const XrPosef& ray, int& modelIndex, int& button, float& distance);
    void ActivateModelPopupButton(int modelIndex, int button, int hand = -1);
    void UpdateModelPopupCandidate();
    void PushMetricSample();
    void PollQuestLinkMetrics();
    MetricsSnapshot MakeMetricsSnapshot() const;
    Texture mMenuTexture, mContentTexture, mLogoTexture, mBarTexture, mModelPopupTexture, mMetricsTexture;


    std::array<bool, 2> mGrabbing{false, false};
    std::array<XrPosef, 2> mGrabOffsets{};
    int mGrabbedPanel = -1;
    int mGrabHand = -1;
    int mGrabZone = 1;


    bool mStretchActive = false;
    int mStretchPanel = -1;
    float mStretchStartWidth = 0;
    float mStretchStartHeight = 0;
    float mStretchStartDeltaX = 0;
    float mStretchStartDeltaY = 0;
    std::chrono::steady_clock::time_point mLastInput{};
    XrPosef mViewerPose = IdentityPose();
    std::array<XrPosef, 2> mAimPoses{};
    std::array<XrPosef, 2> mGripPoses{};
    std::array<RayActivity, 2> mRayActivity;
    std::array<float, 2> mRayAlpha{};
    float mCursorAlpha = 0;
    std::array<bool, 2> mAimValid{false, false};
    std::array<bool, 2> mGripValid{false, false};

    bool mMenuOpen = true;
    bool mRecenterMenu = true;
    XrPosef mDashboardPose = IdentityPose();
    std::string mNotice = "Add Screen creates an independent Mac desktop";
    int mSelected = 0;
    int mRenderedMenuSelected = -1;
    int mControllerBattery[2] = {-1, -1};
    int (*mControllerBatteryPercent)(int) = nullptr;
    void* mBatteryRuntime = nullptr;
    std::chrono::steady_clock::time_point mBatteryPoll{};
    Page mPage = Page::Screens;
    Page mRenderedPage = Page::Screens;
    bool mContentDirty = true;
    Vec3 mCursor{0, 0, 0};
    bool mCursorValid = false;
    std::chrono::steady_clock::time_point mLastNav{};

    const Vec3 mContentCenter{0.0f, 0.05f, -1.55f};
    const float mContentWidth = 1.4f;
    const float mContentHeight = 0.875f;
};

#endif
