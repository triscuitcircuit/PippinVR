#pragma once
#include "Newt/MathTypes.h"
#include <vector>

namespace customui {
struct DecorationMesh { std::vector<Vec3> triangles, edges; };
inline bool SpongeCell(int x, int y, int z, int level) {
    for (int i = 0; i < level; ++i) {
        if ((x % 3 == 1) + (y % 3 == 1) + (z % 3 == 1) >= 2) return false;
        x /= 3; y /= 3; z /= 3;
    }
    return true;
}
inline DecorationMesh MakeSponge(int level) {
    DecorationMesh mesh;
    if (level < 0 || level > 2) return mesh;
    int n = 1;
    for (int i = 0; i < level; ++i) n *= 3;
    const int faces[6][4] = {{0,1,2,3},{5,4,7,6},{4,0,3,7},{1,5,6,2},{3,2,6,7},{4,5,1,0}};
    const int neighbors[6][3] = {{0,0,-1},{0,0,1},{-1,0,0},{1,0,0},{0,1,0},{0,-1,0}};
    for (int z = 0; z < n; ++z) for (int y = 0; y < n; ++y) for (int x = 0; x < n; ++x) {
        if (!SpongeCell(x, y, z, level)) continue;
        const float x0 = float(x)/n - .5f, x1 = float(x+1)/n - .5f;
        const float y0 = float(y)/n - .5f, y1 = float(y+1)/n - .5f;
        const float z0 = float(z)/n - .5f, z1 = float(z+1)/n - .5f;
        const Vec3 corners[8] = {{x0,y0,z0},{x1,y0,z0},{x1,y1,z0},{x0,y1,z0},
                                 {x0,y0,z1},{x1,y0,z1},{x1,y1,z1},{x0,y1,z1}};
        for (int face = 0; face < 6; ++face) {
            const int nx=x+neighbors[face][0], ny=y+neighbors[face][1], nz=z+neighbors[face][2];
            if (nx>=0 && ny>=0 && nz>=0 && nx<n && ny<n && nz<n && SpongeCell(nx,ny,nz,level)) continue;
            const auto* f = faces[face];
            mesh.triangles.insert(mesh.triangles.end(), {corners[f[0]],corners[f[1]],corners[f[2]],corners[f[0]],corners[f[2]],corners[f[3]]});
            mesh.edges.insert(mesh.edges.end(), {corners[f[0]],corners[f[1]],corners[f[1]],corners[f[2]],corners[f[2]],corners[f[3]],corners[f[3]],corners[f[0]]});
        }
    }
    return mesh;
}
}
