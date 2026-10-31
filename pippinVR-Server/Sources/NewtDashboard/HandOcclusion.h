#pragma once
// SPDX-License-Identifier: MIT




#include "Newt/MathTypes.h"
#include <algorithm>
#include <cmath>
#include <vector>

namespace hand_detail {
inline float Dot(const Vec3& a, const Vec3& b) { return a.x * b.x + a.y * b.y + a.z * b.z; }
inline Vec3 Cross(const Vec3& a, const Vec3& b) {
    return {a.y * b.z - a.z * b.y, a.z * b.x - a.x * b.z, a.x * b.y - a.y * b.x};
}
inline float Length(const Vec3& a) { return std::sqrt(Dot(a, a)); }
inline Vec3 Position(const XrPosef& p) { return {p.position.x, p.position.y, p.position.z}; }
inline Vec3 Axis(const XrPosef& p, const Vec3& axis) { return Rotate(p.orientation, axis); }



enum : int { kWrist = 1, kThumbMeta = 2, kIndexProx = 7, kMiddleProx = 12, kRingProx = 17, kLittleMeta = 21,
             kLittleProx = 22, kForearm = -1 };

struct Segment {
    int a, b;
    float radius;
    bool tip;
};


constexpr Segment kSegments[] = {
    {kWrist, kThumbMeta, 0.0150f, false}, {2, 3, 0.0125f, false}, {3, 4, 0.0105f, false}, {4, 5, 0.0090f, true},
    {7, 8, 0.0095f, false},  {8, 9, 0.0085f, false},  {9, 10, 0.0075f, true},
    {12, 13, 0.0100f, false}, {13, 14, 0.0090f, false}, {14, 15, 0.0080f, true},
    {17, 18, 0.0095f, false}, {18, 19, 0.0085f, false}, {19, 20, 0.0075f, true},
    {22, 23, 0.0085f, false}, {23, 24, 0.0075f, false}, {24, 25, 0.0070f, true},
    {kWrist, kIndexProx, 0.0140f, false}, {kWrist, kMiddleProx, 0.0150f, false}, {kWrist, kRingProx, 0.0140f, false},
    {kWrist, kLittleMeta, 0.0130f, false}, {kLittleMeta, kLittleProx, 0.0120f, false},
    {kIndexProx, kLittleProx, 0.0120f, false},
    {kWrist, kForearm, 0.0230f, false},
};
constexpr float kForearmLength = 0.07f;
constexpr float kPalmWidth = 0.055f;
}

constexpr int kSegmentCount = sizeof(hand_detail::kSegments) / sizeof(hand_detail::kSegments[0]);

constexpr int kMaxHandPieces = kSegmentCount * 3 - 1;

struct HandPiece {
    bool sphere = false;
    Mat4 worldFromLocal{};
};


inline float HandScale(const XrPosef* joints) {
    using namespace hand_detail;
    const float span = Length(Position(joints[kIndexProx]) - Position(joints[kLittleProx]));
    return std::isfinite(span) ? std::clamp(span / kPalmWidth, 0.85f, 1.2f) : 1.0f;
}




inline int BuildHandPieces(const XrPosef* joints, float scale, HandPiece* out) {
    using namespace hand_detail;
    int count = 0;
    for (const Segment& s : kSegments) {
        const XrPosef& start = joints[s.a];
        const Vec3 a = Position(start);
        const float r = s.radius * scale;
        Vec3 dir;
        float length;
        if (s.b == kForearm) {
            dir = Axis(start, {0, 0, 1});
            length = kForearmLength;
        } else {
            const Vec3 d = Position(joints[s.b]) - a;
            length = Length(d);
            dir = length > 1e-4f ? d * (1.0f / length) : Axis(start, {0, 0, -1});
            if (s.tip) length = std::max(1e-4f, length - r * 0.7f);
        }


        Vec3 x = Axis(start, {1, 0, 0});
        x = x - dir * Dot(x, dir);
        if (Length(x) < 0.3f) {
            x = Axis(start, {0, 1, 0});
            x = x - dir * Dot(x, dir);
        }
        if (Length(x) < 1e-4f) x = std::fabs(dir.x) < 0.9f ? Cross({0, 1, 0}, dir) : Cross({0, 0, 1}, dir);
        x = x * (1.0f / Length(x));
        const Vec3 y = Cross(dir, x);
        Mat4 frame = Identity();
        frame.m[0] = x.x; frame.m[1] = x.y; frame.m[2] = x.z;
        frame.m[4] = y.x; frame.m[5] = y.y; frame.m[6] = y.z;
        frame.m[8] = dir.x; frame.m[9] = dir.y; frame.m[10] = dir.z;
        frame.m[12] = a.x; frame.m[13] = a.y; frame.m[14] = a.z;
        out[count++] = {false, Multiply(frame, Scale({r, r, length}))};
        out[count++] = {true, Multiply(frame, Scale({r, r, r}))};
        if (s.b != kForearm) out[count++] = {true, Multiply(frame, Multiply(Translation({0, 0, length}), Scale({r, r, r})))};
    }
    return count;
}

inline std::vector<VertexPC> MakeHandTube(int sides = 14) {
    std::vector<VertexPC> out;
    out.reserve(size_t(sides) * 6);
    for (int i = 0; i < sides; ++i) {
        const float a0 = 2.0f * float(M_PI) * i / sides, a1 = 2.0f * float(M_PI) * (i + 1) / sides;
        const VertexPC p00{{std::cos(a0), std::sin(a0), 0}, {0, 0}}, p10{{std::cos(a1), std::sin(a1), 0}, {0, 0}};
        const VertexPC p01{{std::cos(a0), std::sin(a0), 1}, {0, 0}}, p11{{std::cos(a1), std::sin(a1), 1}, {0, 0}};
        out.insert(out.end(), {p00, p10, p11, p00, p11, p01});
    }
    return out;
}

inline std::vector<VertexPC> MakeHandBall(int sides = 14, int rings = 8) {
    auto point = [&](int i, int j) {
        const float lon = 2.0f * float(M_PI) * i / sides, lat = float(M_PI) * j / rings - float(M_PI) / 2;
        return VertexPC{{std::cos(lat) * std::cos(lon), std::cos(lat) * std::sin(lon), std::sin(lat)}, {0, 0}};
    };
    std::vector<VertexPC> out;
    out.reserve(size_t(sides) * rings * 6);
    for (int j = 0; j < rings; ++j)
        for (int i = 0; i < sides; ++i)
            out.insert(out.end(), {point(i, j), point(i + 1, j), point(i + 1, j + 1),
                                   point(i, j), point(i + 1, j + 1), point(i, j + 1)});
    return out;
}





inline bool HandCard(const XrPosef* joints, const Vec3& viewer, float margin, Mat4& worldFromCard) {
    using namespace hand_detail;
    Vec3 center{};
    int count = 0;
    for (int i = 0; i < XR_HAND_JOINT_COUNT_EXT; ++i) {
        const Vec3 p = Position(joints[i]);
        if (!std::isfinite(p.x) || !std::isfinite(p.y) || !std::isfinite(p.z)) return false;
        center = center + p;
        ++count;
    }
    center = center * (1.0f / count);
    float radius = 0;
    for (int i = 0; i < XR_HAND_JOINT_COUNT_EXT; ++i) radius = std::max(radius, Length(Position(joints[i]) - center));
    radius += margin;
    Vec3 z = viewer - center;
    if (Length(z) < 1e-3f) return false;
    z = z * (1.0f / Length(z));
    Vec3 x = Cross({0, 1, 0}, z);
    if (Length(x) < 1e-3f) x = {1, 0, 0};
    x = x * (1.0f / Length(x));
    const Vec3 y = Cross(z, x);
    Mat4 m = Identity();
    m.m[0] = x.x * 2 * radius; m.m[1] = x.y * 2 * radius; m.m[2] = x.z * 2 * radius;
    m.m[4] = y.x * 2 * radius; m.m[5] = y.y * 2 * radius; m.m[6] = y.z * 2 * radius;
    m.m[8] = z.x; m.m[9] = z.y; m.m[10] = z.z;
    m.m[12] = center.x; m.m[13] = center.y; m.m[14] = center.z;
    worldFromCard = m;
    return true;
}
