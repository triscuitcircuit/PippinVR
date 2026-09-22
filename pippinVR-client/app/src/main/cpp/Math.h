
#ifndef PIPPINVR_MATH_H
#define PIPPINVR_MATH_H

#include <glm/glm.hpp>
#include <glm/gtc/quaternion.hpp>

#include <openxr/openxr.h>

namespace pippinvr {

inline glm::vec3 toGlm(const XrVector3f& v) { return {v.x, v.y, v.z}; }

inline glm::quat toGlm(const XrQuaternionf& q) {
    return glm::quat(q.w, q.x, q.y, q.z);
}

inline XrVector3f toXr(const glm::vec3& v) { return {v.x, v.y, v.z}; }

inline XrQuaternionf toXr(const glm::quat& q) { return {q.x, q.y, q.z, q.w}; }

struct Pose {
    glm::vec3 position{0.0f};
    glm::quat orientation{1.0f, 0.0f, 0.0f, 0.0f};

    Pose() = default;
    Pose(const glm::vec3& p, const glm::quat& o) : position(p), orientation(o) {}
    explicit Pose(const XrPosef& p)
        : position(toGlm(p.position)), orientation(toGlm(p.orientation)) {}

    XrPosef toXrPose() const {
        XrPosef out;
        out.position = toXr(position);
        out.orientation = toXr(glm::normalize(orientation));
        return out;
    }

    Pose operator*(const Pose& rhs) const {
        return Pose(position + orientation * rhs.position, orientation * rhs.orientation);
    }

    Pose inverse() const {
        const glm::quat inv = glm::conjugate(orientation);
        return Pose(inv * -position, inv);
    }
};


inline bool rayQuadIntersect(const glm::vec3& origin, const glm::vec3& direction,
                             const Pose& quad, float width, float height,
                             float* distance) {
    const glm::quat inv = glm::conjugate(quad.orientation);
    const glm::vec3 localOrigin = inv * (origin - quad.position);
    const glm::vec3 localDir = inv * direction;

    if (glm::abs(localDir.z) < 1e-6f) return false;   // parallel to the quad

    const float t = -localOrigin.z / localDir.z;
    if (t <= 0.0f) return false;                      // behind the ray origin

    const glm::vec2 hit(localOrigin.x + localDir.x * t, localOrigin.y + localDir.y * t);
    if (glm::abs(hit.x) > width * 0.5f) return false;
    if (glm::abs(hit.y) > height * 0.5f) return false;

    *distance = t;
    return true;
}

inline glm::vec3 forwardOf(const Pose& pose) {
    return glm::normalize(pose.orientation * glm::vec3(0.0f, 0.0f, -1.0f));
}

}  // namespace pippinvr

#endif  // PIPPINVR_MATH_H
