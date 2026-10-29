#pragma once
// SPDX-License-Identifier: MIT
#include "Newt/MathTypes.h"


class WristClockGesture {
public:
    bool visible = false;

    void Reset() { visible = false; entered = departed = -1; }

    void Update(double now, bool tracked, const XrPosef& palm, const XrPosef& viewer) {
        if (!tracked || !std::isfinite(now) || !ValidPose(palm) || !ValidPose(viewer)) { Reset(); return; }
        const Vec3 toHead{viewer.position.x - palm.position.x, viewer.position.y - palm.position.y,
                          viewer.position.z - palm.position.z};
        const float distance = std::sqrt(Dot(toHead, toHead));
        if (distance < 0.20f || distance > 0.85f) { Reset(); return; }
        const Vec3 direction = toHead * (1.0f / distance);
        const Vec3 palmNormal = Rotate(palm.orientation, {0, -1, 0});
        const Vec3 headForward = Rotate(viewer.orientation, {0, 0, -1});
        const bool facing = Dot(palmNormal, direction) >= (visible ? 0.55f : 0.75f) &&
                            Dot(headForward, direction * -1.0f) > 0.5f;
        if (facing) {
            departed = -1;
            if (entered < 0 || now < entered) entered = now;
            if (now - entered >= 0.25) visible = true;
        } else {
            entered = -1;
            if (departed < 0 || now < departed) departed = now;
            if (now - departed >= 0.12) visible = false;
        }
    }

    static bool ValidPose(const XrPosef& pose) {
        const auto& q = pose.orientation;
        const float norm = q.x*q.x + q.y*q.y + q.z*q.z + q.w*q.w;
        return std::isfinite(pose.position.x) && std::isfinite(pose.position.y) &&
               std::isfinite(pose.position.z) && std::isfinite(norm) && norm > 0.9f && norm < 1.1f;
    }

private:
    double entered = -1, departed = -1;
    static float Dot(const Vec3& a, const Vec3& b) { return a.x*b.x + a.y*b.y + a.z*b.z; }
};
