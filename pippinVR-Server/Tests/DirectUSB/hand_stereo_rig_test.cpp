#include "hand_stereo_synth.h"

#include <cassert>
#include <chrono>
#include <cstdio>
using namespace stereo;
int main() {
    const PassthroughCamera L = SynthCamera(-0.032, 1.5), R = SynthCamera(0.032, -1.0);
    auto t0 = std::chrono::steady_clock::now();
    auto rig = BuildRig(L, R);
    printf(
        "build %.0f ms\n",
        std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count());
    assert(rig);
    printf("baseline %.4f m, f %.1f\n", rig->baseline, rig->f);

    double worstRow = 0, worstZ = 0;
    for (double dist : {0.25, 0.4, 0.7, 1.5})
        for (double sx : {-0.3, 0.0, 0.25})
            for (double sy : {-0.35, -0.1, 0.1}) {
                const V3 head{sx * dist, sy * dist - 0.05, -dist};
                const V3 a = rig->RectPoint(0, head), b = rig->RectPoint(1, head);
                double xa, ya, xb, yb;
                assert(rig->RectPixel(a, xa, ya) && rig->RectPixel(b, xb, yb));
                worstRow = std::max(worstRow, std::fabs(ya - yb));
                const double d = xa - xb, Z = rig->f * rig->baseline / d;
                worstZ = std::max(worstZ, std::fabs(Z - a[2]) / a[2]);

                M3 hc;
                V3 cc;
                HeadFromCamera(L, hc, cc);
                const V3 cam =
                    Mul(Transpose(hc), V3{head[0] - cc[0], head[1] - cc[1], head[2] - cc[2]});
                double pu, pv;
                assert(LensProject(L, LensModelOf(L), cam[0], cam[1], cam[2], pu, pv));
                const int ix = int(std::lround(xa)), iy = int(std::lround(ya));
                if (ix >= 0 && ix < rig->width && iy >= 0 && iy < rig->height) {
                    const float fu = rig->forward[0][(size_t(iy) * rig->width + ix) * 2] * L.width;
                    const float fv =
                        rig->forward[0][(size_t(iy) * rig->width + ix) * 2 + 1] * L.height;

                    assert(std::hypot(fu - pu, fv - pv) < 1.2 * L.projection[0] / rig->f + 1);

                    const int gx = int(pu / rig->step), gy = int(pv / rig->step);
                    const float rx = rig->inverse[0][(size_t(gy) * rig->gridWidth + gx) * 2];
                    const float ry = rig->inverse[0][(size_t(gy) * rig->gridWidth + gx) * 2 + 1];
                    assert(rx >= 0 && std::hypot(rx - xa, ry - ya) < 4);
                }
            }
    printf("worst row mismatch %.4f px, worst depth error %.4f%%\n", worstRow, worstZ * 100);
    assert(worstRow < 1e-6 && worstZ < 1e-9);

    double a, b, u, v;

    for (double px : {150.0, 600.0, 1164.0, 2100.0})
        for (double py : {200.0, 874.0, 1600.0}) {
            assert(Unproject(L, LensModelOf(L), px, py, a, b));
            LensProject(L, LensModelOf(L), a, b, 1, u, v);
            assert(std::hypot(u - px, v - py) < 0.1);
        }
    size_t valid = 0;
    for (size_t i = 0; i < rig->forward[0].size(); i += 2)
        valid += rig->forward[0][i] >= 0;
    printf("forward map coverage %.1f%%\n", 100.0 * valid / (rig->forward[0].size() / 2));
    puts("PASS: rectified rows align, disparity gives distance, maps agree, fisheye unprojection");
}
