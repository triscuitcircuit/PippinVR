#pragma once
// SPDX-License-Identifier: MIT
#include <algorithm>
#include <array>
#include <cmath>
#include <cstddef>
#include <cstdint>
#include <vector>

namespace HandBenchmark {


struct Point { double x, y, confidence; int joint = -1; };

inline uint8_t LabelAt(const uint8_t* labels, size_t width, size_t height, size_t stride, Point p) {
    if (!labels || !width || !height || stride < width || !std::isfinite(p.x) || !std::isfinite(p.y) ||
        !std::isfinite(p.confidence) || p.confidence < 0.4 || p.x < 0 || p.x > 1 || p.y < 0 || p.y > 1)
        return 0;
    const size_t x = std::min(width - 1, size_t(p.x * width));
    const size_t y = std::min(height - 1, size_t((1 - p.y) * height));
    return labels[y * stride + x];
}

inline constexpr double SelectionConfidence = 0.6;


inline constexpr unsigned MinimumJointVotes = 5;
inline constexpr double MinimumJointAgreement = 0.55;
inline constexpr double HandBoundsPadding = 0.35;


inline constexpr double FingerReach = 0.32, PalmReach = 0.45, ForearmReach = 0.6;
inline constexpr double ForearmLength = 1.3, RegionFeather = 0.12;
struct Selection {
    std::array<bool, 256> labels{};
    unsigned weakHands = 0;




    std::vector<uint8_t> region;
    size_t selectedPixels = 0, clippedPixels = 0;
};
namespace detail {
struct Capsule { double ax, ay, bx, by, radius; };
inline double SegmentDistance(double px, double py, const Capsule& c) {
    const double dx = c.bx - c.ax, dy = c.by - c.ay, len2 = dx * dx + dy * dy;
    const double t = len2 > 0 ? std::clamp(((px - c.ax) * dx + (py - c.ay) * dy) / len2, 0.0, 1.0) : 0.0;
    return std::hypot(px - (c.ax + t * dx), py - (c.ay + t * dy));
}

constexpr int kFingerBones[][2] = {{1,2},{2,3},{3,4}, {5,6},{6,7},{7,8}, {9,10},{10,11},{11,12},
                                   {13,14},{14,15},{15,16}, {17,18},{18,19},{19,20}};
constexpr int kPalmBones[][2] = {{0,1},{0,5},{0,9},{0,13},{0,17},{1,5},{5,9},{9,13},{13,17}};
}
inline Selection SelectLabels(const uint8_t* labels, size_t width, size_t height, size_t stride,
                              const std::vector<std::vector<Point>>& hands) {
    Selection result;
    if (!labels || !width || !height || stride < width) return result;
    std::vector<detail::Capsule> capsules;
    struct Box { double x0, y0, x1, y1; };
    std::vector<Box> boxes;
    double feather = 2;
    for (const auto& points : hands) {
        std::array<unsigned, 256> votes{};
        std::array<bool, 21> have{};
        std::array<double, 21> jx{}, jy{};
        unsigned valid = 0;
        double x0 = double(width), y0 = double(height), x1 = 0, y1 = 0;
        for (const auto& p : points) {
            if (!std::isfinite(p.x) || !std::isfinite(p.y) || !std::isfinite(p.confidence) ||
                p.confidence < SelectionConfidence || p.x < 0 || p.x > 1 || p.y < 0 || p.y > 1) continue;
            ++valid;
            ++votes[LabelAt(labels, width, height, stride, p)];
            const double x = std::min(double(width - 1), p.x * width);
            const double y = std::min(double(height - 1), (1 - p.y) * height);
            x0 = std::min(x0, x); x1 = std::max(x1, x);
            y0 = std::min(y0, y); y1 = std::max(y1, y);
            if (p.joint >= 0 && p.joint < 21) { have[p.joint] = true; jx[p.joint] = x + 0.5; jy[p.joint] = y + 0.5; }
        }
        uint8_t best = 0;
        for (unsigned i = 1; i < votes.size(); ++i)
            if (votes[i] >= MinimumJointVotes && votes[i] >= MinimumJointAgreement * valid &&
                (!best || votes[i] > votes[best])) best = uint8_t(i);
        const double span = std::max(x1 - x0, y1 - y0);
        if (!best || span < 2) { ++result.weakHands; continue; }
        result.labels[best] = true;

        double palm = 0;
        for (int k : {9, 5, 13, 17})
            if (have[0] && have[k]) { palm = std::hypot(jx[k] - jx[0], jy[k] - jy[0]); break; }
        if (palm < 2) {

            const double pad = std::max(2.0, HandBoundsPadding * span);
            boxes.push_back({x0 - pad, y0 - pad, x1 + 1 + pad, y1 + 1 + pad});
            continue;
        }
        feather = std::max(feather, RegionFeather * palm);
        auto add = [&](int a, int b, double reach) {
            if (have[a] && have[b]) capsules.push_back({jx[a], jy[a], jx[b], jy[b], reach * palm});
        };
        for (const auto& bone : detail::kFingerBones) add(bone[0], bone[1], FingerReach);
        for (const auto& bone : detail::kPalmBones) add(bone[0], bone[1], PalmReach);
        for (int i = 0; i < 21; ++i)
            if (have[i]) capsules.push_back({jx[i], jy[i], jx[i], jy[i], FingerReach * palm});

        int knuckle = -1;
        for (int k : {9, 5, 13, 17}) if (have[k]) { knuckle = k; break; }
        if (have[0] && knuckle >= 0) {
            const double dx = jx[0] - jx[knuckle], dy = jy[0] - jy[knuckle], len = std::hypot(dx, dy);
            if (len > 1e-6)
                capsules.push_back({jx[0], jy[0], jx[0] + dx / len * ForearmLength * palm,
                                    jy[0] + dy / len * ForearmLength * palm, ForearmReach * palm});
        }
    }
    if (capsules.empty() && boxes.empty()) return result;

    std::vector<float> outside(width * height, 1e30f);
    auto visit = [&](double x0, double y0, double x1, double y1, auto&& distance) {
        const size_t ya = size_t(std::clamp(std::floor(y0 - feather), 0.0, double(height)));
        const size_t yb = size_t(std::clamp(std::ceil(y1 + feather), 0.0, double(height)));
        const size_t xa = size_t(std::clamp(std::floor(x0 - feather), 0.0, double(width)));
        const size_t xb = size_t(std::clamp(std::ceil(x1 + feather), 0.0, double(width)));
        for (size_t y = ya; y < yb; ++y)
            for (size_t x = xa; x < xb; ++x) {
                float& d = outside[y * width + x];
                d = std::min(d, float(distance(x + 0.5, y + 0.5)));
            }
    };
    for (const auto& c : capsules)
        visit(std::min(c.ax, c.bx) - c.radius, std::min(c.ay, c.by) - c.radius,
              std::max(c.ax, c.bx) + c.radius, std::max(c.ay, c.by) + c.radius,
              [&](double px, double py) { return detail::SegmentDistance(px, py, c) - c.radius; });
    for (const auto& b : boxes)
        visit(b.x0, b.y0, b.x1, b.y1, [&](double px, double py) {
            return std::hypot(std::max({b.x0 - px, 0.0, px - b.x1}), std::max({b.y0 - py, 0.0, py - b.y1}));
        });
    result.region.assign(width * height, 0);
    for (size_t y = 0; y < height; ++y) {
        for (size_t x = 0; x < width; ++x) {
            const double alpha = std::clamp(1.0 - outside[y * width + x] / feather, 0.0, 1.0);
            const uint8_t value = uint8_t(std::lround(alpha * 255));
            result.region[y * width + x] = value;
            if (result.labels[labels[y * stride + x]]) {
                ++result.selectedPixels;
                if (value == 0) ++result.clippedPixels;
            }
        }
    }
    return result;
}

inline int Phase(double seconds) {
    if (!std::isfinite(seconds) || seconds < 0 || seconds >= 75) return -1;
    return seconds < 10 ? 0 : (seconds < 15 ? 1 : 2);
}
inline double Percentile(std::vector<double> values, double percentile) {
    if (values.empty()) return 0;
    std::sort(values.begin(), values.end());
    return values[std::min(values.size() - 1, size_t(std::ceil(percentile * values.size()) - 1))];
}
}
