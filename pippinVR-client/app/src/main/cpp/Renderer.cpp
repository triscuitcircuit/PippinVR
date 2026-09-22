#include "Renderer.h"
#include "Log.h"

#include <GLES2/gl2ext.h>

namespace pippinvr {
namespace {

constexpr const char* kVertexShader = R"(#version 300 es
out vec2 vUV;
void main() {
    vec2 p = vec2((gl_VertexID << 1) & 2, gl_VertexID & 2);
    vUV = p;
    gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}
)";

// samplerExternalOES is how a GL_TEXTURE_EXTERNAL_OES texture is read; the decoder
// writes YUV and the sampler does the conversion for us.
constexpr const char* kFragmentShader = R"(#version 300 es
#extension GL_OES_EGL_image_external_essl3 : require
precision mediump float;
uniform samplerExternalOES uTexture;
in vec2 vUV;
out vec4 fragColor;
void main() {
    fragColor = texture(uTexture, vec2(vUV.x, 1.0 - vUV.y));
}
)";

// Panel handle bar, drawn procedurally so it needs no font or texture asset.
// Zones left to right: 0 rotate-left, 1 drag, 2 face-me, 3 rotate-right.
// Glyphs are signed-distance-ish shapes evaluated per pixel.
constexpr const char* kBarFragmentShader = R"(#version 300 es
precision mediump float;
uniform int uHovered;   // -1 = none
uniform int uActive;    // -1 = none
uniform float uAspect;  // width / height, to keep glyphs round
in vec2 vUV;
out vec4 fragColor;

const float kRotW = 0.12;   // width of each rotate zone
const float kFaceW = 0.10;  // width of the face-me zone

int zoneAt(float x) {
    if (x < kRotW) return 0;
    if (x > 1.0 - kRotW) return 3;
    if (x > 1.0 - kRotW - kFaceW) return 2;
    return 1;
}

// Chevron pointing left (dir -1) or right (+1), centred in a zone.
float chevron(vec2 p, float dir) {
    p.x *= dir;
    float d = abs(abs(p.x) + p.y * 0.0) ;
    float arm = abs(p.y) - (p.x + 0.18);
    float band = abs(arm) - 0.06;
    float inside = max(band, abs(p.y) - 0.22);
    return 1.0 - smoothstep(0.0, 0.03, inside + 0.02 * d);
}

// Three grip dots for the drag zone.
float gripDots(vec2 p) {
    float acc = 0.0;
    for (int i = -1; i <= 1; ++i) {
        vec2 c = vec2(float(i) * 0.09, 0.0);
        acc = max(acc, 1.0 - smoothstep(0.02, 0.035, length(p - c)));
    }
    return acc;
}


float ring(vec2 p) {
    float d = abs(length(p) - 0.16) - 0.035;
    return 1.0 - smoothstep(0.0, 0.03, d);
}

void main() {
    int zone = zoneAt(vUV.x);

    vec3 base = vec3(0.10, 0.11, 0.14);
    if (zone == 1) base = vec3(0.13, 0.14, 0.18);
    if (zone == uHovered) base *= 1.9;
    if (zone == uActive)  base = vec3(0.20, 0.45, 0.85);

    // Local coordinates within the zone, aspect-corrected so glyphs are not stretched.
    float zoneStart, zoneEnd;
    if (zone == 0)      { zoneStart = 0.0;               zoneEnd = kRotW; }
    else if (zone == 3) { zoneStart = 1.0 - kRotW;       zoneEnd = 1.0; }
    else if (zone == 2) { zoneStart = 1.0 - kRotW-kFaceW; zoneEnd = 1.0 - kRotW; }
    else                { zoneStart = kRotW;             zoneEnd = 1.0 - kRotW - kFaceW; }

    float zw = max(zoneEnd - zoneStart, 1e-4);
    vec2 p = vec2(((vUV.x - zoneStart) / zw - 0.5) * (zw * uAspect), vUV.y - 0.5);
    p.x = clamp(p.x, -1.0, 1.0);

    float glyph = 0.0;
    if (zone == 0)      glyph = chevron(p, -1.0);
    else if (zone == 3) glyph = chevron(p,  1.0);
    else if (zone == 2) glyph = ring(p);
    else                glyph = gripDots(p);

    vec3 col = mix(base, vec3(0.92, 0.94, 1.0), clamp(glyph, 0.0, 1.0));

    // Hairline separators between zones.
    float edge = 0.0;
    edge = max(edge, 1.0 - smoothstep(0.0, 0.004, abs(vUV.x - kRotW)));
    edge = max(edge, 1.0 - smoothstep(0.0, 0.004, abs(vUV.x - (1.0 - kRotW))));
    edge = max(edge, 1.0 - smoothstep(0.0, 0.004, abs(vUV.x - (1.0 - kRotW - kFaceW))));
    col = mix(col, vec3(0.03), edge * 0.8);

    fragColor = vec4(col, 0.93);
}
)";

GLuint compile(GLenum type, const char* source) {
    GLuint shader = glCreateShader(type);
    glShaderSource(shader, 1, &source, nullptr);
    glCompileShader(shader);

    GLint ok = GL_FALSE;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
    if (ok != GL_TRUE) {
        char log[1024] = {};
        glGetShaderInfoLog(shader, sizeof(log) - 1, nullptr, log);
        LOGE("shader compile failed: %s", log);
        glDeleteShader(shader);
        return 0;
    }
    return shader;
}

}

Renderer::~Renderer() { shutdown(); }

bool Renderer::buildProgram() {
    GLuint vs = compile(GL_VERTEX_SHADER, kVertexShader);
    if (vs == 0) return false;
    GLuint fs = compile(GL_FRAGMENT_SHADER, kFragmentShader);
    if (fs == 0) {
        glDeleteShader(vs);
        return false;
    }

    program_ = glCreateProgram();
    glAttachShader(program_, vs);
    glAttachShader(program_, fs);
    glLinkProgram(program_);
    glDeleteShader(vs);
    glDeleteShader(fs);

    GLint ok = GL_FALSE;
    glGetProgramiv(program_, GL_LINK_STATUS, &ok);
    if (ok != GL_TRUE) {
        char log[1024] = {};
        glGetProgramInfoLog(program_, sizeof(log) - 1, nullptr, log);
        LOGE("program link failed: %s", log);
        glDeleteProgram(program_);
        program_ = 0;
        return false;
    }

    samplerLocation_ = glGetUniformLocation(program_, "uTexture");
    return true;
}

bool Renderer::buildBarProgram() {
    GLuint vs = compile(GL_VERTEX_SHADER, kVertexShader);
    if (vs == 0) return false;
    GLuint fs = compile(GL_FRAGMENT_SHADER, kBarFragmentShader);
    if (fs == 0) {
        glDeleteShader(vs);
        return false;
    }

    barProgram_ = glCreateProgram();
    glAttachShader(barProgram_, vs);
    glAttachShader(barProgram_, fs);
    glLinkProgram(barProgram_);
    glDeleteShader(vs);
    glDeleteShader(fs);

    GLint ok = GL_FALSE;
    glGetProgramiv(barProgram_, GL_LINK_STATUS, &ok);
    if (ok != GL_TRUE) {
        char log[1024] = {};
        glGetProgramInfoLog(barProgram_, sizeof(log) - 1, nullptr, log);
        LOGE("bar program link failed: %s", log);
        glDeleteProgram(barProgram_);
        barProgram_ = 0;
        return false;
    }

    barHoveredLocation_ = glGetUniformLocation(barProgram_, "uHovered");
    barActiveLocation_ = glGetUniformLocation(barProgram_, "uActive");
    barAspectLocation_ = glGetUniformLocation(barProgram_, "uAspect");
    return true;
}

void Renderer::drawPanelBar(GLuint destTexture, int32_t width, int32_t height,
                            int32_t hoveredZone, int32_t activeZone) {
    if (!initialised_ || barProgram_ == 0) return;

    glBindFramebuffer(GL_FRAMEBUFFER, fbo_);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
                           destTexture, 0);
    glViewport(0, 0, width, height);
    glDisable(GL_DEPTH_TEST);
    glDisable(GL_BLEND);
    glDisable(GL_SCISSOR_TEST);

    glUseProgram(barProgram_);
    glUniform1i(barHoveredLocation_, hoveredZone);
    glUniform1i(barActiveLocation_, activeZone);
    glUniform1f(barAspectLocation_,
                height > 0 ? static_cast<float>(width) / static_cast<float>(height)
                           : 1.0f);

    glBindVertexArray(vao_);
    glDrawArrays(GL_TRIANGLES, 0, 3);
    glBindVertexArray(0);
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
}

bool Renderer::init() {
    if (initialised_) return true;

    eglCreateImageKHR_ = reinterpret_cast<PFNEGLCREATEIMAGEKHRPROC>(
        eglGetProcAddress("eglCreateImageKHR"));
    eglDestroyImageKHR_ = reinterpret_cast<PFNEGLDESTROYIMAGEKHRPROC>(
        eglGetProcAddress("eglDestroyImageKHR"));
    eglGetNativeClientBufferANDROID_ =
        reinterpret_cast<PFNEGLGETNATIVECLIENTBUFFERANDROIDPROC>(
            eglGetProcAddress("eglGetNativeClientBufferANDROID"));
    glEGLImageTargetTexture2DOES_ =
        reinterpret_cast<PFNGLEGLIMAGETARGETTEXTURE2DOESPROC>(
            eglGetProcAddress("glEGLImageTargetTexture2DOES"));

    if (eglCreateImageKHR_ == nullptr || eglDestroyImageKHR_ == nullptr ||
        eglGetNativeClientBufferANDROID_ == nullptr ||
        glEGLImageTargetTexture2DOES_ == nullptr) {
        LOGE("required EGL/GLES image extensions are missing");
        return false;
    }

    if (!buildProgram()) return false;
    if (!buildBarProgram()) {
        LOGW("panel handle bars unavailable (shader build failed)");
    }

    glGenVertexArrays(1, &vao_);
    glGenFramebuffers(1, &fbo_);
    glGenTextures(1, &externalTexture_);

    glBindTexture(GL_TEXTURE_EXTERNAL_OES, externalTexture_);
    glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_EXTERNAL_OES, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glBindTexture(GL_TEXTURE_EXTERNAL_OES, 0);

    initialised_ = true;
    LOGI("renderer initialised");
    return true;
}

void Renderer::shutdown() {
    if (!initialised_) return;

    EGLDisplay display = eglGetCurrentDisplay();
    if (display != EGL_NO_DISPLAY && eglDestroyImageKHR_ != nullptr) {
        for (auto& [buffer, image] : imageCache_) {
            (void)buffer;
            eglDestroyImageKHR_(display, image);
        }
    }
    imageCache_.clear();

    if (externalTexture_ != 0) glDeleteTextures(1, &externalTexture_);
    if (fbo_ != 0) glDeleteFramebuffers(1, &fbo_);
    if (vao_ != 0) glDeleteVertexArrays(1, &vao_);
    if (program_ != 0) glDeleteProgram(program_);
    if (barProgram_ != 0) glDeleteProgram(barProgram_);

    externalTexture_ = fbo_ = vao_ = program_ = barProgram_ = 0;
    initialised_ = false;
}

EGLImageKHR Renderer::imageFor(AHardwareBuffer* buffer) {
    auto it = imageCache_.find(buffer);
    if (it != imageCache_.end()) return it->second;

    EGLDisplay display = eglGetCurrentDisplay();
    if (display == EGL_NO_DISPLAY) {
        LOGE("no current EGL display");
        return EGL_NO_IMAGE_KHR;
    }

    EGLClientBuffer clientBuffer = eglGetNativeClientBufferANDROID_(buffer);
    if (clientBuffer == nullptr) {
        LOGE("eglGetNativeClientBufferANDROID returned null");
        return EGL_NO_IMAGE_KHR;
    }

    // EGL_IMAGE_PRESERVED means the buffer's existing contents survive the import.
    const EGLint attribs[] = {EGL_IMAGE_PRESERVED_KHR, EGL_TRUE, EGL_NONE};
    EGLImageKHR image = eglCreateImageKHR_(display, EGL_NO_CONTEXT,
                                           EGL_NATIVE_BUFFER_ANDROID,
                                           clientBuffer, attribs);
    if (image == EGL_NO_IMAGE_KHR) {
        LOGE("eglCreateImageKHR failed (0x%04x)", eglGetError());
        return EGL_NO_IMAGE_KHR;
    }

    imageCache_.emplace(buffer, image);
    return image;
}

bool Renderer::blit(AHardwareBuffer* buffer, GLuint destTexture,
                    int32_t width, int32_t height) {
    if (!initialised_ || buffer == nullptr) return false;

    EGLImageKHR image = imageFor(buffer);
    if (image == EGL_NO_IMAGE_KHR) return false;

    glBindFramebuffer(GL_FRAMEBUFFER, fbo_);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
                           destTexture, 0);
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
        LOGE("swapchain framebuffer incomplete");
        glBindFramebuffer(GL_FRAMEBUFFER, 0);
        return false;
    }

    glViewport(0, 0, width, height);
    glDisable(GL_DEPTH_TEST);
    glDisable(GL_BLEND);
    glDisable(GL_SCISSOR_TEST);

    glUseProgram(program_);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_EXTERNAL_OES, externalTexture_);
    glEGLImageTargetTexture2DOES_(GL_TEXTURE_EXTERNAL_OES,
                                  static_cast<GLeglImageOES>(image));
    glUniform1i(samplerLocation_, 0);

    glBindVertexArray(vao_);
    glDrawArrays(GL_TRIANGLES, 0, 3);
    glBindVertexArray(0);

    glBindTexture(GL_TEXTURE_EXTERNAL_OES, 0);
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
    return true;
}

void Renderer::clear(GLuint destTexture, int32_t width, int32_t height,
                     float r, float g, float b) {
    if (!initialised_) return;

    glBindFramebuffer(GL_FRAMEBUFFER, fbo_);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
                           destTexture, 0);
    glViewport(0, 0, width, height);
    glDisable(GL_SCISSOR_TEST);
    glClearColor(r, g, b, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    glBindFramebuffer(GL_FRAMEBUFFER, 0);
}

}
