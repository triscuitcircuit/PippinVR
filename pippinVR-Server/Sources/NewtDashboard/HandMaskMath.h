#pragma once
// SPDX-License-Identifier: MIT

#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <vector>

namespace HandMask {

struct Point { double x, y; };

inline constexpr unsigned kMinimumVotes = 5;
inline constexpr double kMinimumAgreement = 0.5;

struct Selection {
    std::array<bool, 256> labels{};
    std::vector<int> hand;
};

inline Selection SelectLabels(const uint8_t* labels, size_t width, size_t height, size_t stride,
                              const std::vector<std::vector<Point>>& hands) {
    Selection selected;
    selected.hand.assign(hands.size(), 0);
    if (!labels || !width || !height || stride < width) return selected;
    for (size_t h = 0; h < hands.size(); ++h) {
        const auto& points = hands[h];
        std::array<unsigned, 256> votes{};
        unsigned inside = 0;
        for (const auto& p : points) {
            if (!std::isfinite(p.x) || !std::isfinite(p.y) || p.x < 0 || p.x >= 1 || p.y < 0 || p.y >= 1) continue;
            ++inside;
            ++votes[labels[size_t(p.y * height) * stride + size_t(p.x * width)]];
        }
        int best = 0;
        for (int i = 1; i < 256; ++i)
            if (votes[i] > (best ? votes[best] : 0u)) best = i;
        if (best > 0 && votes[best] >= kMinimumVotes && votes[best] >= kMinimumAgreement * inside) {
            selected.labels[best] = true;
            selected.hand[h] = best;
        }
    }
    return selected;
}
}
