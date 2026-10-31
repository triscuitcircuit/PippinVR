#pragma once
// SPDX-License-Identifier: MIT
#include <algorithm>

struct WristClockSettings {
    bool enabled = true;
    int hand = 0;
    int size = 1;
    int format = 0;
    bool showDate = true;
    int position = 0;
    int color = 0;

    bool AllowsHand(int index) const { return hand == 0 || hand == index + 1; }
    float Width() const { return size == 0 ? 0.16f : (size == 2 ? 0.26f : 0.20f); }
    float Offset() const { return position == 0 ? 0.075f : 0.025f; }
    void Normalize() {
        hand = std::clamp(hand, 0, 2); size = std::clamp(size, 0, 2);
        format = std::clamp(format, 0, 2); position = std::clamp(position, 0, 1);
        color = std::clamp(color, 0, 3);
    }
    bool Select(int control) {
        switch (control) {
        case 200: enabled = !enabled; break;
        case 201: hand = (hand + 1) % 3; break;
        case 202: size = (size + 1) % 3; break;
        case 203: format = (format + 1) % 3; break;
        case 204: showDate = !showDate; break;
        case 205: position = (position + 1) % 2; break;
        case 206: color = (color + 1) % 4; break;
        case 207: *this = {}; break;
        default: return false;
        }
        return true;
    }
};

constexpr float kClockControlX = 70, kClockControlY = 142;
constexpr float kClockControlWidth = 434, kClockControlHeight = 78;
constexpr float kClockColumnStride = 450, kClockRowStride = 96;
inline int WristClockControlAt(float x, float y) {
    for (int i = 0; i < 8; ++i) {
        const float left = kClockControlX + (i % 2) * kClockColumnStride;
        const float top = kClockControlY + (i / 2) * kClockRowStride;
        if (x >= left && x <= left + kClockControlWidth && y >= top && y <= top + kClockControlHeight)
            return 200 + i;
    }
    return -1;
}

WristClockSettings LoadWristClockSettings();
bool SaveWristClockSettings(const WristClockSettings& settings);
