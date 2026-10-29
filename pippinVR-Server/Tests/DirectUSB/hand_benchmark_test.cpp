#include "HandBenchmarkMath.h"

#include <cassert>
#include <cstdio>
#include <limits>
int main() {
    using namespace HandBenchmark;

    const uint8_t labels[] = {2, 2, 2, 99, 99, 0, 0, 3, 99, 99};
    assert(LabelAt(labels, 3, 2, 5, {0, 1, 1}) == 2);
    assert(LabelAt(labels, 3, 2, 5, {1, 0, 1}) == 3);
    assert(LabelAt(labels, 3, 2, 5, {0, 0, 1}) == 0);
    assert(LabelAt(labels, 3, 2, 5, {1.01, 0, 1}) == 0);
    assert(LabelAt(labels, 3, 2, 5, {0, 1, 0.2}) == 0);
    assert(LabelAt(labels, 3, 2, 5, {NAN, 1, 1}) == 0);
    assert(LabelAt(labels, 3, 2, 2, {0, 1, 1}) == 0);
    assert(LabelAt(nullptr, 3, 2, 5, {0, 1, 1}) == 0);
    constexpr size_t w = 100, h = 60, stride = 104;
    std::vector<uint8_t> scene(stride * h, 0);
    auto paint = [&](int x0, int y0, int x1, int y1, uint8_t label) {
        for (int y = y0; y < y1; ++y)
            for (int x = x0; x < x1; ++x)
                scene[y * stride + x] = label;
    };
    auto point = [&](double x, double y, double confidence = 1.0) {
        return Point{(x + 0.5) / w, 1 - (y + 0.5) / h, confidence};
    };
    const std::vector<Point> hand = {point(22, 22), point(30, 22), point(37, 22),
                                     point(22, 37), point(30, 37), point(37, 37)};
    auto select = [&](std::vector<std::vector<Point>> hands) {
        return SelectLabels(scene.data(), w, h, stride, hands);
    };
    paint(20, 20, 40, 40, 2);
    paint(70, 20, 90, 40, 3);
    paint(100, 0, 104, 60, 2);
    const auto original = scene;
    auto selection = select({hand});
    assert(selection.labels[2] && !selection.labels[0] && !selection.labels[3]);
    assert(selection.weakHands == 0 && scene == original);
    auto regionAt = [&](const Selection& sel, int x, int y) {
        return sel.region[size_t(y) * w + x];
    };
    assert(regionAt(selection, 30, 30) == 255 && regionAt(selection, 80, 30) == 0);
    assert(selection.selectedPixels == 400 && selection.clippedPixels == 0);
    assert(!select({}).labels[2]);
    assert(select({{hand[0], hand[1], hand[2]}}).weakHands == 1);
    auto uncertain = hand;
    uncertain[0].confidence = 0.5;
    assert(select({uncertain}).weakHands == 0);
    uncertain[1].confidence = 0.5;
    assert(select({uncertain}).weakHands == 1);
    auto scattered = hand;
    for (int i = 0; i < 6; ++i)
        scattered.push_back(point(50 + i, 50));
    assert(select({scattered}).weakHands == 1);
    assert(select({std::vector<Point>(6, point(22, 22))}).weakHands == 1);
    assert(select({std::vector<Point>(6, point(22, 22, NAN))}).weakHands == 1);
    paint(70, 20, 90, 40, 2);
    selection = select({hand});
    assert(selection.labels[2] && regionAt(selection, 30, 30) == 255 &&
           regionAt(selection, 80, 30) == 0);
    assert(selection.selectedPixels == 800 && selection.clippedPixels == 400);
    std::vector<Point> otherHand;
    for (auto p : hand) {
        p.x += 0.5;
        otherHand.push_back(p);
    }
    selection = select({hand, otherHand});
    assert(selection.labels[2] && regionAt(selection, 30, 30) == 255 &&
           regionAt(selection, 80, 30) == 255);
    paint(0, 0, 100, 60, 2);
    selection = select({hand, otherHand});
    assert(selection.labels[2] && regionAt(selection, 2, 58) == 0 &&
           regionAt(selection, 55, 30) == 0);

    {
        constexpr size_t W = 200, H = 200;
        std::vector<uint8_t> body(W * H, 5);
        auto at = [&](double x, double y, int joint) {
            return Point{(x + 0.5) / W, 1 - (y + 0.5) / H, 1.0, joint};
        };
        std::vector<Point> named = {at(100, 150, 0)};
        const double fx[5] = {70, 85, 100, 115, 130};
        for (int k = 0; k < 4; ++k)
            named.push_back(at(70 - 4 * k, 135 - 10 * k, 1 + k));
        for (int f = 0; f < 4; ++f)
            for (int k = 0; k < 4; ++k)
                named.push_back(at(fx[f + 1], 110 - 15 * k, 5 + 4 * f + k));
        const auto s2 = SelectLabels(body.data(), W, H, W, {named});
        auto r = [&](int x, int y) {
            return s2.region[size_t(y) * W + x];
        };
        assert(s2.labels[5] && s2.weakHands == 0);
        assert(r(100, 130) == 255 && r(130, 65) == 255 && r(58, 105) == 255);
        assert(r(100, 175) == 255);
        assert(r(100, 10) == 0 && r(190, 150) == 0 && r(10, 10) == 0);
        assert(s2.clippedPixels > 0 && s2.clippedPixels < s2.selectedPixels);
    }
    assert(!SelectLabels(nullptr, w, h, stride, {hand}).labels[2]);
    assert(!SelectLabels(scene.data(), w, h, w - 1, {hand}).labels[2]);
    assert(Phase(-1) == -1 && Phase(0) == 0 && Phase(9.999) == 0);
    assert(Phase(10) == 1 && Phase(15) == 2 && Phase(75) == -1 && Phase(NAN) == -1);
    assert(Percentile({1, 100, 2, 3}, 0.5) == 2);
    assert(Percentile({1, 100, 2, 3}, 0.95) == 100);
    puts(
        "PASS: mask coordinates, confidence/majority filtering, hand-region cut of distant objects "
        "and body, shared hand instances, named-joint regions with forearm, phase boundaries, "
        "percentiles");
}
