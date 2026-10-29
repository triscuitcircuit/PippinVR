#include "HandMaskMath.h"

#include <cassert>
#include <cstdio>
int main() {
    using namespace HandMask;
    constexpr size_t w = 100, h = 60, stride = 104;
    std::vector<uint8_t> labels(stride * h, 0);
    auto paint = [&](int x0, int y0, int x1, int y1, uint8_t label) {
        for (int y = y0; y < y1; ++y)
            for (int x = x0; x < x1; ++x)
                labels[y * stride + x] = label;
    };
    auto at = [&](double x, double y) {
        return Point{(x + 0.5) / w, (y + 0.5) / h};
    };
    paint(10, 10, 40, 50, 3);
    paint(60, 10, 90, 50, 7);
    std::vector<Point> left, right, stray;
    for (int i = 0; i < 8; ++i) {
        left.push_back(at(15 + 3 * i, 20 + i));
        right.push_back(at(65 + 3 * i, 20 + i));
    }
    auto s = SelectLabels(labels.data(), w, h, stride, {left, right});
    assert(s.labels[3] && s.labels[7] && !s.labels[0] && s.hand[0] == 3 && s.hand[1] == 7);

    for (int i = 0; i < 8; ++i)
        stray.push_back(at(45 + i, 55));
    stray.push_back(at(15, 20));
    stray.push_back(at(16, 20));
    s = SelectLabels(labels.data(), w, h, stride, {stray, {}});
    assert(!s.labels[3] && s.hand[0] == 0 && s.hand[1] == 0);

    std::vector<Point> few = {at(15, 20), at(16, 20),      at(17, 20),
                              at(18, 20), Point{1.2, 0.5}, Point{-0.1, 0.5}};
    assert(SelectLabels(labels.data(), w, h, stride, {few}).hand[0] == 0);
    few.push_back(at(19, 20));
    assert(SelectLabels(labels.data(), w, h, stride, {few}).hand[0] == 3);

    paint(10, 10, 90, 50, 4);
    s = SelectLabels(labels.data(), w, h, stride, {left, right});
    assert(s.labels[4] && s.hand[0] == 4 && s.hand[1] == 4);

    assert(SelectLabels(nullptr, w, h, stride, {left}).hand[0] == 0);
    assert(SelectLabels(labels.data(), w, h, w - 1, {left}).hand[0] == 0);
    puts(
        "PASS: hand mask instance votes per hand, background and stray rejection, shared "
        "instances, bounds");
}
