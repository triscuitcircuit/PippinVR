#pragma once
#include <algorithm>
#include <cmath>

struct StereoLayout {
    float sourceX, sourceY, sourceWidth, sourceHeight;
    float destinationX, destinationY, destinationWidth, destinationHeight;
};

inline StereoLayout CalculateStereoLayout(int mode, int eye, float fullAspect, float panelAspect, float alignment) {
    const bool vertical = mode == 3 || mode == 4;
    const bool fullWidth = mode == 5 || mode == 6;
    alignment = std::clamp(alignment, -0.4f, 0.4f);
    const float crop = 1.0f - std::abs(alignment);
    float eyeAspect = vertical ? ((fullAspect < 1.1f) ? fullAspect * 2 : fullAspect)
        : (fullWidth || fullAspect > 2.4f ? fullAspect * 0.5f : fullAspect);
    const float offset = alignment >= 0 ? (eye == 0 ? alignment : 0.0f) : (eye == 1 ? -alignment : 0.0f);
    eyeAspect *= crop;
    const float w = std::min(1.0f, eyeAspect / panelAspect);
    const float h = std::min(1.0f, panelAspect / eyeAspect);
    if (vertical) return {offset, eye * 0.5f, crop, 0.5f, (1-w)*0.5f, (1-h)*0.5f, w, h};
    return {(eye + offset) * 0.5f, 0, crop * 0.5f, 1, (1-w)*0.5f, (1-h)*0.5f, w, h};
}
