#pragma once
// SPDX-License-Identifier: MIT
#include <algorithm>
#include <cmath>
#include <cstdint>

struct MetalFXResolution {
    uint32_t width = 0;
    uint32_t height = 0;
};

inline bool ValidMetalFXScale(float scale) {
    return scale == 0 || scale == 1.25f || scale == 1.5f || scale == 2.0f;
}


inline MetalFXResolution MetalFXOutputResolution(uint32_t width, uint32_t height, float requestedScale) {
    if (width < 64 || height < 64 || width >= 3840 || height >= 2400) return {};
    const float scale = requestedScale > 0 && ValidMetalFXScale(requestedScale)
        ? requestedScale : (width <= 1536 ? 2.0f : 1.5f);
    const double cappedScale = std::min({double(scale), 3840.0 / width, 2400.0 / height});
    const uint32_t outputWidth = static_cast<uint32_t>(width * cappedScale) & ~uint32_t(1);
    const uint32_t outputHeight = static_cast<uint32_t>(height * cappedScale) & ~uint32_t(1);
    if (outputWidth <= width || outputHeight <= height) return {};
    return {outputWidth, outputHeight};
}
