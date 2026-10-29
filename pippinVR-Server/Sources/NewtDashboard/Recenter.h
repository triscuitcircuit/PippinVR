#pragma once
// SPDX-License-Identifier: MIT




#include "Newt/MathTypes.h"
#include <array>
#include <cmath>

namespace recenter {

using Home = std::array<float, 3>;

inline XrPosef HomePose(const Home& h) {
    return {{0, std::sin(h[2] / 2), 0, std::cos(h[2] / 2)}, {h[0], 0, h[1]}};
}


inline Home ViewerHome(const XrPosef& viewer) {
    const Vec3 f = Rotate(viewer.orientation, Vec3{0, 0, -1});
    return {viewer.position.x, viewer.position.z, std::atan2(-f.x, -f.z)};
}


inline XrPosef Apply(const XrPosef& delta, const XrPosef& pose) {
    XrPosef out;
    const XrQuaternionf& a = delta.orientation;
    const XrQuaternionf& b = pose.orientation;
    out.orientation = {a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y, a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
                       a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w, a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z};
    const Vec3 p = Rotate(delta.orientation, Vec3{pose.position.x, pose.position.y, pose.position.z});
    out.position = {p.x + delta.position.x, p.y + delta.position.y, p.z + delta.position.z};
    return out;
}


inline XrPosef Delta(const Home& from, const Home& to) {
    const XrPosef a = HomePose(from), b = HomePose(to);

    XrPosef inverse;
    inverse.orientation = {-a.orientation.x, -a.orientation.y, -a.orientation.z, a.orientation.w};
    const Vec3 p = Rotate(inverse.orientation, Vec3{a.position.x, a.position.y, a.position.z});
    inverse.position = {-p.x, -p.y, -p.z};
    return Apply(b, inverse);
}
}
