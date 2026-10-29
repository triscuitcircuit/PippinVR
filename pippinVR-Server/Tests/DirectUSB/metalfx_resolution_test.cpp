#include "../../Sources/NewtDashboard/MetalFXResolution.h"

#include <cassert>
#include <cstdio>
#include <limits>

int main() {
    auto result = MetalFXOutputResolution(1024, 640, 0);
    assert(result.width == 2048 && result.height == 1280);
    result = MetalFXOutputResolution(1920, 1080, 0);
    assert(result.width == 2880 && result.height == 1620);
    result = MetalFXOutputResolution(1920, 1080, 1.25f);
    assert(result.width == 2400 && result.height == 1350);
    result = MetalFXOutputResolution(1920, 1080, 2);
    assert(result.width == 3840 && result.height == 2160);
    result = MetalFXOutputResolution(1200, 1920, 2);
    assert(result.width == 1500 && result.height == 2400);
    result = MetalFXOutputResolution(3000, 1000, 2);
    assert(result.width == 3840 && result.height == 1280);
    assert(MetalFXOutputResolution(3840, 2160, 2).width == 0);
    assert(MetalFXOutputResolution(1000, 2400, 2).width == 0);
    assert(MetalFXOutputResolution(0, 0, 2).width == 0);
    assert(!ValidMetalFXScale(std::numeric_limits<float>::quiet_NaN()));
    for (float scale : {0.0f, 1.25f, 1.5f, 2.0f}) {
        for (uint32_t w = 64; w < 3840; w += 57) {
            for (uint32_t h = 64; h < 2400; h += 57) {
                const auto output = MetalFXOutputResolution(w, h, scale);
                if (!output.width)
                    continue;
                assert(output.width <= 3840 && output.height <= 2400);
                assert(output.width > w && output.height > h);
                assert(output.width % 2 == 0 && output.height % 2 == 0);

                assert(std::abs(double(output.width) / w - double(output.height) / h) <
                       2.0 / w + 2.0 / h);
            }
        }
    }
    std::puts("PASS: MetalFX presets, Auto, texture caps, aspect ratio and even dimensions");
}
