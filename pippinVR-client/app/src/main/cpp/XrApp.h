#ifndef PIPPINVR_XR_APP_H
#define PIPPINVR_XR_APP_H

#include <array>
#include <cstdint>
#include <memory>
#include <mutex>
#include <vector>

#include <EGL/egl.h>
#include <GLES3/gl3.h>
#include <jni.h>

#include <openxr/openxr.h>
#include <openxr/openxr_platform.h>

#include "Background.h"
#include "Decoder.h"
#include "Input.h"
#include "Math.h"
#include "Net.h"
#include "Renderer.h"

struct android_app;

namespace pippinvr {

enum class BarZone : int32_t {
    None = -1,
    RotateLeft = 0,
    Drag = 1,
    FaceMe = 2,
    RotateRight = 3,
};

struct Panel {
    uint8_t streamId = 0;
    int32_t width = 0;
    int32_t height = 0;

    XrSwapchain swapchain = XR_NULL_HANDLE;
    std::vector<XrSwapchainImageOpenGLESKHR> images;

    Pose pose;
    XrExtent2Df size{};
    XrSwapchain barSwapchain = XR_NULL_HANDLE;
    std::vector<XrSwapchainImageOpenGLESKHR> barImages;
    Pose barPose;
    XrExtent2Df barSize{};
    BarZone hoveredZone = BarZone::None;
    BarZone activeZone = BarZone::None;

    StreamDecoder* decoder = nullptr;
};

struct Grab {
    bool active = false;
    size_t panelIndex = 0;
    Pose panelInHand;
    float distance = 0.0f;
    BarZone zone = BarZone::Drag;
};

class XrApp {
public:
    XrApp() = default;
    ~XrApp();

    XrApp(const XrApp&) = delete;
    XrApp& operator=(const XrApp&) = delete;

    bool createInstance(android_app* app);

    bool createSession();
    void destroySession();

    bool pollEvents(bool* exitRequested);

    void renderFrame();

    bool sessionRunning() const { return sessionRunning_; }
    bool hasSession() const { return session_ != XR_NULL_HANDLE; }

    void onStreams(const std::vector<StreamInfo>& streams);
    void onFrame(FramePacket&& packet);

private:
    bool initEgl();
    void destroyEgl();
    bool buildPanels();
    void layOutPanels();
    bool createSwapchainFor(Panel& panel, int64_t format);
    bool createBarSwapchainFor(Panel& panel, int64_t format);
    int64_t chooseSwapchainFormat() const;
    void renderPanel(Panel& panel);
    void renderPanelBar(Panel& panel);
    void updateBarPoses();
    void updateManipulation();
    void updateHandGrab(Hand hand, Grab& grab);
    BarZone pickBarZone(const glm::vec3& origin, const glm::vec3& direction,
                        size_t* hitPanel, float* hitDistance) const;
    void yawPanel(Panel& panel, float radians);

    void facePanelToViewer(Panel& panel);

    android_app* app_ = nullptr;

    XrInstance instance_ = XR_NULL_HANDLE;
    XrSystemId systemId_ = XR_NULL_SYSTEM_ID;
    XrSession session_ = XR_NULL_HANDLE;
    XrSpace space_ = XR_NULL_HANDLE;
    XrSpace viewSpace_ = XR_NULL_HANDLE;
    XrSessionState sessionState_ = XR_SESSION_STATE_UNKNOWN;
    bool sessionRunning_ = false;

    XrFrameState frameState_{XR_TYPE_FRAME_STATE};

    EGLDisplay eglDisplay_ = EGL_NO_DISPLAY;
    EGLContext eglContext_ = EGL_NO_CONTEXT;
    EGLSurface eglSurface_ = EGL_NO_SURFACE;
    EGLConfig eglConfig_ = nullptr;

    Renderer renderer_;
    Input input_;
    Background background_;

    bool passthroughAvailable_ = false;
    bool equirectAvailable_ = false;

    std::array<Grab, 2> grabs_{};

    std::mutex streamsMutex_;
    std::vector<StreamInfo> pendingStreams_;
    bool streamsDirty_ = false;

    std::mutex decodersMutex_;
    std::vector<std::unique_ptr<StreamDecoder>> decoders_;


    std::vector<Panel> panels_;

    uint64_t frameIndex_ = 0;
};

}  // namespace pippinvr

#endif  // PIPPINVR_XR_APP_H
