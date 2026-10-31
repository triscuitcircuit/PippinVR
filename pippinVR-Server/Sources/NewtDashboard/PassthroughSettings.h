#pragma once
// SPDX-License-Identifier: MIT
#include <algorithm>
#include <cmath>
#include "WristClockSettings.h"




struct PassthroughSettings {
    bool allowed = false;
    bool enabled = false;
    bool stereo = true;
    float width = 1.2f;
    float height = 0.9f;


    int lensMode = 1;
    bool Corrected() const { return lensMode == 1; }
    bool SeeThrough() const { return lensMode == 2; }
    int fov = 1;
    int anchor = 0;
    bool frame = true;
    int direction = 0;
    static constexpr float kDeskPitchDegrees = 35.0f;
    float PitchDownDegrees() const { return direction == 1 ? kDeskPitchDegrees : 0.0f; }


    static constexpr float kWholePortal[8] = {-0.5f, 0.5f, 0.5f, 0.5f, 0.5f, -0.5f, -0.5f, -0.5f};
    float shape[8] = {-0.5f, 0.5f, 0.5f, 0.5f, 0.5f, -0.5f, -0.5f, -0.5f};
    bool tracing = false;
    bool locked = false;





    int hands = 0;
    bool HandOutline() const { return hands == 1; }
    bool HandDepth() const { return hands == 3; }

    static int NextHands(int mode) { return mode == 0 ? 1 : mode == 1 ? 3 : mode == 3 ? 2 : 0; }

    bool hasPose = false;
    float position[3] = {0.0f, 1.1f, -1.6f};
    float orientation[4] = {0, 0, 0, 1};

    static constexpr float kFovDegrees[3] = {70.0f, 90.0f, 110.0f};
    float FovDegrees() const { return kFovDegrees[fov]; }
    void Normalize() {
        width = std::clamp(width, 0.3f, 4.0f);
        height = std::clamp(height, 0.2f, 4.0f);
        fov = std::clamp(fov, 0, 2);
        anchor = std::clamp(anchor, 0, 1);
        direction = std::clamp(direction, 0, 1);
        lensMode = std::clamp(lensMode, 0, 2);
        hands = std::clamp(hands, 0, 3);
        for (float& v : shape) v = std::clamp(v, -0.5f, 0.5f);
    }
    bool Select(int control) {
        switch (control) {
        case 300: enabled = !enabled; break;
        case 301: stereo = !stereo; break;
        case 302: width = PassthroughSettings{}.width; height = PassthroughSettings{}.height; break;
        case 303: lensMode = (lensMode + 1) % 3; break;
        case 304: fov = (fov + 1) % 3; break;
        case 305: anchor = (anchor + 1) % 2; break;
        case 306: frame = !frame; break;
        case 307: direction = (direction + 1) % 2; break;
        case 309: std::copy(kWholePortal, kWholePortal + 8, shape); break;
        case 310: locked = !locked; break;
        case 311: hands = NextHands(hands); break;
        default: return false;
        }
        return true;
    }
};


constexpr int kPassthroughControls = 12;
constexpr float kPassthroughRowStride = 66, kPassthroughTileHeight = 58;
inline int PassthroughControlAt(float x, float y) {
    for (int i = 0; i < kPassthroughControls; ++i) {
        const float left = kClockControlX + (i % 2) * kClockColumnStride;
        const float top = kClockControlY + (i / 2) * kPassthroughRowStride;
        if (x >= left && x <= left + kClockControlWidth && y >= top && y <= top + kPassthroughTileHeight)
            return 300 + i;
    }
    return -1;
}

PassthroughSettings LoadPassthroughSettings();
bool SavePassthroughSettings(const PassthroughSettings& settings);
