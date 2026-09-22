
#ifndef PIPPINVR_BACKGROUND_H
#define PIPPINVR_BACKGROUND_H

#include <cstdint>
#include <string>
#include <vector>

#include <EGL/egl.h>
#include <GLES3/gl3.h>
#include <jni.h>

#include <openxr/openxr.h>
#include <openxr/openxr_platform.h>

namespace pippinvr {

enum class BackgroundMode : uint32_t {
    Passthrough = 0,
    Panorama = 1,
    Black = 2,
    Count = 3,
};

const char* backgroundModeName(BackgroundMode mode);

class Background {
public:
    Background() = default;
    ~Background();

    Background(const Background&) = delete;
    Background& operator=(const Background&) = delete;

    void setAvailability(bool passthroughAvailable, bool equirectAvailable);


    bool init(XrInstance instance, XrSession session, XrSpace space);
    void shutdown();

    void cycleMode();
    BackgroundMode mode() const { return mode_; }

    void appendLayer(std::vector<XrCompositionLayerBaseHeader*>& layers);


    bool loadPanorama(const std::string& path);

private:
    bool initPassthrough();
    bool initPanorama();
    bool uploadPanoramaPixels(const uint8_t* rgba, int32_t width, int32_t height);
    void renderPanoramaContents();

    XrInstance instance_ = XR_NULL_HANDLE;
    XrSession session_ = XR_NULL_HANDLE;
    XrSpace space_ = XR_NULL_HANDLE;

    BackgroundMode mode_ = BackgroundMode::Passthrough;

    bool passthroughAvailable_ = false;
    bool equirectAvailable_ = false;

    XrPassthroughFB passthrough_ = XR_NULL_HANDLE;
    XrPassthroughLayerFB passthroughLayer_ = XR_NULL_HANDLE;
    XrCompositionLayerPassthroughFB passthroughComposition_{};
    bool passthroughRunning_ = false;

    PFN_xrCreatePassthroughFB xrCreatePassthroughFB_ = nullptr;
    PFN_xrDestroyPassthroughFB xrDestroyPassthroughFB_ = nullptr;
    PFN_xrPassthroughStartFB xrPassthroughStartFB_ = nullptr;
    PFN_xrPassthroughPauseFB xrPassthroughPauseFB_ = nullptr;
    PFN_xrCreatePassthroughLayerFB xrCreatePassthroughLayerFB_ = nullptr;
    PFN_xrDestroyPassthroughLayerFB xrDestroyPassthroughLayerFB_ = nullptr;
    PFN_xrPassthroughLayerResumeFB xrPassthroughLayerResumeFB_ = nullptr;
    PFN_xrPassthroughLayerPauseFB xrPassthroughLayerPauseFB_ = nullptr;

    XrSwapchain panoramaSwapchain_ = XR_NULL_HANDLE;
    std::vector<XrSwapchainImageOpenGLESKHR> panoramaImages_;
    XrCompositionLayerEquirect2KHR panoramaComposition_{};
    int32_t panoramaWidth_ = 2048;
    int32_t panoramaHeight_ = 1024;
    bool panoramaReady_ = false;
    bool panoramaNeedsUpload_ = true;

    GLuint panoramaFbo_ = 0;
    GLuint panoramaUploadTexture_ = 0;
    GLuint skyProgram_ = 0;
    GLuint texProgram_ = 0;
    GLint texSamplerLocation_ = -1;
    GLuint skyVao_ = 0;
};

}  // namespace pippinvr

#endif  // PIPPINVR_BACKGROUND_H
