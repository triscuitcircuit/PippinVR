#include "Recenter.h"

#include <cassert>
#include <cstdio>
using namespace recenter;
static XrPosef Inverse(const XrPosef& p) {
    XrPosef out;
    out.orientation = {-p.orientation.x, -p.orientation.y, -p.orientation.z, p.orientation.w};
    const Vec3 v = Rotate(out.orientation, Vec3{p.position.x, p.position.y, p.position.z});
    out.position = {-v.x, -v.y, -v.z};
    return out;
}
static bool Near(const XrPosef& a, const XrPosef& b) {
    const float dp = std::fabs(a.position.x - b.position.x) +
                     std::fabs(a.position.y - b.position.y) +
                     std::fabs(a.position.z - b.position.z);
    float dot = a.orientation.x * b.orientation.x + a.orientation.y * b.orientation.y +
                a.orientation.z * b.orientation.z + a.orientation.w * b.orientation.w;
    return dp < 1e-4f && std::fabs(std::fabs(dot) - 1) < 1e-5f;
}
int main() {
    XrPosef screen{{0.1f, 0.2f, 0.05f, 0.97f}, {0.3f, 1.4f, -1.5f}};
    const float n = std::sqrt(0.1f * 0.1f + 0.2f * 0.2f + 0.05f * 0.05f + 0.97f * 0.97f);
    screen.orientation = {0.1f / n, 0.2f / n, 0.05f / n, 0.97f / n};
    const Home home{0, 0, 0};

    const float yaw = float(M_PI / 2), pitch = -0.3f;
    XrPosef viewer;
    const XrQuaternionf qy{0, std::sin(yaw / 2), 0, std::cos(yaw / 2)},
        qp{std::sin(pitch / 2), 0, 0, std::cos(pitch / 2)};
    viewer.orientation = {qy.w * qp.x + qy.x * qp.w + qy.y * qp.z - qy.z * qp.y,
                          qy.w * qp.y - qy.x * qp.z + qy.y * qp.w + qy.z * qp.x,
                          qy.w * qp.z + qy.x * qp.y - qy.y * qp.x + qy.z * qp.w,
                          qy.w * qp.w - qy.x * qp.x - qy.y * qp.y - qy.z * qp.z};
    viewer.position = {2, 1.7f, 3};
    const Home to = ViewerHome(viewer);
    assert(std::fabs(to[0] - 2) < 1e-5f && std::fabs(to[1] - 3) < 1e-5f &&
           std::fabs(to[2] - yaw) < 1e-4f);
    const XrPosef moved = Apply(Delta(home, to), screen);

    assert(Near(Apply(Inverse(HomePose(to)), moved), Apply(Inverse(HomePose(home)), screen)));
    assert(std::fabs(moved.position.y - 1.4f) < 1e-5f);

    assert(std::fabs(moved.position.x - (2 - 1.5f)) < 0.35f &&
           std::fabs(moved.position.z - (3 - 0.3f)) < 0.35f);

    assert(Near(Apply(Delta(to, to), moved), moved));

    const Home mid{-1, 0.5f, 2.0f};
    assert(Near(Apply(Delta(mid, to), Apply(Delta(home, mid), screen)), moved));
    puts("PASS: recenter keeps the layout relative to the viewer, keeps heights, composes");
}
