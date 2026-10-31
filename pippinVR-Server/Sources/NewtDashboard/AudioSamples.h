#pragma once
// SPDX-License-Identifier: MIT
#include <cstddef>
#include <vector>

namespace systemaudio {
inline bool CopyStereo(const float* left, size_t leftBytes, const float* right, size_t rightBytes,
                       size_t frames, size_t stride, std::vector<float>& outLeft, std::vector<float>& outRight) {
    if (!left || !right || !frames || !stride) return false;
    const auto fits = [=](size_t bytes) {
        const size_t samples = bytes / sizeof(float);
        return samples && frames - 1 <= (samples - 1) / stride;
    };
    if (!fits(leftBytes) || !fits(rightBytes)) return false;
    outLeft.resize(frames);
    outRight.resize(frames);
    for (size_t i = 0; i < frames; ++i) {
        outLeft[i] = left[i * stride];
        outRight[i] = right[i * stride];
    }
    return true;
}
}
