#ifndef NEWT_ENVIRONMENT_MODEL_H
#define NEWT_ENVIRONMENT_MODEL_H

#include "Newt/MathTypes.h"
#include "Newt/PixelImage.h"
#include <simd/simd.h>
#include <string>
#include <vector>

struct EnvironmentModelPart {
    std::vector<VertexPC> vertices;
    PixelImage texture;
};

struct EnvironmentModel {
    std::vector<EnvironmentModelPart> parts;
    float defaultScale = 1.0f;
    Vec3 localCenter{0.0f, 0.5f, 0.0f};
    Vec3 halfExtents{0.5f, 0.5f, 0.5f};
    bool loaded = false;
    std::string summary;
};

namespace NewtModelInternal {

constexpr size_t kMaxModelTextures = 16;

inline float Dot(const Vec3& a, const Vec3& b) {
    return a.x * b.x + a.y * b.y + a.z * b.z;
}

inline Vec3 Cross(const Vec3& a, const Vec3& b) {
    return {
        a.y * b.z - a.z * b.y,
        a.z * b.x - a.x * b.z,
        a.x * b.y - a.y * b.x
    };
}

inline float Length(const Vec3& v) {
    return std::sqrt(Dot(v, v));
}

inline Vec3 Normalize(const Vec3& v) {
    const float len = Length(v);
    return len > 1e-6f ? Vec3{v.x / len, v.y / len, v.z / len} : Vec3{0.0f, 1.0f, 0.0f};
}

struct RawVertex {
    Vec3 pos{0, 0, 0};
    Vec3 norm{0, 1, 0};
    float u = 0.0f;
    float v = 0.0f;
    float color[3]{0.82f, 0.84f, 0.86f};
};

struct RawSubmesh {
    std::vector<RawVertex> vertices;
    int textureIndex = -1;
};

struct RawScene {
    std::vector<RawSubmesh> submeshes;
    std::vector<PixelImage> textures;
};

inline Vec3 TransformPoint(const simd_float4x4& m, const Vec3& p) {
    simd_float4 v = simd_make_float4(p.x, p.y, p.z, 1.0f);
    simd_float4 r = simd_mul(m, v);
    return {r.x, r.y, r.z};
}

inline Vec3 TransformDirection(const simd_float4x4& m, const Vec3& n) {
    simd_float4 v = simd_make_float4(n.x, n.y, n.z, 0.0f);
    simd_float4 r = simd_mul(m, v);
    return Normalize(Vec3{r.x, r.y, r.z});
}

bool LoadGltfOrGlbModel(const std::string& path, RawScene& scene);

}

bool IsModelFilePath(const std::string& path);
EnvironmentModel LoadModelFile(const std::string& path);

#endif
