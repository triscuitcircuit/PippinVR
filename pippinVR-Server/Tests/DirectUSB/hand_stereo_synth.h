#pragma once
#include "HandStereoMath.h"

#include <cstring>

inline PassthroughCamera SynthCamera(double x, double yawDeg) {
    PassthroughCamera c;
    std::strcpy(c.projection_model, "PinholeSymmetric");
    std::strcpy(c.distortion_model, "Fisheye62");
    c.width = 2328;
    c.height = 1748;
    c.projection_count = 3;
    c.projection[0] = 900;
    c.projection[1] = 1164 + 7;
    c.projection[2] = 874 - 5;
    c.distortion_count = 8;
    const double k[8] = {-0.02, 0.01, -0.003, 0.0005, 0, 0, 0.0004, -0.0003};
    for (int i = 0; i < 8; ++i)
        c.distortion[i] = k[i];

    const double p = 11 * M_PI / 180, yw = yawDeg * M_PI / 180;
    stereo::V3 zc{std::sin(yw) * std::cos(p), -std::sin(p), -std::cos(yw) * std::cos(p)};
    stereo::V3 xc = stereo::Normalize(stereo::Cross(zc, {0, 1, 0}));
    xc = {-xc[0], -xc[1], -xc[2]};
    if (xc[0] < 0)
        xc = {-xc[0], -xc[1], -xc[2]};
    stereo::V3 yc = stereo::Cross(zc, xc);
    const double m[16] = {xc[0], yc[0], zc[0], x,      xc[1], yc[1], zc[1], -0.017,
                          xc[2], yc[2], zc[2], -0.062, 0,     0,     0,     1};
    std::memcpy(c.device_from_camera, m, sizeof m);
    return c;
}
