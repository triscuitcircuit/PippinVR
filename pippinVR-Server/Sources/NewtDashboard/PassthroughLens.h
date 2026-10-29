#pragma once
// SPDX-License-Identifier: MIT

#include "Newt/MathTypes.h"
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <strings.h>
#include <vector>

struct PassthroughCamera {
    uint32_t struct_size = sizeof(PassthroughCamera);
    char projection_model[32] = {};
    char distortion_model[32] = {};
    int32_t width = 0, height = 0;
    int32_t projection_count = 0;
    int32_t distortion_count = 0;
    double projection[4] = {};
    double distortion[12] = {};
    double device_from_camera[16] = {};
};

enum class LensModel { Unknown, Fisheye62, KannalaBrandt, RadTan };

inline bool LensNameHas(const char* name, const char* part) {
    for (const char* it = name; *it; ++it)
        if (strncasecmp(it, part, std::strlen(part)) == 0) return true;
    return false;
}

inline LensModel LensModelOf(const PassthroughCamera& c) {
    const char* d = c.distortion_model;
    if ((LensNameHas(d, "Fisheye62") || LensNameHas(d, "Fisheye624") || LensNameHas(d, "RadTanThinPrism")) &&
        c.distortion_count >= 8)
        return LensModel::Fisheye62;
    if ((LensNameHas(d, "Kannala") || LensNameHas(d, "KB") || LensNameHas(d, "Equidistant")) && c.distortion_count >= 4)
        return LensModel::KannalaBrandt;
    if ((LensNameHas(d, "RadTan") || LensNameHas(d, "Brown") || LensNameHas(d, "OpenCV")) && c.distortion_count >= 4)
        return LensModel::RadTan;
    return LensModel::Unknown;
}

inline bool LensProject(const PassthroughCamera& c, LensModel model, double x, double y, double z,
                        double& px, double& py) {
    if (z <= 1e-6 || c.width <= 0 || c.height <= 0) return false;
    double fx, fy, cx, cy;
    if (c.projection_count == 3) { fx = fy = c.projection[0]; cx = c.projection[1]; cy = c.projection[2]; }
    else if (c.projection_count == 4) { fx = c.projection[0]; fy = c.projection[1]; cx = c.projection[2]; cy = c.projection[3]; }
    else return false;
    const double* k = c.distortion;
    const double a = x / z, b = y / z;
    double u, v;
    if (model == LensModel::Fisheye62 || model == LensModel::KannalaBrandt) {
        const double r = std::sqrt(a * a + b * b);
        const double th = std::atan(r), th2 = th * th;
        double poly = 1, power = 1;
        const int terms = model == LensModel::Fisheye62 ? 6 : 4;
        for (int i = 0; i < terms; ++i) { power *= th2; poly += k[i] * power; }
        const double scale = r > 1e-9 ? th * poly / r : 1.0;
        u = a * scale; v = b * scale;
        if (model == LensModel::Fisheye62) {
            const double p0 = k[6], p1 = k[7];
            const double r2 = u * u + v * v, t = 2 * (u * p0 + v * p1);
            u += t * u + r2 * p0;
            v += t * v + r2 * p1;
        }
    } else if (model == LensModel::RadTan) {
        const double r2 = a * a + b * b;
        const double radial = 1 + k[0] * r2 + k[1] * r2 * r2 + (c.distortion_count > 4 ? k[4] * r2 * r2 * r2 : 0);
        u = a * radial + 2 * k[2] * a * b + k[3] * (r2 + 2 * a * a);
        v = b * radial + k[2] * (r2 + 2 * b * b) + 2 * k[3] * a * b;
    } else {
        return false;
    }
    px = fx * u + cx;
    py = fy * v + cy;
    return std::isfinite(px) && std::isfinite(py);
}

inline std::vector<VertexPC> MakeLensCorrectedQuad(const PassthroughCamera& c, float horizontalFovDeg,
                                                   float aspect, float pitchDownDeg = 0, int columns = 32,
                                                   int rows = 24) {
    const LensModel model = LensModelOf(c);
    std::vector<VertexPC> out;
    if (model == LensModel::Unknown || aspect <= 0.05f) return out;
    const double tanX = std::tan(horizontalFovDeg * M_PI / 360.0);
    const double tanY = tanX / aspect;
    const double pitch = pitchDownDeg * M_PI / 180.0, cp = std::cos(pitch), sp = std::sin(pitch);
    auto vertex = [&](float s, float t, VertexPC& result) {

        const double x = (2 * s - 1) * tanX, y = (2 * t - 1) * tanY;
        double px, py;


        if (!LensProject(c, model, x, y * cp + sp, std::max(-y * sp + cp, 0.02), px, py)) return false;
        result = VertexPC{{s - 0.5f, 0.5f - t, 0}, {float(px / c.width), float(py / c.height)}};
        return true;
    };
    out.reserve(size_t(columns) * rows * 6);
    for (int j = 0; j < rows; ++j) {
        for (int i = 0; i < columns; ++i) {
            const float u0 = float(i) / columns, u1 = float(i + 1) / columns;
            const float v0 = float(j) / rows, v1 = float(j + 1) / rows;
            VertexPC q[6];
            if (!vertex(u0, v1, q[0]) || !vertex(u1, v1, q[1]) || !vertex(u1, v0, q[2]) ||
                !vertex(u0, v1, q[3]) || !vertex(u1, v0, q[4]) || !vertex(u0, v0, q[5]))
                return {};
            out.insert(out.end(), q, q + 6);
        }
    }
    return out;
}

inline Mat4 CameraFromHead(const PassthroughCamera& c) {
    const double* m = c.device_from_camera;
    Mat4 out{};
    for (int row = 0; row < 3; ++row) {
        for (int col = 0; col < 3; ++col) out.m[col * 4 + row] = static_cast<float>(m[col * 4 + row]);
        double t = 0;
        for (int k = 0; k < 3; ++k) t -= m[k * 4 + row] * m[k * 4 + 3];
        out.m[12 + row] = static_cast<float>(t);
    }
    out.m[15] = 1;
    return out;
}

inline XrPosef InversePose(const XrPosef& pose) {
    XrPosef out;
    out.orientation = {-pose.orientation.x, -pose.orientation.y, -pose.orientation.z, pose.orientation.w};
    const Vec3 p = Rotate(out.orientation, Vec3{pose.position.x, pose.position.y, pose.position.z});
    out.position = {-p.x, -p.y, -p.z};
    return out;
}
