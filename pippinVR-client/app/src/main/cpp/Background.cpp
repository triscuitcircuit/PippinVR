#include "Background.h"
#include "Log.h"

#include <SOIL2/SOIL2.h>

#include <cmath>
#include <cstring>

namespace pippinvr {
namespace {

constexpr int64_t kFormatSRGBA8 = 0x8C43;   // GL_SRGB8_ALPHA8
constexpr int64_t kFormatRGBA8 = 0x8058;    // GL_RGBA8

constexpr const char* kSkyVertexShader = R"(#version 300 es
out vec2 vUV;
void main() {
    vec2 p = vec2((gl_VertexID << 1) & 2, gl_VertexID & 2);
    vUV = p;
    gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}
)";

constexpr const char* kSkyFragmentShader = R"(#version 300 es
precision mediump float;
in vec2 vUV;
out vec4 fragColor;
void main() {
    float h = vUV.y;
    vec3 horizon = vec3(0.08, 0.09, 0.12);
    vec3 zenith  = vec3(0.01, 0.02, 0.05);
    vec3 ground  = vec3(0.03, 0.03, 0.035);
    vec3 col = h < 0.5
        ? mix(ground, horizon, smoothstep(0.30, 0.50, h))
        : mix(horizon, zenith, smoothstep(0.50, 0.85, h));
    // Faint longitude banding so head rotation is perceptible.
    col += 0.012 * sin(vUV.x * 6.2831853 * 12.0) * (1.0 - abs(h - 0.5) * 2.0);
    fragColor = vec4(col, 1.0);
}
)";

constexpr const char* kTexFragmentShader = R"(#version 300 es
precision mediump float;
uniform sampler2D uTexture;
in vec2 vUV;
out vec4 fragColor;
void main() {
    // Image origin is top-left, GL's is bottom-left.
    fragColor = texture(uTexture, vec2(vUV.x, 1.0 - vUV.y));
}
)";

GLuint compileShader(GLenum type, const char* source) {
    GLuint shader = glCreateShader(type);
    glShaderSource(shader, 1, &source, nullptr);
    glCompileShader(shader);
    GLint ok = GL_FALSE;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
    if (ok != GL_TRUE) {
        char log[512] = {};
        glGetShaderInfoLog(shader, sizeof(log) - 1, nullptr, log);
        LOGE("sky shader compile failed: %s", log);
        glDeleteShader(shader);
        return 0;
    }
    return shader;
}

bool xrOk(XrResult result, const char* what) {
    if (XR_SUCCEEDED(result)) return true;
    LOGE("%s failed: XrResult %d", what, static_cast<int>(result));
    return false;
}

}  // namespace

const char* backgroundModeName(BackgroundMode mode) {
    switch (mode) {
        case BackgroundMode::Passthrough: return "passthrough";
        case BackgroundMode::Panorama:    return "panorama";
        case BackgroundMode::Black:       return "black";
        default:                          return "?";
    }
}

Background::~Background() { shutdown(); }

void Background::setAvailability(bool passthroughAvailable, bool equirectAvailable) {
    passthroughAvailable_ = passthroughAvailable;
    equirectAvailable_ = equirectAvailable;
}

bool Background::init(XrInstance instance, XrSession session, XrSpace space) {
    instance_ = instance;
    session_ = session;
    space_ = space;

    if (passthroughAvailable_ && !initPassthrough()) {
        LOGW("passthrough init failed; mode disabled");
        passthroughAvailable_ = false;
    }
    if (equirectAvailable_ && !initPanorama()) {
        LOGW("panorama init failed; mode disabled");
        equirectAvailable_ = false;
    }

    mode_ = BackgroundMode::Passthrough;
    if (!passthroughAvailable_) {
        mode_ = equirectAvailable_ ? BackgroundMode::Panorama : BackgroundMode::Black;
    }
    LOGI("background: starting in %s mode (passthrough=%d panorama=%d)",
         backgroundModeName(mode_), passthroughAvailable_ ? 1 : 0,
         equirectAvailable_ ? 1 : 0);
    return true;
}

bool Background::initPassthrough() {
    auto load = [&](const char* name, PFN_xrVoidFunction* fn) {
        return XR_SUCCEEDED(xrGetInstanceProcAddr(instance_, name, fn)) && *fn != nullptr;
    };

    if (!load("xrCreatePassthroughFB",
              reinterpret_cast<PFN_xrVoidFunction*>(&xrCreatePassthroughFB_)) ||
        !load("xrDestroyPassthroughFB",
              reinterpret_cast<PFN_xrVoidFunction*>(&xrDestroyPassthroughFB_)) ||
        !load("xrPassthroughStartFB",
              reinterpret_cast<PFN_xrVoidFunction*>(&xrPassthroughStartFB_)) ||
        !load("xrPassthroughPauseFB",
              reinterpret_cast<PFN_xrVoidFunction*>(&xrPassthroughPauseFB_)) ||
        !load("xrCreatePassthroughLayerFB",
              reinterpret_cast<PFN_xrVoidFunction*>(&xrCreatePassthroughLayerFB_)) ||
        !load("xrDestroyPassthroughLayerFB",
              reinterpret_cast<PFN_xrVoidFunction*>(&xrDestroyPassthroughLayerFB_)) ||
        !load("xrPassthroughLayerResumeFB",
              reinterpret_cast<PFN_xrVoidFunction*>(&xrPassthroughLayerResumeFB_)) ||
        !load("xrPassthroughLayerPauseFB",
              reinterpret_cast<PFN_xrVoidFunction*>(&xrPassthroughLayerPauseFB_))) {
        LOGE("XR_FB_passthrough entry points missing");
        return false;
    }

    XrPassthroughCreateInfoFB createInfo{XR_TYPE_PASSTHROUGH_CREATE_INFO_FB};
    if (!xrOk(xrCreatePassthroughFB_(session_, &createInfo, &passthrough_),
              "xrCreatePassthroughFB")) {
        return false;
    }

    XrPassthroughLayerCreateInfoFB layerInfo{XR_TYPE_PASSTHROUGH_LAYER_CREATE_INFO_FB};
    layerInfo.passthrough = passthrough_;
    layerInfo.purpose = XR_PASSTHROUGH_LAYER_PURPOSE_RECONSTRUCTION_FB;
    layerInfo.flags = XR_PASSTHROUGH_IS_RUNNING_AT_CREATION_BIT_FB;
    if (!xrOk(xrCreatePassthroughLayerFB_(session_, &layerInfo, &passthroughLayer_),
              "xrCreatePassthroughLayerFB")) {
        return false;
    }

    passthroughComposition_ = XrCompositionLayerPassthroughFB{
        XR_TYPE_COMPOSITION_LAYER_PASSTHROUGH_FB};
    passthroughComposition_.layerHandle = passthroughLayer_;
    passthroughComposition_.flags = XR_COMPOSITION_LAYER_BLEND_TEXTURE_SOURCE_ALPHA_BIT;
    passthroughComposition_.space = XR_NULL_HANDLE;
    return true;
}

bool Background::initPanorama() {
    XrSwapchainCreateInfo info{XR_TYPE_SWAPCHAIN_CREATE_INFO};
    info.usageFlags = XR_SWAPCHAIN_USAGE_COLOR_ATTACHMENT_BIT |
                      XR_SWAPCHAIN_USAGE_SAMPLED_BIT;
    info.format = kFormatSRGBA8;
    info.sampleCount = 1;
    info.width = static_cast<uint32_t>(panoramaWidth_);
    info.height = static_cast<uint32_t>(panoramaHeight_);
    info.faceCount = 1;
    info.arraySize = 1;
    info.mipCount = 1;

    if (XR_FAILED(xrCreateSwapchain(session_, &info, &panoramaSwapchain_))) {
        info.format = kFormatRGBA8;
        if (!xrOk(xrCreateSwapchain(session_, &info, &panoramaSwapchain_),
                  "xrCreateSwapchain(panorama)")) {
            return false;
        }
    }

    uint32_t imageCount = 0;
    if (!xrOk(xrEnumerateSwapchainImages(panoramaSwapchain_, 0, &imageCount, nullptr),
              "xrEnumerateSwapchainImages(panorama)")) {
        return false;
    }
    panoramaImages_.assign(
        imageCount, XrSwapchainImageOpenGLESKHR{XR_TYPE_SWAPCHAIN_IMAGE_OPENGL_ES_KHR});
    if (!xrOk(xrEnumerateSwapchainImages(
                  panoramaSwapchain_, imageCount, &imageCount,
                  reinterpret_cast<XrSwapchainImageBaseHeader*>(panoramaImages_.data())),
              "xrEnumerateSwapchainImages(panorama)")) {
        return false;
    }

    glGenFramebuffers(1, &panoramaFbo_);
    glGenVertexArrays(1, &skyVao_);

    GLuint vs = compileShader(GL_VERTEX_SHADER, kSkyVertexShader);
    GLuint fs = compileShader(GL_FRAGMENT_SHADER, kSkyFragmentShader);
    if (vs == 0 || fs == 0) return false;
    skyProgram_ = glCreateProgram();
    glAttachShader(skyProgram_, vs);
    glAttachShader(skyProgram_, fs);
    glLinkProgram(skyProgram_);
    glDeleteShader(vs);
    glDeleteShader(fs);

    GLint linked = GL_FALSE;
    glGetProgramiv(skyProgram_, GL_LINK_STATUS, &linked);
    if (linked != GL_TRUE) {
        LOGE("sky program link failed");
        return false;
    }

    GLuint texVs = compileShader(GL_VERTEX_SHADER, kSkyVertexShader);
    GLuint texFs = compileShader(GL_FRAGMENT_SHADER, kTexFragmentShader);
    if (texVs != 0 && texFs != 0) {
        texProgram_ = glCreateProgram();
        glAttachShader(texProgram_, texVs);
        glAttachShader(texProgram_, texFs);
        glLinkProgram(texProgram_);
        glDeleteShader(texVs);
        glDeleteShader(texFs);

        glGetProgramiv(texProgram_, GL_LINK_STATUS, &linked);
        if (linked != GL_TRUE) {
            LOGW("panorama texture program link failed; gradient only");
            glDeleteProgram(texProgram_);
            texProgram_ = 0;
        } else {
            texSamplerLocation_ = glGetUniformLocation(texProgram_, "uTexture");
        }
    }

    panoramaComposition_ = XrCompositionLayerEquirect2KHR{
        XR_TYPE_COMPOSITION_LAYER_EQUIRECT2_KHR};
    panoramaComposition_.layerFlags = 0;
    panoramaComposition_.space = space_;
    panoramaComposition_.eyeVisibility = XR_EYE_VISIBILITY_BOTH;
    panoramaComposition_.subImage.swapchain = panoramaSwapchain_;
    panoramaComposition_.subImage.imageRect.offset = {0, 0};
    panoramaComposition_.subImage.imageRect.extent = {panoramaWidth_, panoramaHeight_};
    panoramaComposition_.subImage.imageArrayIndex = 0;
    panoramaComposition_.pose.orientation.w = 1.0f;
    panoramaComposition_.radius = 0.0f;   // 0 = infinite sphere
    panoramaComposition_.centralHorizontalAngle = 2.0f * static_cast<float>(M_PI);
    panoramaComposition_.upperVerticalAngle = static_cast<float>(M_PI) / 2.0f;
    panoramaComposition_.lowerVerticalAngle = -static_cast<float>(M_PI) / 2.0f;

    panoramaReady_ = true;
    LOGI("panorama ready (%dx%d)", panoramaWidth_, panoramaHeight_);
    return true;
}

bool Background::loadPanorama(const std::string& path) {
    int width = 0;
    int height = 0;
    int channels = 0;

    unsigned char* pixels =
        SOIL_load_image(path.c_str(), &width, &height, &channels, SOIL_LOAD_RGBA);
    if (pixels == nullptr) {
        LOGW("panorama: cannot load %s (%s)", path.c_str(), SOIL_last_result());
        return false;
    }

    LOGI("panorama: loaded %s (%dx%d, %d channels)", path.c_str(), width, height,
         channels);
    const bool ok = uploadPanoramaPixels(pixels, width, height);
    SOIL_free_image_data(pixels);
    return ok;
}

bool Background::uploadPanoramaPixels(const uint8_t* rgba, int32_t width,
                                      int32_t height) {
    if (panoramaUploadTexture_ == 0) glGenTextures(1, &panoramaUploadTexture_);

    glBindTexture(GL_TEXTURE_2D, panoramaUploadTexture_);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, width, height, 0, GL_RGBA,
                 GL_UNSIGNED_BYTE, rgba);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_REPEAT);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glBindTexture(GL_TEXTURE_2D, 0);

    panoramaNeedsUpload_ = true;
    return true;
}

void Background::renderPanoramaContents() {
    glDisable(GL_DEPTH_TEST);
    glDisable(GL_BLEND);
    glBindVertexArray(skyVao_);

    if (panoramaUploadTexture_ != 0 && texProgram_ != 0) {
        glUseProgram(texProgram_);
        glActiveTexture(GL_TEXTURE0);
        glBindTexture(GL_TEXTURE_2D, panoramaUploadTexture_);
        glUniform1i(texSamplerLocation_, 0);
        glDrawArrays(GL_TRIANGLES, 0, 3);
        glBindTexture(GL_TEXTURE_2D, 0);
    } else {
        glUseProgram(skyProgram_);
        glDrawArrays(GL_TRIANGLES, 0, 3);
    }

    glBindVertexArray(0);
}

void Background::cycleMode() {
    for (uint32_t step = 1; step <= static_cast<uint32_t>(BackgroundMode::Count); ++step) {
        const auto next = static_cast<BackgroundMode>(
            (static_cast<uint32_t>(mode_) + step) %
            static_cast<uint32_t>(BackgroundMode::Count));

        if (next == BackgroundMode::Passthrough && !passthroughAvailable_) continue;
        if (next == BackgroundMode::Panorama && !panoramaReady_) continue;

        mode_ = next;
        break;
    }

    if (passthroughAvailable_) {
        const bool wantRunning = mode_ == BackgroundMode::Passthrough;
        if (wantRunning && !passthroughRunning_) {
            xrPassthroughStartFB_(passthrough_);
            xrPassthroughLayerResumeFB_(passthroughLayer_);
            passthroughRunning_ = true;
        } else if (!wantRunning && passthroughRunning_) {
            xrPassthroughLayerPauseFB_(passthroughLayer_);
            xrPassthroughPauseFB_(passthrough_);
            passthroughRunning_ = false;
        }
    }

}

void Background::appendLayer(std::vector<XrCompositionLayerBaseHeader*>& layers) {
    switch (mode_) {
        case BackgroundMode::Passthrough: {
            if (!passthroughAvailable_) return;
            if (!passthroughRunning_) {
                xrPassthroughStartFB_(passthrough_);
                xrPassthroughLayerResumeFB_(passthroughLayer_);
                passthroughRunning_ = true;
            }
            layers.push_back(
                reinterpret_cast<XrCompositionLayerBaseHeader*>(&passthroughComposition_));
            break;
        }

        case BackgroundMode::Panorama: {
            if (!panoramaReady_) return;

            if (panoramaNeedsUpload_) {
                uint32_t index = 0;
                XrSwapchainImageAcquireInfo acquireInfo{
                    XR_TYPE_SWAPCHAIN_IMAGE_ACQUIRE_INFO};
                if (XR_SUCCEEDED(
                        xrAcquireSwapchainImage(panoramaSwapchain_, &acquireInfo, &index))) {
                    XrSwapchainImageWaitInfo waitInfo{XR_TYPE_SWAPCHAIN_IMAGE_WAIT_INFO};
                    waitInfo.timeout = XR_INFINITE_DURATION;
                    if (XR_SUCCEEDED(xrWaitSwapchainImage(panoramaSwapchain_, &waitInfo))) {
                        glBindFramebuffer(GL_FRAMEBUFFER, panoramaFbo_);
                        glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                                               GL_TEXTURE_2D,
                                               panoramaImages_[index].image, 0);
                        glViewport(0, 0, panoramaWidth_, panoramaHeight_);
                        glDisable(GL_SCISSOR_TEST);
                        renderPanoramaContents();
                        glBindFramebuffer(GL_FRAMEBUFFER, 0);
                        panoramaNeedsUpload_ = false;
                    }
                    XrSwapchainImageReleaseInfo releaseInfo{
                        XR_TYPE_SWAPCHAIN_IMAGE_RELEASE_INFO};
                    xrReleaseSwapchainImage(panoramaSwapchain_, &releaseInfo);
                }
            }

            layers.push_back(
                reinterpret_cast<XrCompositionLayerBaseHeader*>(&panoramaComposition_));
            break;
        }

        case BackgroundMode::Black:
        default:
            break;
    }
}

void Background::shutdown() {
    if (passthroughLayer_ != XR_NULL_HANDLE && xrDestroyPassthroughLayerFB_ != nullptr) {
        xrDestroyPassthroughLayerFB_(passthroughLayer_);
        passthroughLayer_ = XR_NULL_HANDLE;
    }
    if (passthrough_ != XR_NULL_HANDLE && xrDestroyPassthroughFB_ != nullptr) {
        xrDestroyPassthroughFB_(passthrough_);
        passthrough_ = XR_NULL_HANDLE;
    }
    passthroughRunning_ = false;

    if (panoramaSwapchain_ != XR_NULL_HANDLE) {
        xrDestroySwapchain(panoramaSwapchain_);
        panoramaSwapchain_ = XR_NULL_HANDLE;
    }
    if (panoramaUploadTexture_ != 0) glDeleteTextures(1, &panoramaUploadTexture_);
    if (panoramaFbo_ != 0) glDeleteFramebuffers(1, &panoramaFbo_);
    if (skyVao_ != 0) glDeleteVertexArrays(1, &skyVao_);
    if (skyProgram_ != 0) glDeleteProgram(skyProgram_);
    if (texProgram_ != 0) glDeleteProgram(texProgram_);
    panoramaUploadTexture_ = panoramaFbo_ = skyVao_ = skyProgram_ = texProgram_ = 0;
    panoramaReady_ = false;
}

}  // namespace pippinvr
