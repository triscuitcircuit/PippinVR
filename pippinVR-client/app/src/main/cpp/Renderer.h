#ifndef PIPPINVR_RENDERER_H
#define PIPPINVR_RENDERER_H

#include <cstdint>
#include <unordered_map>

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES3/gl3.h>
#include <GLES2/gl2ext.h>
#include <android/hardware_buffer.h>

namespace pippinvr {

class Renderer {
public:
    Renderer() = default;
    ~Renderer();

    Renderer(const Renderer&) = delete;
    Renderer& operator=(const Renderer&) = delete;

    bool init();
    void shutdown();

    bool blit(AHardwareBuffer* buffer, GLuint destTexture, int32_t width, int32_t height);

    void clear(GLuint destTexture, int32_t width, int32_t height,
               float r, float g, float b);

    void drawPanelBar(GLuint destTexture, int32_t width, int32_t height,
                      int32_t hoveredZone, int32_t activeZone);

private:
    EGLImageKHR imageFor(AHardwareBuffer* buffer);
    bool buildProgram();

    bool buildBarProgram();

    GLuint program_ = 0;
    GLuint vao_ = 0;
    GLuint fbo_ = 0;
    GLuint externalTexture_ = 0;
    GLint samplerLocation_ = -1;

    GLuint barProgram_ = 0;
    GLint barHoveredLocation_ = -1;
    GLint barActiveLocation_ = -1;
    GLint barAspectLocation_ = -1;

    std::unordered_map<AHardwareBuffer*, EGLImageKHR> imageCache_;

    PFNEGLCREATEIMAGEKHRPROC eglCreateImageKHR_ = nullptr;
    PFNEGLDESTROYIMAGEKHRPROC eglDestroyImageKHR_ = nullptr;
    PFNEGLGETNATIVECLIENTBUFFERANDROIDPROC eglGetNativeClientBufferANDROID_ = nullptr;
    PFNGLEGLIMAGETARGETTEXTURE2DOESPROC glEGLImageTargetTexture2DOES_ = nullptr;

    bool initialised_ = false;
};

}

#endif  // PIPPINVR_RENDERER_H
