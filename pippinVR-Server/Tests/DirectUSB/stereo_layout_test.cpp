#include "StereoLayout.h"

#include <cassert>
#include <cmath>
#include <cstdio>
int main() {
    const float full = 1920.0f / 1028.0f;
    auto left = CalculateStereoLayout(5, 0, full, 1.6f, 0);
    auto right = CalculateStereoLayout(5, 1, full, 1.6f, 0);
    assert(std::abs(left.destinationWidth / left.destinationHeight * 1.6f - full / 2) < 0.00001f);
    assert(left.sourceX == 0 && right.sourceX == 0.5f && left.sourceWidth == 0.5f);
    left = CalculateStereoLayout(5, 0, full, 1.6f, 0.25f);
    right = CalculateStereoLayout(5, 1, full, 1.6f, 0.25f);
    assert(left.sourceX == 0.125f && right.sourceX == 0.5f && left.sourceWidth == 0.375f &&
           right.sourceWidth == 0.375f);
    left = CalculateStereoLayout(5, 0, full, 1.6f, -0.25f);
    right = CalculateStereoLayout(5, 1, full, 1.6f, -0.25f);
    assert(left.sourceX == 0 && right.sourceX == 0.625f);
    auto vertical = CalculateStereoLayout(3, 1, 0.9f, 1.6f, 0);
    assert(vertical.sourceY == 0.5f && vertical.sourceHeight == 0.5f);
    puts("PASS: full-width SBS aspect, both alignment directions, over-under");
}
