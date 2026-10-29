#pragma once
// SPDX-License-Identifier: MIT




#include "PassthroughLens.h"
#include <algorithm>
#include <array>
#include <cmath>
#include <memory>
#include <vector>

namespace stereo {
using V3 = std::array<double, 3>;
using M3 = std::array<double, 9>;

inline V3 Mul(const M3& m, const V3& v) {
    return {m[0] * v[0] + m[1] * v[1] + m[2] * v[2], m[3] * v[0] + m[4] * v[1] + m[5] * v[2],
            m[6] * v[0] + m[7] * v[1] + m[8] * v[2]};
}
inline M3 Transpose(const M3& m) { return {m[0], m[3], m[6], m[1], m[4], m[7], m[2], m[5], m[8]}; }
inline M3 Mul(const M3& a, const M3& b) {
    M3 r{};
    for (int i = 0; i < 3; ++i)
        for (int j = 0; j < 3; ++j) r[i * 3 + j] = a[i * 3] * b[j] + a[i * 3 + 1] * b[3 + j] + a[i * 3 + 2] * b[6 + j];
    return r;
}
inline double Dot(const V3& a, const V3& b) { return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]; }
inline V3 Cross(const V3& a, const V3& b) {
    return {a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]};
}
inline V3 Normalize(const V3& a) {
    const double l = std::sqrt(Dot(a, a));
    return l > 1e-12 ? V3{a[0] / l, a[1] / l, a[2] / l} : a;
}


inline bool Unproject(const PassthroughCamera& c, LensModel model, double px, double py, double& a, double& b) {
    if (c.projection_count != 3) return false;
    const double f = c.projection[0], cx = c.projection[1], cy = c.projection[2];
    a = (px - cx) / f;
    b = (py - cy) / f;
    for (int i = 0; i < 30; ++i) {
        double x0, y0, x1, y1, x2, y2;
        const double h = 1e-6;
        if (!LensProject(c, model, a, b, 1, x0, y0) || !LensProject(c, model, a + h, b, 1, x1, y1) ||
            !LensProject(c, model, a, b + h, 1, x2, y2)) return false;
        const double ex = x0 - px, ey = y0 - py;
        if (ex * ex + ey * ey < 1e-6) return true;
        const double j00 = (x1 - x0) / h, j10 = (y1 - y0) / h, j01 = (x2 - x0) / h, j11 = (y2 - y0) / h;
        const double det = j00 * j11 - j01 * j10;
        if (std::fabs(det) < 1e-12) return false;
        double da = (j11 * ex - j01 * ey) / det, db = (-j10 * ex + j00 * ey) / det;
        const double step = std::sqrt(da * da + db * db);
        if (step > 0.5) { da *= 0.5 / step; db *= 0.5 / step; }
        a -= da;
        b -= db;
    }
    double x0, y0;
    return LensProject(c, model, a, b, 1, x0, y0) && (x0 - px) * (x0 - px) + (y0 - py) * (y0 - py) < 0.01;
}

struct Rig {
    int width = 0, height = 0;
    double f = 0, cx = 0, cy = 0;
    double baseline = 0;
    M3 rectFromCam[2]{};
    M3 rectFromHead{};
    V3 center[2]{};
    int colorWidth = 0, colorHeight = 0;

    std::vector<float> forward[2];

    int step = 8, gridWidth = 0, gridHeight = 0;
    std::vector<float> inverse[2];


    V3 RectPoint(int k, const V3& head) const {
        return Mul(rectFromHead, V3{head[0] - center[k][0], head[1] - center[k][1], head[2] - center[k][2]});
    }
    bool RectPixel(const V3& r, double& x, double& y) const {
        if (r[2] < 0.05) return false;
        x = f * r[0] / r[2] + cx;
        y = f * r[1] / r[2] + cy;
        return true;
    }
};


inline void HeadFromCamera(const PassthroughCamera& c, M3& rotation, V3& center) {
    const double* m = c.device_from_camera;
    rotation = {m[0], m[1], m[2], m[4], m[5], m[6], m[8], m[9], m[10]};
    center = {m[3], m[7], m[11]};
}






inline std::shared_ptr<Rig> BuildRig(const PassthroughCamera& left, const PassthroughCamera& right, int width = 640,
                                     int height = 576, double horizontalFovDeg = 110, double pitchDownDeg = 15,
                                     int step = 8) {
    const LensModel models[2] = {LensModelOf(left), LensModelOf(right)};
    if (models[0] == LensModel::Unknown || models[1] == LensModel::Unknown || left.width <= 0 || left.height <= 0 ||
        left.width != right.width || left.height != right.height) return nullptr;
    auto rig = std::make_shared<Rig>();
    M3 headFromCam[2];
    HeadFromCamera(left, headFromCam[0], rig->center[0]);
    HeadFromCamera(right, headFromCam[1], rig->center[1]);
    const V3 base{rig->center[1][0] - rig->center[0][0], rig->center[1][1] - rig->center[0][1],
                  rig->center[1][2] - rig->center[0][2]};
    rig->baseline = std::sqrt(Dot(base, base));
    if (rig->baseline < 0.01 || rig->baseline > 0.3) return nullptr;


    const V3 x = Normalize(base);
    V3 z{};
    for (int k = 0; k < 2; ++k)
        for (int i = 0; i < 3; ++i) z[i] += headFromCam[k][i * 3 + 2];
    z = Normalize(V3{z[0] - x[0] * Dot(z, x), z[1] - x[1] * Dot(z, x), z[2] - x[2] * Dot(z, x)});
    V3 y = Cross(z, x);
    const double pitch = pitchDownDeg * M_PI / 180, cp = std::cos(pitch), sp = std::sin(pitch);
    const V3 zDown{cp * z[0] + sp * y[0], cp * z[1] + sp * y[1], cp * z[2] + sp * y[2]};
    y = Cross(zDown, x);
    z = zDown;
    rig->rectFromHead = {x[0], x[1], x[2], y[0], y[1], y[2], z[0], z[1], z[2]};
    for (int k = 0; k < 2; ++k) rig->rectFromCam[k] = Mul(rig->rectFromHead, headFromCam[k]);
    rig->width = width;
    rig->height = height;
    rig->f = (width / 2.0) / std::tan(horizontalFovDeg * M_PI / 360.0);
    rig->cx = (width - 1) / 2.0;
    rig->cy = (height - 1) / 2.0;
    rig->colorWidth = left.width;
    rig->colorHeight = left.height;
    const PassthroughCamera* cams[2] = {&left, &right};
    for (int k = 0; k < 2; ++k) {
        const M3 camFromRect = Transpose(rig->rectFromCam[k]);
        auto& fwd = rig->forward[k];
        fwd.assign(size_t(width) * height * 2, -1.0f);
        for (int py = 0; py < height; ++py)
            for (int px = 0; px < width; ++px) {
                const V3 ray = Mul(camFromRect, V3{(px - rig->cx) / rig->f, (py - rig->cy) / rig->f, 1});
                double u, v;
                if (ray[2] <= 0.05 || !LensProject(*cams[k], models[k], ray[0], ray[1], ray[2], u, v)) continue;
                u /= cams[k]->width;
                v /= cams[k]->height;
                if (u < 0 || u > 1 || v < 0 || v > 1) continue;
                fwd[(size_t(py) * width + px) * 2] = float(u);
                fwd[(size_t(py) * width + px) * 2 + 1] = float(v);
            }
    }
    rig->step = step;
    rig->gridWidth = left.width / step + 2;
    rig->gridHeight = left.height / step + 2;
    for (int k = 0; k < 2; ++k) {
        auto& inv = rig->inverse[k];
        inv.assign(size_t(rig->gridWidth) * rig->gridHeight * 2, -1.0f);
        for (int gy = 0; gy < rig->gridHeight; ++gy)
            for (int gx = 0; gx < rig->gridWidth; ++gx) {
                double a, b;
                if (!Unproject(*cams[k], models[k], gx * step + 0.5, gy * step + 0.5, a, b)) continue;
                const V3 r = Mul(rig->rectFromCam[k], V3{a, b, 1});
                double rx, ry;
                if (!rig->RectPixel(r, rx, ry)) continue;
                inv[(size_t(gy) * rig->gridWidth + gx) * 2] = float(rx);
                inv[(size_t(gy) * rig->gridWidth + gx) * 2 + 1] = float(ry);
            }
    }
    return rig;
}
}
