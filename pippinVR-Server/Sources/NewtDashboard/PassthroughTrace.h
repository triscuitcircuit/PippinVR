#pragma once
// SPDX-License-Identifier: MIT



#include "Newt/MathTypes.h"
#include <algorithm>
#include <array>
#include <cmath>

struct TracedPortal {
    XrPosef pose{};
    float width = 0, height = 0;
    float shape[8] = {};
    float flatness = 0;
};

namespace trace_detail {
inline float Dot(const Vec3& a, const Vec3& b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
inline Vec3 Cross(const Vec3& a, const Vec3& b) {
    return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x};
}
inline float Length(const Vec3& a) { return std::sqrt(Dot(a, a)); }
inline Vec3 Normalized(const Vec3& a) { const float l = Length(a); return l > 1e-9f ? a * (1.0f / l) : a; }

inline XrQuaternionf FromAxes(const Vec3& x, const Vec3& y, const Vec3& z) {
    const float m00 = x.x, m11 = y.y, m22 = z.z, trace = m00 + m11 + m22;
    XrQuaternionf q;
    if (trace > 0) {
        const float s = std::sqrt(trace + 1) * 2;
        q = {(y.z - z.y) / s, (z.x - x.z) / s, (x.y - y.x) / s, s / 4};
    } else if (m00 > m11 && m00 > m22) {
        const float s = std::sqrt(1 + m00 - m11 - m22) * 2;
        q = {s / 4, (y.x + x.y) / s, (z.x + x.z) / s, (y.z - z.y) / s};
    } else if (m11 > m22) {
        const float s = std::sqrt(1 + m11 - m00 - m22) * 2;
        q = {(y.x + x.y) / s, s / 4, (z.y + y.z) / s, (z.x - x.z) / s};
    } else {
        const float s = std::sqrt(1 + m22 - m00 - m11) * 2;
        q = {(z.x + x.z) / s, (z.y + y.z) / s, s / 4, (x.y - y.x) / s};
    }
    return q;
}
}



inline bool FitTracedPortal(const std::array<Vec3, 4>& points, const Vec3& viewer, TracedPortal& out) {
    using namespace trace_detail;
    Vec3 centroid{};
    for (const auto& p : points) centroid = centroid + p * 0.25f;


    const int pairs[3][4] = {{0, 2, 1, 3}, {0, 1, 2, 3}, {0, 3, 1, 2}};
    Vec3 normal{};
    for (const auto& p : pairs) {
        const Vec3 n = Cross(points[p[1]] - points[p[0]], points[p[3]] - points[p[2]]);
        if (Length(n) > Length(normal)) normal = n;
    }
    if (Length(normal) < 1e-4f) return false;
    normal = Normalized(normal);
    if (Dot(normal, viewer - centroid) < 0) normal = normal * -1.0f;


    Vec3 up = Vec3{0, 1, 0} - normal * normal.y;
    if (Length(up) < 0.3f) {
        const Vec3 away = centroid - viewer;
        up = away - normal * Dot(away, normal);
    }
    if (Length(up) < 1e-4f) return false;
    up = Normalized(up);
    const Vec3 right = Cross(up, normal);
    float u[4], v[4], minU = 1e9f, maxU = -1e9f, minV = 1e9f, maxV = -1e9f;
    out.flatness = 0;
    for (int i = 0; i < 4; ++i) {
        const Vec3 d = points[i] - centroid;
        u[i] = Dot(d, right);
        v[i] = Dot(d, up);
        out.flatness = std::max(out.flatness, std::fabs(Dot(d, normal)));
        minU = std::min(minU, u[i]); maxU = std::max(maxU, u[i]);
        minV = std::min(minV, v[i]); maxV = std::max(maxV, v[i]);
    }
    out.width = maxU - minU;
    out.height = maxV - minV;
    if (out.width < 0.03f || out.height < 0.03f) return false;
    const float cu = (minU + maxU) / 2, cv = (minV + maxV) / 2;

    float mu = 0, mv = 0;
    for (int i = 0; i < 4; ++i) { mu += u[i] / 4; mv += v[i] / 4; }
    std::array<int, 4> order{0, 1, 2, 3};
    std::sort(order.begin(), order.end(), [&](int a, int b) {
        return std::atan2(v[a] - mv, u[a] - mu) > std::atan2(v[b] - mv, u[b] - mu);
    });
    int start = 0;
    for (int i = 1; i < 4; ++i)
        if (v[order[i]] - u[order[i]] > v[order[start]] - u[order[start]]) start = i;
    for (int i = 0; i < 4; ++i) {
        const int p = order[(start + i) % 4];
        out.shape[2 * i] = (u[p] - cu) / out.width;
        out.shape[2 * i + 1] = (v[p] - cv) / out.height;
    }
    const Vec3 center = centroid + right * cu + up * cv;
    out.pose.position = {center.x, center.y, center.z};
    out.pose.orientation = FromAxes(right, up, normal);
    return true;
}
