#pragma once
// SPDX-License-Identifier: MIT




#include <algorithm>
#include <cmath>
#include <string>
#include <vector>

namespace customui {

enum class Anchor {
    World,
    Head,
    Dashboard,
};

struct Button {
    std::string id;
    std::string label;
};

struct PanelSpec {
    std::string id;
    std::string title;
    std::vector<std::string> lines;
    std::vector<Button> buttons;
    std::string image;
    Anchor anchor = Anchor::World;
    float width = 0.55f;
    float position[3] = {0, -0.05f, -0.9f};
    bool closable = true;
    float accent[3] = {0.45f, 0.85f, 0.72f};
};

constexpr float kCardWidth = 1024;
constexpr int kMaxLines = 16, kMaxButtons = 9, kButtonsPerRow = 3;
constexpr float kMaxCardHeight = 1536;

struct Area {
    float x = 0, y = 0, w = 0, h = 0;
    bool Contains(float px, float py) const { return w > 0 && px >= x && px <= x + w && py >= y && py <= y + h; }
};

struct Layout {
    float height = 0;
    Area title, close, image;
    std::vector<Area> lines, buttons;
};


inline Layout LayoutPanel(const PanelSpec& spec, float imageAspect) {
    constexpr float pad = 36, titleHeight = 64, lineHeight = 42, buttonHeight = 84, gap = 20, closeSize = 76;
    Layout layout;
    float y = pad;
    if (spec.closable) layout.close = {kCardWidth - pad - closeSize, pad - 8, closeSize, closeSize};
    const float textWidth = kCardWidth - 2 * pad - (spec.closable ? closeSize + gap : 0);
    if (!spec.title.empty()) {
        layout.title = {pad, y, textWidth, titleHeight};
        y += titleHeight + gap / 2;
    } else if (spec.closable) {
        y = std::max(y, layout.close.y + layout.close.h + gap / 2);
    }
    const int lines = std::min<int>(int(spec.lines.size()), kMaxLines);
    for (int i = 0; i < lines; ++i) {
        layout.lines.push_back({pad, y, kCardWidth - 2 * pad, lineHeight});
        y += lineHeight;
    }
    if (lines) y += gap;
    if (imageAspect > 0.01f && std::isfinite(imageAspect)) {
        const float w = kCardWidth - 2 * pad;
        const float h = std::min(w / imageAspect, 640.0f);
        const float fitted = h * imageAspect;
        layout.image = {(kCardWidth - fitted) / 2, y, fitted, h};
        y += h + gap;
    }
    const int buttons = std::min<int>(int(spec.buttons.size()), kMaxButtons);
    for (int row = 0; row * kButtonsPerRow < buttons; ++row) {
        const int inRow = std::min(kButtonsPerRow, buttons - row * kButtonsPerRow);
        const float w = (kCardWidth - 2 * pad - gap * (inRow - 1)) / inRow;
        for (int i = 0; i < inRow; ++i) layout.buttons.push_back({pad + i * (w + gap), y, w, buttonHeight});
        y += buttonHeight + gap;
    }
    if (!buttons) y += pad - gap / 2;
    layout.height = std::clamp(y + (buttons ? pad - gap : 0), 120.0f, kMaxCardHeight);
    return layout;
}

constexpr int kNoHit = -1, kCloseHit = -2;

inline int HitTest(const Layout& layout, float x, float y) {
    if (layout.close.Contains(x, y)) return kCloseHit;
    for (size_t i = 0; i < layout.buttons.size(); ++i)
        if (layout.buttons[i].Contains(x, y)) return int(i);
    return kNoHit;
}

}

#ifdef __OBJC__
#import <Foundation/Foundation.h>
namespace customui {


bool ParsePanelSpec(NSDictionary* json, const std::string& panelId, PanelSpec& out, std::string& error);
}
#endif
