#include "XrApp.h"
#include "Log.h"

#include <android_native_app_glue.h>

#include <cmath>
#include <cstring>

namespace pippinvr {
namespace {

/// Panels sit on an arc this far from the user, spanning this much horizontal angle
/// each. Roughly a comfortable multi-monitor desk setup.
constexpr float kPanelDistanceMeters = 2.0f;
constexpr float kPanelWidthMeters = 1.6f;
constexpr float kPanelGapRadians = 0.62f;   // ~35 degrees between panel centres

constexpr int64_t kFormatSRGBA8 = 0x8C43;   // GL_SRGB8_ALPHA8
constexpr int64_t kFormatRGBA8 = 0x8058;    // GL_RGBA8

/// Handle bar geometry. The bar hangs just above the panel's top edge and shares
/// its orientation, so it reads as part of the window.
constexpr int32_t kBarTexWidth = 1024;
constexpr int32_t kBarTexHeight = 64;
constexpr float kBarHeightMeters = 0.075f;
constexpr float kBarGapMeters = 0.02f;

/// Yaw applied per frame while a rotate handle is held, and per unit of thumbstick.
constexpr float kRotateHandleRadiansPerFrame = 0.018f;
constexpr float kRotateStickRadiansPerFrame = 0.025f;

constexpr float kBarRotateZoneWidth = 0.12f;
constexpr float kBarFaceZoneWidth = 0.10f;

BarZone zoneAtU(float u) {
    if (u < kBarRotateZoneWidth) return BarZone::RotateLeft;
    if (u > 1.0f - kBarRotateZoneWidth) return BarZone::RotateRight;
    if (u > 1.0f - kBarRotateZoneWidth - kBarFaceZoneWidth) return BarZone::FaceMe;
    return BarZone::Drag;
}

bool xrCheck(XrResult result, const char* what) {
    if (XR_SUCCEEDED(result)) return true;
    LOGE("%s failed: XrResult %d", what, static_cast<int>(result));
    return false;
}

XrPosef identityPose() {
    XrPosef pose{};
    pose.orientation.w = 1.0f;
    return pose;
}

}  // namespace

XrApp::~XrApp() {
    destroySession();
    if (instance_ != XR_NULL_HANDLE) {
        xrDestroyInstance(instance_);
        instance_ = XR_NULL_HANDLE;
    }
}

bool XrApp::createInstance(android_app* app) {
    app_ = app;

    PFN_xrInitializeLoaderKHR xrInitializeLoaderKHR = nullptr;
    if (XR_FAILED(xrGetInstanceProcAddr(
            XR_NULL_HANDLE, "xrInitializeLoaderKHR",
            reinterpret_cast<PFN_xrVoidFunction*>(&xrInitializeLoaderKHR))) ||
        xrInitializeLoaderKHR == nullptr) {
        LOGE("xrInitializeLoaderKHR unavailable -- no OpenXR runtime installed?");
        return false;
    }

    XrLoaderInitInfoAndroidKHR loaderInit{XR_TYPE_LOADER_INIT_INFO_ANDROID_KHR};
    loaderInit.applicationVM = app->activity->vm;
    loaderInit.applicationContext = app->activity->clazz;
    if (!xrCheck(xrInitializeLoaderKHR(
                     reinterpret_cast<const XrLoaderInitInfoBaseHeaderKHR*>(&loaderInit)),
                 "xrInitializeLoaderKHR")) {
        return false;
    }

    std::vector<const char*> extensions = {
        XR_KHR_OPENGL_ES_ENABLE_EXTENSION_NAME,
        XR_KHR_ANDROID_CREATE_INSTANCE_EXTENSION_NAME,
    };

    {
        uint32_t extensionCount = 0;
        xrEnumerateInstanceExtensionProperties(nullptr, 0, &extensionCount, nullptr);
        std::vector<XrExtensionProperties> available(
            extensionCount, XrExtensionProperties{XR_TYPE_EXTENSION_PROPERTIES});
        xrEnumerateInstanceExtensionProperties(nullptr, extensionCount, &extensionCount,
                                               available.data());

        auto supported = [&](const char* name) {
            for (const auto& property : available) {
                if (std::strcmp(property.extensionName, name) == 0) return true;
            }
            return false;
        };

        if (supported(XR_FB_PASSTHROUGH_EXTENSION_NAME)) {
            extensions.push_back(XR_FB_PASSTHROUGH_EXTENSION_NAME);
            passthroughAvailable_ = true;
        } else {
            LOGW("XR_FB_passthrough unsupported; desk passthrough disabled");
        }

        if (supported(XR_KHR_COMPOSITION_LAYER_EQUIRECT2_EXTENSION_NAME)) {
            extensions.push_back(XR_KHR_COMPOSITION_LAYER_EQUIRECT2_EXTENSION_NAME);
            equirectAvailable_ = true;
        } else {
            LOGW("XR_KHR_composition_layer_equirect2 unsupported; panorama disabled");
        }
    }

    XrInstanceCreateInfoAndroidKHR androidInfo{XR_TYPE_INSTANCE_CREATE_INFO_ANDROID_KHR};
    androidInfo.applicationVM = app->activity->vm;
    androidInfo.applicationActivity = app->activity->clazz;

    XrInstanceCreateInfo createInfo{XR_TYPE_INSTANCE_CREATE_INFO};
    createInfo.next = &androidInfo;
    createInfo.enabledExtensionCount = static_cast<uint32_t>(extensions.size());
    createInfo.enabledExtensionNames = extensions.data();
    std::strncpy(createInfo.applicationInfo.applicationName, "PippinVr",
                 XR_MAX_APPLICATION_NAME_SIZE - 1);
    createInfo.applicationInfo.applicationVersion = 1;
    std::strncpy(createInfo.applicationInfo.engineName, "pippinvr",
                 XR_MAX_ENGINE_NAME_SIZE - 1);
    createInfo.applicationInfo.engineVersion = 1;
    createInfo.applicationInfo.apiVersion = XR_CURRENT_API_VERSION;

    if (!xrCheck(xrCreateInstance(&createInfo, &instance_), "xrCreateInstance")) {
        return false;
    }

    XrSystemGetInfo systemInfo{XR_TYPE_SYSTEM_GET_INFO};
    systemInfo.formFactor = XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY;
    if (!xrCheck(xrGetSystem(instance_, &systemInfo, &systemId_), "xrGetSystem")) {
        return false;
    }

    XrInstanceProperties props{XR_TYPE_INSTANCE_PROPERTIES};
    if (XR_SUCCEEDED(xrGetInstanceProperties(instance_, &props))) {
        LOGI("OpenXR runtime: %s", props.runtimeName);
    }

    if (!input_.init(instance_)) {
        LOGW("input init failed; panels will not be movable");
    }
    return true;
}

bool XrApp::initEgl() {
    eglDisplay_ = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (eglDisplay_ == EGL_NO_DISPLAY) {
        LOGE("eglGetDisplay failed");
        return false;
    }
    if (eglInitialize(eglDisplay_, nullptr, nullptr) != EGL_TRUE) {
        LOGE("eglInitialize failed");
        return false;
    }

    const EGLint configAttribs[] = {
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT_KHR,
        EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_ALPHA_SIZE, 8,
        EGL_DEPTH_SIZE, 0, EGL_STENCIL_SIZE, 0,
        EGL_NONE};

    EGLint numConfigs = 0;
    if (eglChooseConfig(eglDisplay_, configAttribs, &eglConfig_, 1, &numConfigs) !=
            EGL_TRUE ||
        numConfigs < 1) {
        LOGE("eglChooseConfig found no usable config");
        return false;
    }

    const EGLint contextAttribs[] = {EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE};
    eglContext_ = eglCreateContext(eglDisplay_, eglConfig_, EGL_NO_CONTEXT,
                                   contextAttribs);
    if (eglContext_ == EGL_NO_CONTEXT) {
        LOGE("eglCreateContext failed (0x%04x)", eglGetError());
        return false;
    }

    const EGLint surfaceAttribs[] = {EGL_WIDTH, 16, EGL_HEIGHT, 16, EGL_NONE};
    eglSurface_ = eglCreatePbufferSurface(eglDisplay_, eglConfig_, surfaceAttribs);
    if (eglSurface_ == EGL_NO_SURFACE) {
        LOGE("eglCreatePbufferSurface failed (0x%04x)", eglGetError());
        return false;
    }

    if (eglMakeCurrent(eglDisplay_, eglSurface_, eglSurface_, eglContext_) != EGL_TRUE) {
        LOGE("eglMakeCurrent failed (0x%04x)", eglGetError());
        return false;
    }

    LOGI("EGL ready: %s", glGetString(GL_VERSION));
    return true;
}

void XrApp::destroyEgl() {
    if (eglDisplay_ == EGL_NO_DISPLAY) return;
    eglMakeCurrent(eglDisplay_, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    if (eglSurface_ != EGL_NO_SURFACE) eglDestroySurface(eglDisplay_, eglSurface_);
    if (eglContext_ != EGL_NO_CONTEXT) eglDestroyContext(eglDisplay_, eglContext_);
    eglTerminate(eglDisplay_);
    eglSurface_ = EGL_NO_SURFACE;
    eglContext_ = EGL_NO_CONTEXT;
    eglDisplay_ = EGL_NO_DISPLAY;
}

bool XrApp::createSession() {
    if (session_ != XR_NULL_HANDLE) return true;

    // Required by spec before session creation, even though we ignore the versions.
    PFN_xrGetOpenGLESGraphicsRequirementsKHR getRequirements = nullptr;
    if (XR_FAILED(xrGetInstanceProcAddr(
            instance_, "xrGetOpenGLESGraphicsRequirementsKHR",
            reinterpret_cast<PFN_xrVoidFunction*>(&getRequirements))) ||
        getRequirements == nullptr) {
        LOGE("xrGetOpenGLESGraphicsRequirementsKHR unavailable");
        return false;
    }
    XrGraphicsRequirementsOpenGLESKHR requirements{
        XR_TYPE_GRAPHICS_REQUIREMENTS_OPENGL_ES_KHR};
    getRequirements(instance_, systemId_, &requirements);

    if (!initEgl()) return false;
    if (!renderer_.init()) return false;

    XrGraphicsBindingOpenGLESAndroidKHR binding{
        XR_TYPE_GRAPHICS_BINDING_OPENGL_ES_ANDROID_KHR};
    binding.display = eglDisplay_;
    binding.config = eglConfig_;
    binding.context = eglContext_;

    XrSessionCreateInfo createInfo{XR_TYPE_SESSION_CREATE_INFO};
    createInfo.next = &binding;
    createInfo.systemId = systemId_;
    if (!xrCheck(xrCreateSession(instance_, &createInfo, &session_),
                 "xrCreateSession")) {
        return false;
    }

    // LOCAL is head-relative-at-startup, which is what we want for panels that stay
    // where the user put them rather than following the head.
    XrReferenceSpaceCreateInfo spaceInfo{XR_TYPE_REFERENCE_SPACE_CREATE_INFO};
    spaceInfo.referenceSpaceType = XR_REFERENCE_SPACE_TYPE_LOCAL;
    spaceInfo.poseInReferenceSpace = identityPose();
    if (!xrCheck(xrCreateReferenceSpace(session_, &spaceInfo, &space_),
                 "xrCreateReferenceSpace")) {
        return false;
    }

    // VIEW space tracks the headset; needed by the "face me" handle.
    XrReferenceSpaceCreateInfo viewInfo{XR_TYPE_REFERENCE_SPACE_CREATE_INFO};
    viewInfo.referenceSpaceType = XR_REFERENCE_SPACE_TYPE_VIEW;
    viewInfo.poseInReferenceSpace = identityPose();
    if (XR_FAILED(xrCreateReferenceSpace(session_, &viewInfo, &viewSpace_))) {
        LOGW("VIEW space unavailable; 'face me' handle disabled");
        viewSpace_ = XR_NULL_HANDLE;
    }

    input_.attach(session_, space_);

    background_.setAvailability(passthroughAvailable_, equirectAvailable_);
    background_.init(instance_, session_, space_);
    background_.loadPanorama("/sdcard/Download/pippinvr-panorama.jpg");

    LOGI("session created");
    return true;
}

void XrApp::destroySession() {
    for (Panel& panel : panels_) {
        if (panel.swapchain != XR_NULL_HANDLE) xrDestroySwapchain(panel.swapchain);
        if (panel.barSwapchain != XR_NULL_HANDLE) xrDestroySwapchain(panel.barSwapchain);
    }
    panels_.clear();
    {
        std::lock_guard<std::mutex> lock(decodersMutex_);
        decoders_.clear();
    }

    background_.shutdown();
    input_.shutdown();
    renderer_.shutdown();

    if (viewSpace_ != XR_NULL_HANDLE) {
        xrDestroySpace(viewSpace_);
        viewSpace_ = XR_NULL_HANDLE;
    }
    if (space_ != XR_NULL_HANDLE) {
        xrDestroySpace(space_);
        space_ = XR_NULL_HANDLE;
    }
    if (session_ != XR_NULL_HANDLE) {
        xrDestroySession(session_);
        session_ = XR_NULL_HANDLE;
    }
    destroyEgl();
    sessionRunning_ = false;
}

void XrApp::onStreams(const std::vector<StreamInfo>& streams) {
    std::lock_guard<std::mutex> lock(streamsMutex_);
    pendingStreams_ = streams;
    streamsDirty_ = true;
    LOGI("session header: %zu stream(s) pending panel setup", streams.size());
}

void XrApp::onFrame(FramePacket&& packet) {
    std::lock_guard<std::mutex> lock(decodersMutex_);
    for (auto& decoder : decoders_) {
        if (decoder->info().id == packet.streamId) {
            decoder->submit(std::move(packet));
            return;
        }
    }
}

int64_t XrApp::chooseSwapchainFormat() const {
    uint32_t count = 0;
    if (XR_FAILED(xrEnumerateSwapchainFormats(session_, 0, &count, nullptr)) ||
        count == 0) {
        return kFormatRGBA8;
    }
    std::vector<int64_t> formats(count);
    if (XR_FAILED(xrEnumerateSwapchainFormats(session_, count, &count,
                                              formats.data()))) {
        return kFormatRGBA8;
    }
    for (int64_t format : formats) {
        if (format == kFormatSRGBA8) return format;
    }
    for (int64_t format : formats) {
        if (format == kFormatRGBA8) return format;
    }
    return formats.front();
}

bool XrApp::createSwapchainFor(Panel& panel, int64_t format) {
    XrSwapchainCreateInfo info{XR_TYPE_SWAPCHAIN_CREATE_INFO};
    info.usageFlags = XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT |
                      XR_SWAPCHAIN_USAGE_SAMPLED_BIT;
    info.format = format;
    info.sampleCount = 1;
    info.width = static_cast<uint32_t>(panel.width);
    info.height = static_cast<uint32_t>(panel.height);
    info.faceCount = 1;
    info.arraySize = 1;
    info.mipCount = 1;

    if (!xrCheck(xrCreateSwapchain(session_, &info, &panel.swapchain),
                 "xrCreateSwapchain")) {
        return false;
    }

    uint32_t imageCount = 0;
    if (!xrCheck(xrEnumerateSwapchainImages(panel.swapchain, 0, &imageCount, nullptr),
                 "xrEnumerateSwapchainImages")) {
        return false;
    }

    panel.images.assign(imageCount,
                        XrSwapchainImageOpenGLESKHR{
                            XR_TYPE_SWAPCHAIN_IMAGE_OPENGL_ES_KHR});
    if (!xrCheck(xrEnumerateSwapchainImages(
                     panel.swapchain, imageCount, &imageCount,
                     reinterpret_cast<XrSwapchainImageBaseHeader*>(panel.images.data())),
                 "xrEnumerateSwapchainImages")) {
        return false;
    }

    LOGI("stream %u: swapchain %dx%d, %u images", panel.streamId, panel.width,
         panel.height, imageCount);
    return true;
}

bool XrApp::createBarSwapchainFor(Panel& panel, int64_t format) {
    XrSwapchainCreateInfo info{XR_TYPE_SWAPCHAIN_CREATE_INFO};
    info.usageFlags = XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT |
                      XR_SWAPCHAIN_USAGE_SAMPLED_BIT;
    info.format = format;
    info.sampleCount = 1;
    info.width = static_cast<uint32_t>(kBarTexWidth);
    info.height = static_cast<uint32_t>(kBarTexHeight);
    info.faceCount = 1;
    info.arraySize = 1;
    info.mipCount = 1;

    if (!xrCheck(xrCreateSwapchain(session_, &info, &panel.barSwapchain),
                 "xrCreateSwapchain(bar)")) {
        return false;
    }

    uint32_t imageCount = 0;
    if (!xrCheck(xrEnumerateSwapchainImages(panel.barSwapchain, 0, &imageCount, nullptr),
                 "xrEnumerateSwapchainImages(bar)")) {
        return false;
    }
    panel.barImages.assign(
        imageCount, XrSwapchainImageOpenGLESKHR{XR_TYPE_SWAPCHAIN_IMAGE_OPENGL_ES_KHR});
    return xrCheck(
        xrEnumerateSwapchainImages(
            panel.barSwapchain, imageCount, &imageCount,
            reinterpret_cast<XrSwapchainImageBaseHeader*>(panel.barImages.data())),
        "xrEnumerateSwapchainImages(bar)");
}

void XrApp::renderPanelBar(Panel& panel) {
    if (panel.barSwapchain == XR_NULL_HANDLE) return;

    uint32_t imageIndex = 0;
    XrSwapchainImageAcquireInfo acquireInfo{XR_TYPE_SWAPCHAIN_IMAGE_ACQUIRE_INFO};
    if (XR_FAILED(xrAcquireSwapchainImage(panel.barSwapchain, &acquireInfo,
                                          &imageIndex))) {
        return;
    }

    XrSwapchainImageWaitInfo waitInfo{XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO};
    waitInfo.timeout = XR_INFINITE_DURATION;
    if (XR_SUCCEEDED(xrWaitSwapchainImage(panel.barSwapchain, &waitInfo))) {
        renderer_.drawPanelBar(panel.barImages[imageIndex].image, kBarTexWidth,
                               kBarTexHeight,
                               static_cast<int32_t>(panel.hoveredZone),
                               static_cast<int32_t>(panel.activeZone));
    }

    XrSwapchainImageReleaseInfo releaseInfo{XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO};
    xrReleaseSwapchainImage(panel.barSwapchain, &releaseInfo);
}

void XrApp::layOutPanels() {
    const size_t count = panels_.size();
    if (count == 0) return;

    const float startAngle = -kPanelGapRadians * (static_cast<float>(count) - 1.0f) / 2.0f;

    for (size_t i = 0; i < count; ++i) {
        Panel& panel = panels_[i];
        const float angle = startAngle + kPanelGapRadians * static_cast<float>(i);

        panel.pose.position = glm::vec3(kPanelDistanceMeters * std::sin(angle), 0.0f,
                                        -kPanelDistanceMeters * std::cos(angle));
        panel.pose.orientation =
            glm::angleAxis(angle, glm::vec3(0.0f, 1.0f, 0.0f));

        const float aspect = static_cast<float>(panel.height) /
                             static_cast<float>(panel.width);
        panel.size.width = kPanelWidthMeters;
        panel.size.height = kPanelWidthMeters * aspect;
    }
}

void XrApp::yawPanel(Panel& panel, float radians) {
    const glm::quat spin = glm::angleAxis(radians, glm::vec3(0.0f, 1.0f, 0.0f));
    panel.pose.orientation = glm::normalize(spin * panel.pose.orientation);
}

void XrApp::facePanelToViewer(Panel& panel) {
    if (viewSpace_ == XR_NULL_HANDLE) return;

    XrSpaceLocation location{XR_TYPE_SPACE_LOCATION};
    if (XR_FAILED(xrLocateSpace(viewSpace_, space_, frameState_.predictedDisplayTime,
                                &location))) {
        return;
    }
    if ((location.locationFlags & XR_SPACE_LOCATION_POSITION_VALID_BIT) == 0) return;

    const glm::vec3 toViewer = toGlm(location.pose.position) - panel.pose.position;
    const glm::vec2 flat(toViewer.x, toViewer.z);
    if (glm::length(flat) < 1e-4f) return;

    const float yaw = std::atan2(flat.x, flat.y);
    panel.pose.orientation = glm::angleAxis(yaw, glm::vec3(0.0f, 1.0f, 0.0f));
}

BarZone XrApp::pickBarZone(const glm::vec3& origin, const glm::vec3& direction,
                           size_t* hitPanel, float* hitDistance) const {
    BarZone best = BarZone::None;
    float bestDistance = 0.0f;

    for (size_t i = 0; i < panels_.size(); ++i) {
        const Panel& panel = panels_[i];
        if (panel.barSwapchain == XR_NULL_HANDLE) continue;

        float distance = 0.0f;
        if (!rayQuadIntersect(origin, direction, panel.barPose, panel.barSize.width,
                              panel.barSize.height, &distance)) {
            continue;
        }
        if (best != BarZone::None && distance >= bestDistance) continue;

        // Recover the hit point in bar-local space to work out which zone it is.
        const glm::vec3 hit = origin + direction * distance;
        const glm::vec3 local =
            glm::conjugate(panel.barPose.orientation) * (hit - panel.barPose.position);
        const float u = local.x / panel.barSize.width + 0.5f;

        best = zoneAtU(glm::clamp(u, 0.0f, 1.0f));
        bestDistance = distance;
        *hitPanel = i;
        *hitDistance = distance;
    }
    return best;
}

void XrApp::updateHandGrab(Hand hand, Grab& grab) {
    const HandState& state = input_.hand(hand);
    if (!state.poseValid) {
        grab.active = false;
        return;
    }

    const Pose handPose(state.aimPose);
    const glm::vec3 origin = handPose.position;
    const glm::vec3 direction = forwardOf(handPose);

    size_t hoverPanel = 0;
    float hoverDistance = 0.0f;
    const BarZone hoverZone = pickBarZone(origin, direction, &hoverPanel, &hoverDistance);
    if (hoverZone != BarZone::None && hoverPanel < panels_.size()) {
        panels_[hoverPanel].hoveredZone = hoverZone;
    }

    if (state.grabStarted && !grab.active) {
        if (hoverZone != BarZone::None) {
            grab.active = true;
            grab.panelIndex = hoverPanel;
            grab.distance = hoverDistance;
            grab.zone = hoverZone;
            grab.panelInHand = handPose.inverse() * panels_[hoverPanel].pose;

            if (hoverZone == BarZone::FaceMe) {
                facePanelToViewer(panels_[hoverPanel]);
                grab.active = false;
                LOGI("panel %zu turned to face viewer", hoverPanel);
            } else {
                LOGI("grabbed panel %zu (stream %u) zone %d at %.2fm", hoverPanel,
                     panels_[hoverPanel].streamId, static_cast<int>(hoverZone),
                     static_cast<double>(hoverDistance));
            }
        } else {
            float bestDistance = 0.0f;
            size_t bestIndex = 0;
            bool hitAny = false;

            for (size_t i = 0; i < panels_.size(); ++i) {
                float distance = 0.0f;
                if (rayQuadIntersect(origin, direction, panels_[i].pose,
                                     panels_[i].size.width, panels_[i].size.height,
                                     &distance)) {
                    if (!hitAny || distance < bestDistance) {
                        bestDistance = distance;
                        bestIndex = i;
                        hitAny = true;
                    }
                }
            }

            if (hitAny) {
                grab.active = true;
                grab.panelIndex = bestIndex;
                grab.distance = bestDistance;
                grab.zone = BarZone::Drag;
                grab.panelInHand = handPose.inverse() * panels_[bestIndex].pose;
                LOGI("grabbed panel %zu (stream %u) at %.2fm", bestIndex,
                     panels_[bestIndex].streamId, static_cast<double>(bestDistance));
            }
        }
    }

    if (grab.active && !state.grabbing) {
        grab.active = false;
        return;
    }

    if (!grab.active) return;
    if (grab.panelIndex >= panels_.size()) {
        grab.active = false;
        return;
    }

    Panel& held = panels_[grab.panelIndex];
    held.activeZone = grab.zone;

    if (grab.zone == BarZone::RotateLeft || grab.zone == BarZone::RotateRight) {
        const float sign = grab.zone == BarZone::RotateLeft ? 1.0f : -1.0f;
        yawPanel(held, sign * kRotateHandleRadiansPerFrame);
        return;
    }

    if (state.thumbstickX != 0.0f) {
        yawPanel(held, -state.thumbstickX * kRotateStickRadiansPerFrame);
        grab.panelInHand = handPose.inverse() * held.pose;
    }

    if (state.thumbstickY != 0.0f) {
        constexpr float kPushMetersPerFrame = 0.02f;
        const float previous = grab.distance;
        grab.distance = glm::clamp(
            grab.distance + state.thumbstickY * kPushMetersPerFrame, 0.35f, 8.0f);

        const float offsetLength = glm::length(grab.panelInHand.position);
        if (previous > 1e-4f && offsetLength > 1e-4f) {
            grab.panelInHand.position *= (grab.distance / previous);
        }
    }

    panels_[grab.panelIndex].pose = handPose * grab.panelInHand;
}

void XrApp::updateBarPoses() {
    for (Panel& panel : panels_) {
        const float offsetY =
            panel.size.height * 0.5f + kBarGapMeters + kBarHeightMeters * 0.5f;
        panel.barPose.orientation = panel.pose.orientation;
        panel.barPose.position =
            panel.pose.position + panel.pose.orientation * glm::vec3(0.0f, offsetY, 0.0f);
        panel.barSize.width = panel.size.width;
        panel.barSize.height = kBarHeightMeters;
    }
}

void XrApp::updateManipulation() {
    if (input_.backgroundCyclePressed()) background_.cycleMode();
    if (input_.layoutResetPressed()) {
        layOutPanels();
        for (Grab& grab : grabs_) grab.active = false;
        LOGI("panel layout reset");
    }

    for (Panel& panel : panels_) {
        panel.hoveredZone = BarZone::None;
        panel.activeZone = BarZone::None;
    }

    updateHandGrab(Hand::Left, grabs_[0]);
    updateHandGrab(Hand::Right, grabs_[1]);

    updateBarPoses();
}

bool XrApp::buildPanels() {
    std::vector<StreamInfo> streams;
    {
        std::lock_guard<std::mutex> lock(streamsMutex_);
        if (!streamsDirty_) return true;
        streams = pendingStreams_;
        streamsDirty_ = false;
    }

    for (Panel& panel : panels_) {
        if (panel.swapchain != XR_NULL_HANDLE) xrDestroySwapchain(panel.swapchain);
        if (panel.barSwapchain != XR_NULL_HANDLE) xrDestroySwapchain(panel.barSwapchain);
    }
    panels_.clear();
    {
        std::lock_guard<std::mutex> lock(decodersMutex_);
        decoders_.clear();
    }

    const int64_t format = chooseSwapchainFormat();

    std::vector<std::unique_ptr<StreamDecoder>> built;
    for (const StreamInfo& info : streams) {
        auto decoder = std::make_unique<StreamDecoder>();
        if (!decoder->init(info)) {
            LOGE("stream %u: decoder init failed; skipping", info.id);
            continue;
        }

        Panel panel;
        panel.streamId = info.id;
        panel.width = info.width;
        panel.height = info.height;
        panel.decoder = decoder.get();

        if (!createSwapchainFor(panel, format)) {
            LOGE("stream %u: swapchain creation failed; skipping", info.id);
            continue;
        }
        if (!createBarSwapchainFor(panel, format)) {
            LOGW("stream %u: handle bar unavailable", info.id);
        }

        built.push_back(std::move(decoder));
        panels_.push_back(std::move(panel));
    }

    {
        std::lock_guard<std::mutex> lock(decodersMutex_);
        decoders_ = std::move(built);
    }

    layOutPanels();
    updateBarPoses();
    LOGI("built %zu panel(s)", panels_.size());
    return true;
}

void XrApp::renderPanel(Panel& panel) {
    uint32_t imageIndex = 0;
    XrSwapchainImageAcquireInfo acquireInfo{XR_TYPE_SWAPCHAIN_IMAGE_ACQUIRE_INFO};
    if (XR_FAILED(xrAcquireSwapchainImage(panel.swapchain, &acquireInfo, &imageIndex))) {
        return;
    }

    XrSwapchainImageWaitInfo waitInfo{XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO};
    waitInfo.timeout = XR_INFINITE_DURATION;
    if (XR_FAILED(xrWaitSwapchainImage(panel.swapchain, &waitInfo))) {
        XrSwapchainImageReleaseInfo releaseInfo{XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO};
        xrReleaseSwapchainImage(panel.swapchain, &releaseInfo);
        return;
    }

    const GLuint texture = panel.images[imageIndex].image;
    AHardwareBuffer* buffer =
        panel.decoder != nullptr ? panel.decoder->acquireLatest() : nullptr;

    if (buffer != nullptr) {
        renderer_.blit(buffer, texture, panel.width, panel.height);
    } else {
        // Nothing decoded yet: a dim grey panel reads as "connected, waiting".
        renderer_.clear(texture, panel.width, panel.height, 0.05f, 0.05f, 0.07f);
    }

    XrSwapchainImageReleaseInfo releaseInfo{XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO};
    xrReleaseSwapchainImage(panel.swapchain, &releaseInfo);
}

void XrApp::renderFrame() {
    if (!sessionRunning_) return;

    XrFrameWaitInfo waitInfo{XR_TYPE_FRAME_WAIT_INFO};
    frameState_ = XrFrameState{XR_TYPE_FRAME_STATE};
    if (XR_FAILED(xrWaitFrame(session_, &waitInfo, &frameState_))) return;

    XrFrameBeginInfo beginInfo{XR_TYPE_FRAME_BEGIN_INFO};
    if (XR_FAILED(xrBeginFrame(session_, &beginInfo))) return;

    // Panels are (re)built on the render thread so all GL/XR calls stay on one thread.
    buildPanels();

    input_.update(session_, frameState_.predictedDisplayTime);
    updateManipulation();

    std::vector<XrCompositionLayerQuad> quads;
    std::vector<XrCompositionLayerBaseHeader*> layers;

    if (frameState_.shouldRender == XR_TRUE) {
        background_.appendLayer(layers);

        quads.reserve(panels_.size() * 2);
        for (Panel& panel : panels_) {
            renderPanel(panel);

            XrCompositionLayerQuad quad{XR_TYPE_COMPOSITION_LAYER_QUAD};
            quad.layerFlags = XR_COMPOSITION_LAYER_BLEND_TEXTURE_SOURCE_ALPHA_BIT;
            quad.space = space_;
            quad.eyeVisibility = XR_EYE_VISIBILITY_BOTH;
            quad.subImage.swapchain = panel.swapchain;
            quad.subImage.imageRect.offset = {0, 0};
            quad.subImage.imageRect.extent = {panel.width, panel.height};
            quad.subImage.imageArrayIndex = 0;
            quad.pose = panel.pose.toXrPose();
            quad.size = panel.size;
            quads.push_back(quad);

            if (panel.barSwapchain != XR_NULL_HANDLE) {
                renderPanelBar(panel);

                XrCompositionLayerQuad bar{XR_TYPE_COMPOSITION_LAYER_QUAD};
                bar.layerFlags = XR_COMPOSITION_LAYER_BLEND_TEXTURE_SOURCE_ALPHA_BIT;
                bar.space = space_;
                bar.eyeVisibility = XR_EYE_VISIBILITY_BOTH;
                bar.subImage.swapchain = panel.barSwapchain;
                bar.subImage.imageRect.offset = {0, 0};
                bar.subImage.imageRect.extent = {kBarTexWidth, kBarTexHeight};
                bar.subImage.imageArrayIndex = 0;
                bar.pose = panel.barPose.toXrPose();
                bar.size = panel.barSize;
                quads.push_back(bar);
            }
        }
        for (XrCompositionLayerQuad& quad : quads) {
            layers.push_back(
                reinterpret_cast<XrCompositionLayerBaseHeader*>(&quad));
        }
    }

    XrFrameEndInfo endInfo{XR_TYPE_FRAME_END_INFO};
    endInfo.displayTime = frameState_.predictedDisplayTime;
    endInfo.environmentBlendMode = XR_ENVIRONMENT_BLEND_MODE_OPAQUE;
    endInfo.layerCount = static_cast<uint32_t>(layers.size());
    endInfo.layers = layers.empty() ? nullptr : layers.data();
    xrEndFrame(session_, &endInfo);

    if ((++frameIndex_ % 300) == 0) {
        std::lock_guard<std::mutex> lock(decodersMutex_);
        for (const auto& decoder : decoders_) {
            LOGI("stream %u: decoded=%llu dropped=%llu", decoder->info().id,
                 static_cast<unsigned long long>(decoder->framesDecoded()),
                 static_cast<unsigned long long>(decoder->framesDropped()));
        }
    }
}

bool XrApp::pollEvents(bool* exitRequested) {
    XrEventDataBuffer event{XR_TYPE_EVENT_DATA_BUFFER};

    for (;;) {
        event = XrEventDataBuffer{XR_TYPE_EVENT_DATA_BUFFER};
        const XrResult result = xrPollEvent(instance_, &event);
        if (result == XR_EVENT_UNAVAILABLE) break;
        if (XR_FAILED(result)) return false;

        switch (event.type) {
            case XR_TYPE_EVENT_DATA_INSTANCE_LOSS_PENDING:
                LOGW("instance loss pending; exiting");
                *exitRequested = true;
                return false;

            case XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED: {
                const auto& changed =
                    *reinterpret_cast<const XrEventDataSessionStateChanged*>(&event);
                sessionState_ = changed.state;
                LOGI("session state -> %d", static_cast<int>(sessionState_));

                if (sessionState_ == XR_SESSION_STATE_READY) {
                    XrSessionBeginInfo beginInfo{XR_TYPE_SESSION_BEGIN_INFO};
                    beginInfo.primaryViewConfigurationType =
                        XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO;
                    if (xrCheck(xrBeginSession(session_, &beginInfo),
                                "xrBeginSession")) {
                        sessionRunning_ = true;
                    }
                } else if (sessionState_ == XR_SESSION_STATE_STOPPING) {
                    sessionRunning_ = false;
                    xrEndSession(session_);
                } else if (sessionState_ == XR_SESSION_STATE_EXITING ||
                           sessionState_ == XR_SESSION_STATE_LOSS_PENDING) {
                    *exitRequested = true;
                    return false;
                }
                break;
            }

            default:
                break;
        }
    }
    return true;
}

}
