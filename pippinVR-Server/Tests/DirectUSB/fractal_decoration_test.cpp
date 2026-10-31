#include "FractalDecoration.h"

#include <cassert>
#include <cstdio>
int main() {
    using namespace customui;
    int occupied1 = 0, occupied2 = 0;
    for (int z = 0; z < 3; ++z)
        for (int y = 0; y < 3; ++y)
            for (int x = 0; x < 3; ++x)
                occupied1 += SpongeCell(x, y, z, 1);
    for (int z = 0; z < 9; ++z)
        for (int y = 0; y < 9; ++y)
            for (int x = 0; x < 9; ++x)
                occupied2 += SpongeCell(x, y, z, 2);
    assert(occupied1 == 20 && occupied2 == 400);
    assert(!SpongeCell(1, 1, 1, 1) && !SpongeCell(1, 1, 0, 1) && SpongeCell(0, 0, 0, 1));
    auto cube = MakeSponge(0), cut = MakeSponge(1), fractal = MakeSponge(2);
    assert(cube.triangles.size() == 36 && cube.edges.size() == 48);
    assert(cut.triangles.size() > cube.triangles.size() &&
           fractal.triangles.size() > cut.triangles.size());
    assert(cut.triangles.size() % 6 == 0 && fractal.triangles.size() % 6 == 0);
    assert(MakeSponge(3).triangles.empty());
    std::printf("PASS: cube, carved cube, and 2-level fractal (%zu triangles)\n",
                fractal.triangles.size() / 3);
}
