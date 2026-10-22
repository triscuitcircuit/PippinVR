#ifndef NEWT_NEWTXRAPP_H
#define NEWT_NEWTXRAPP_H

#include "Newt/Capture.h"
#include "Newt/Session.h"
#include "UI.h"
#include "RayActivity.h"

#include <array>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <string>
#include <vector>
#include <memory>
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
        Newt::TextureRegion gpuRegion;
        Texture badgeTexture;
        std::string badgeLabel;
        bool gpuPathLogged = false;
        std::unique_ptr<ScreenCaptureManager> screen;
        std::unique_ptr<MediaCaptureManager> camera;
        FrameSource& Source() { return screen ? static_cast<FrameSource&>(*screen) : static_cast<FrameSource&>(*camera); }
        uint64_t sequence = 0;
        XrPosef pose = IdentityPose();
        float width = 1.8f;
        float height = 1.8f * 0.625f; // independent of width once resized via a corner drag
        float curvature = 0, builtCurvature = -1;
        std::array<Buffer,6> meshes;
        int stereoMode = 0;
    };
    std::vector<std::string> mApps;
    std::vector<std::unique_ptr<Panel>> mPanels;
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
    Buffer mCubeBuffer, mGridBuffer, mRayBuffer, mDockBuffer;
    std::array<Buffer,18> mButtonFaces, mButtonBodies;
    uint32_t mCubeCount = 0, mGridCount = 0;
    Texture mEnvironmentTexture;
    Buffer mEnvironmentMesh;
    uint32_t mEnvironmentMeshCount = 0;
    bool mHasEnvironment = false;
    PixelImage mEnvironmentImage;
    Texture mMenuTexture, mContentTexture, mLogoTexture, mBarTexture;


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

#endif // NEWT_NEWTXRAPP_H
