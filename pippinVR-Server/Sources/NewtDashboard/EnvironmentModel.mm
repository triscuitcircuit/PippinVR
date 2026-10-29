#include "EnvironmentModel.h"
#include "Environment.h"
#include "include/NewtLog.h"
#import <AppKit/AppKit.h>
#import <ImageIO/ImageIO.h>
#import <ModelIO/ModelIO.h>
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <fstream>
#include <map>
#include <sstream>
#include <unordered_map>

using namespace NewtModelInternal;

namespace {

std::string LowercaseExt(const std::string& path) {
    const auto dot = path.find_last_of('.');
    if (dot == std::string::npos) return "";
    std::string ext = path.substr(dot + 1);
    for (char& c : ext) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return ext;
}

PixelImage DecodeMDLTexture(MDLTexture* mdlTex, uint32_t maxDimension = 2048) {
    PixelImage result;
    if (!mdlTex) return result;
    vector_int2 dims = mdlTex.dimensions;
    if (dims.x <= 0 || dims.y <= 0) return result;
    NSData* texels = [mdlTex texelDataWithTopLeftOrigin];
    if (!texels || texels.length < static_cast<NSUInteger>(dims.x) * static_cast<NSUInteger>(dims.y) * 4) {
        texels = [mdlTex texelDataWithBottomLeftOrigin];
    }
    if (!texels || texels.length < static_cast<NSUInteger>(dims.x) * static_cast<NSUInteger>(dims.y) * 4) {
        return result;
    }
    const uint32_t srcW = static_cast<uint32_t>(dims.x);
    const uint32_t srcH = static_cast<uint32_t>(dims.y);
    uint32_t dstW = srcW;
    uint32_t dstH = srcH;
    const uint32_t longest = std::max(srcW, srcH);
    if (longest > maxDimension) {
        const float scale = static_cast<float>(maxDimension) / longest;
        dstW = std::max<uint32_t>(1, static_cast<uint32_t>(srcW * scale));
        dstH = std::max<uint32_t>(1, static_cast<uint32_t>(srcH * scale));
    }
    result.width = dstW;
    result.height = dstH;
    result.pixels.resize(static_cast<size_t>(dstW) * dstH * 4);
    const auto* src = static_cast<const uint8_t*>(texels.bytes);
    const size_t ch = std::max<size_t>(4, static_cast<size_t>(mdlTex.channelCount));
    for (uint32_t y = 0; y < dstH; ++y) {
        const uint32_t sy = std::min(srcH - 1, (y * srcH) / dstH);
        for (uint32_t x = 0; x < dstW; ++x) {
            const uint32_t sx = std::min(srcW - 1, (x * srcW) / dstW);
            const uint8_t* p = src + (static_cast<size_t>(sy) * srcW + sx) * ch;
            uint8_t* d = result.pixels.data() + (static_cast<size_t>(y) * dstW + x) * 4;
            d[0] = p[2];
            d[1] = p[1];
            d[2] = p[0];
            d[3] = 255;
        }
    }
    return result;
}

void EnsureValidNormals(std::vector<RawVertex>& tris) {
    for (size_t i = 0; i + 2 < tris.size(); i += 3) {
        const float len0 = Length(tris[i].norm);
        const float len1 = Length(tris[i + 1].norm);
        const float len2 = Length(tris[i + 2].norm);
        if (len0 < 0.01f || len1 < 0.01f || len2 < 0.01f) {
            const Vec3 e1 = tris[i + 1].pos - tris[i].pos;
            const Vec3 e2 = tris[i + 2].pos - tris[i].pos;
            Vec3 fn = Normalize(Cross(e1, e2));
            if (Length(fn) < 0.01f) fn = {0.0f, 1.0f, 0.0f};
            tris[i].norm = fn;
            tris[i + 1].norm = fn;
            tris[i + 2].norm = fn;
        }
    }
}

float ComputeShade(const Vec3& normal) {
    const Vec3 n = Normalize(normal);
    const Vec3 sunDir = Normalize(Vec3{0.45f, 0.80f, 0.40f});
    const Vec3 fillDir = Normalize(Vec3{-0.55f, 0.25f, -0.45f});
    const float ndotl = std::max(0.0f, Dot(n, sunDir));
    const float fill = std::max(0.0f, Dot(n, fillDir));
    const float hemi = 0.5f + 0.5f * n.y;
    const float shade = 0.28f + 0.18f * hemi + 0.44f * ndotl + 0.10f * fill;
    return std::clamp(shade, 0.15f, 1.0f);
}

EnvironmentModel FinalizeRawScene(RawScene& raw, const std::string& label) {
    EnvironmentModel out;
    Vec3 bmin{1e30f, 1e30f, 1e30f};
    Vec3 bmax{-1e30f, -1e30f, -1e30f};
    size_t totalVerts = 0;

    for (auto& sm : raw.submeshes) {
        EnsureValidNormals(sm.vertices);
        for (const auto& v : sm.vertices) {
            if (!std::isfinite(v.pos.x) || !std::isfinite(v.pos.y) || !std::isfinite(v.pos.z)) continue;
            bmin.x = std::min(bmin.x, v.pos.x);
            bmin.y = std::min(bmin.y, v.pos.y);
            bmin.z = std::min(bmin.z, v.pos.z);
            bmax.x = std::max(bmax.x, v.pos.x);
            bmax.y = std::max(bmax.y, v.pos.y);
            bmax.z = std::max(bmax.z, v.pos.z);
            ++totalVerts;
        }
    }
    if (totalVerts < 3) return out;

    const Vec3 extent = bmax - bmin;
    const float maxExtent = std::max({extent.x, extent.y, extent.z, 0.0001f});
    const Vec3 centerOffset{
        0.5f * (bmin.x + bmax.x),
        bmin.y,
        0.5f * (bmin.z + bmax.z)
    };

    float autoScale = 1.0f;
    if (maxExtent < 0.20f) {
        autoScale = 1.6f / maxExtent;
    } else if (maxExtent > 60.0f) {
        autoScale = 12.0f / maxExtent;
    }
    out.defaultScale = 1.0f;
    out.localCenter = {0.0f, 0.5f * extent.y * autoScale, 0.0f};
    out.halfExtents = {
        std::max(0.15f, 0.5f * extent.x * autoScale),
        std::max(0.15f, 0.5f * extent.y * autoScale),
        std::max(0.15f, 0.5f * extent.z * autoScale)
    };

    constexpr uint32_t kShadeSteps = 64;
    constexpr uint32_t kMaxPaletteColors = 256;
    std::vector<uint32_t> paletteRGB;
    std::unordered_map<uint32_t, uint32_t> colorToRow;

    auto getColorRow = [&](const float rgb[3]) -> uint32_t {
        const uint8_t r = static_cast<uint8_t>(std::clamp(rgb[0], 0.0f, 1.0f) * 255.0f + 0.5f);
        const uint8_t g = static_cast<uint8_t>(std::clamp(rgb[1], 0.0f, 1.0f) * 255.0f + 0.5f);
        const uint8_t b = static_cast<uint8_t>(std::clamp(rgb[2], 0.0f, 1.0f) * 255.0f + 0.5f);
        const uint32_t key = (static_cast<uint32_t>(r & 0xFC) << 16) |
                             (static_cast<uint32_t>(g & 0xFC) << 8) |
                             static_cast<uint32_t>(b & 0xFC);
        auto it = colorToRow.find(key);
        if (it != colorToRow.end()) return it->second;
        if (paletteRGB.size() >= kMaxPaletteColors) return static_cast<uint32_t>(paletteRGB.size() - 1);
        const uint32_t row = static_cast<uint32_t>(paletteRGB.size());
        const uint32_t exact = (static_cast<uint32_t>(r) << 16) | (static_cast<uint32_t>(g) << 8) | b;
        paletteRGB.push_back(exact);
        colorToRow[key] = row;
        return row;
    };

    std::vector<VertexPC> untexturedVerts;
    std::map<int, std::vector<VertexPC>> texturedVerts;

    for (const auto& sm : raw.submeshes) {
        const bool hasTex = (sm.textureIndex >= 0 &&
                             static_cast<size_t>(sm.textureIndex) < raw.textures.size() &&
                             raw.textures[sm.textureIndex].width > 0);
        if (!hasTex) {
            for (const auto& rv : sm.vertices) {
                const uint32_t row = getColorRow(rv.color);
                const float shade = ComputeShade(rv.norm);
                const float u = std::clamp((shade - 0.15f) / 0.85f, 0.02f, 0.98f);
                const Vec3 p = (rv.pos - centerOffset) * autoScale;
                untexturedVerts.push_back(VertexPC{{p.x, p.y, p.z}, {u, static_cast<float>(row)}});
            }
        } else {
            auto& bucket = texturedVerts[sm.textureIndex];
            for (const auto& rv : sm.vertices) {
                const Vec3 p = (rv.pos - centerOffset) * autoScale;
                float u = rv.u - std::floor(rv.u);
                float v = rv.v - std::floor(rv.v);
                bucket.push_back(VertexPC{{p.x, p.y, p.z}, {u, v}});
            }
        }
    }

    if (!untexturedVerts.empty()) {
        if (paletteRGB.empty()) paletteRGB.push_back(0xD2D6DC);
        const uint32_t rows = std::max<uint32_t>(4, static_cast<uint32_t>(paletteRGB.size()));
        EnvironmentModelPart part;
        part.texture.width = kShadeSteps;
        part.texture.height = rows;
        part.texture.pixels.resize(static_cast<size_t>(kShadeSteps) * rows * 4, 255);
        for (uint32_t r = 0; r < rows; ++r) {
            const uint32_t rgb = paletteRGB[std::min<size_t>(r, paletteRGB.size() - 1)];
            const float cr = static_cast<float>((rgb >> 16) & 0xFF);
            const float cg = static_cast<float>((rgb >> 8) & 0xFF);
            const float cb = static_cast<float>(rgb & 0xFF);
            for (uint32_t c = 0; c < kShadeSteps; ++c) {
                const float shade = 0.15f + 0.85f * (static_cast<float>(c) / (kShadeSteps - 1));
                uint8_t* px = part.texture.pixels.data() + (static_cast<size_t>(r) * kShadeSteps + c) * 4;
                px[0] = static_cast<uint8_t>(std::clamp(cb * shade, 0.0f, 255.0f));
                px[1] = static_cast<uint8_t>(std::clamp(cg * shade, 0.0f, 255.0f));
                px[2] = static_cast<uint8_t>(std::clamp(cr * shade, 0.0f, 255.0f));
                px[3] = 255;
            }
        }
        for (auto& vp : untexturedVerts) {
            vp.uv[1] = (vp.uv[1] + 0.5f) / static_cast<float>(rows);
        }
        part.vertices = std::move(untexturedVerts);
        out.parts.push_back(std::move(part));
    }

    for (auto& kv : texturedVerts) {
        if (kv.second.empty()) continue;
        EnvironmentModelPart part;
        part.vertices = std::move(kv.second);
        part.texture = std::move(raw.textures[kv.first]);
        out.parts.push_back(std::move(part));
    }

    out.loaded = !out.parts.empty();
    out.summary = label + " (" + std::to_string(totalVerts / 3) + " tris)";
    Newt_Logf(NEWT_LOG_INFO, "Loaded 3D environment model: %s (%zu parts, %zu triangles)",
              label.c_str(), out.parts.size(), totalVerts / 3);
    return out;
}





void ExtractMaterialInfo(MDLMaterial* material,
                         const std::string& baseDir,
                         RawScene& scene,
                         std::unordered_map<std::string, int>& texCache,
                         int& outTexIndex,
                         float outColor[3]) {
    outTexIndex = -1;
    outColor[0] = 0.82f;
    outColor[1] = 0.84f;
    outColor[2] = 0.86f;
    if (!material) return;

    MDLMaterialProperty* prop = [material propertyWithSemantic:MDLMaterialSemanticBaseColor];
    if (!prop) return;

    if (prop.type == MDLMaterialPropertyTypeTexture && prop.textureSamplerValue && prop.textureSamplerValue.texture) {
        if (scene.textures.size() < kMaxModelTextures) {
            MDLTexture* mdlTex = prop.textureSamplerValue.texture;
            std::string cacheKey = mdlTex.name.length > 0
                ? std::string(mdlTex.name.UTF8String)
                : std::to_string(reinterpret_cast<uintptr_t>((__bridge void*)mdlTex));
            auto it = texCache.find(cacheKey);
            if (it != texCache.end()) {
                outTexIndex = it->second;
                return;
            }
            PixelImage img = DecodeMDLTexture(mdlTex);
            if (img.width == 0 && [mdlTex isKindOfClass:[MDLURLTexture class]]) {
                NSURL* u = ((MDLURLTexture*)mdlTex).URL;
                if (u && u.isFileURL) img = LoadImageFile(u.path.UTF8String, 2048);
            }
            if (img.width > 0 && img.height > 0) {
                outTexIndex = static_cast<int>(scene.textures.size());
                scene.textures.push_back(std::move(img));
                texCache[cacheKey] = outTexIndex;
                return;
            }
        }
    } else if ((prop.type == MDLMaterialPropertyTypeURL || prop.type == MDLMaterialPropertyTypeString) &&
               scene.textures.size() < kMaxModelTextures) {
        NSString* strPath = prop.URLValue ? prop.URLValue.path : prop.stringValue;
        if (strPath && strPath.length > 0) {
            std::string resolved = strPath.UTF8String;
            if (resolved[0] != '/' && !baseDir.empty()) {
                resolved = baseDir + "/" + resolved;
            }
            auto it = texCache.find(resolved);
            if (it != texCache.end()) {
                outTexIndex = it->second;
                return;
            }
            PixelImage img = LoadImageFile(resolved, 2048);
            if (img.width > 0 && img.height > 0) {
                outTexIndex = static_cast<int>(scene.textures.size());
                scene.textures.push_back(std::move(img));
                texCache[resolved] = outTexIndex;
                return;
            }
        }
    }

    if (prop.type == MDLMaterialPropertyTypeFloat3) {
        vector_float3 c = prop.float3Value;
        outColor[0] = c.x; outColor[1] = c.y; outColor[2] = c.z;
    } else if (prop.type == MDLMaterialPropertyTypeFloat4) {
        vector_float4 c = prop.float4Value;
        outColor[0] = c.x; outColor[1] = c.y; outColor[2] = c.z;
    } else if (prop.type == MDLMaterialPropertyTypeColor && prop.color) {
        const size_t n = CGColorGetNumberOfComponents(prop.color);
        const CGFloat* comp = CGColorGetComponents(prop.color);
        if (comp && n >= 3) {
            outColor[0] = static_cast<float>(comp[0]);
            outColor[1] = static_cast<float>(comp[1]);
            outColor[2] = static_cast<float>(comp[2]);
        }
    }
}

void TraverseMDLObject(MDLObject* obj,
                       simd_float4x4 parentTransform,
                       const std::string& baseDir,
                       RawScene& scene,
                       std::unordered_map<std::string, int>& texCache) {
    if (!obj || obj.hidden) return;
    simd_float4x4 worldTransform = parentTransform;
    if (obj.transform) {
        worldTransform = simd_mul(parentTransform, obj.transform.matrix);
    }

    if ([obj isKindOfClass:[MDLMesh class]]) {
        MDLMesh* srcMesh = (MDLMesh*)obj;
        MDLVertexDescriptor* desc = [[MDLVertexDescriptor alloc] init];
        desc.attributes[0] = [[MDLVertexAttribute alloc] initWithName:MDLVertexAttributePosition
                                                               format:MDLVertexFormatFloat3
                                                               offset:0
                                                          bufferIndex:0];
        desc.attributes[1] = [[MDLVertexAttribute alloc] initWithName:MDLVertexAttributeNormal
                                                               format:MDLVertexFormatFloat3
                                                               offset:12
                                                          bufferIndex:0];
        desc.attributes[2] = [[MDLVertexAttribute alloc] initWithName:MDLVertexAttributeTextureCoordinate
                                                               format:MDLVertexFormatFloat2
                                                               offset:24
                                                          bufferIndex:0];
        desc.layouts[0] = [[MDLVertexBufferLayout alloc] initWithStride:32];

        if (![srcMesh vertexAttributeDataForAttributeNamed:MDLVertexAttributeNormal]) {
            @try {
                [srcMesh addNormalsWithAttributeNamed:MDLVertexAttributeNormal creaseThreshold:0.0f];
            } @catch (NSException*) {}
        }
        srcMesh.vertexDescriptor = desc;

        id<MDLMeshBuffer> vbuf = srcMesh.vertexBuffers.firstObject;
        MDLMeshBufferMap* vmap = vbuf ? [vbuf map] : nil;
        const uint8_t* vbytes = vmap ? static_cast<const uint8_t*>(vmap.bytes) : nullptr;
        const NSUInteger vcount = srcMesh.vertexCount;

        if (vbytes && vcount > 0) {
            for (MDLSubmesh* submesh in srcMesh.submeshes) {
                MDLSubmesh* triSub = submesh;
                if (submesh.geometryType != MDLGeometryTypeTriangles) {
                    @try {
                        triSub = [[MDLSubmesh alloc] initWithMDLSubmesh:submesh
                                                              indexType:MDLIndexBitDepthUInt32
                                                           geometryType:MDLGeometryTypeTriangles];
                    } @catch (NSException*) {
                        triSub = nil;
                    }
                }
                if (!triSub || !triSub.indexBuffer || triSub.indexCount < 3) continue;
                MDLMeshBufferMap* imap = [triSub.indexBuffer map];
                if (!imap || !imap.bytes) continue;

                int texIdx = -1;
                float baseColor[3]{0.82f, 0.84f, 0.86f};
                ExtractMaterialInfo(triSub.material ?: submesh.material, baseDir, scene, texCache, texIdx, baseColor);

                RawSubmesh rawSm;
                rawSm.textureIndex = texIdx;
                rawSm.vertices.reserve(triSub.indexCount);

                const uint8_t* ibytes = static_cast<const uint8_t*>(imap.bytes);
                const MDLIndexBitDepth depth = triSub.indexType;

                auto readIndex = [&](NSUInteger k) -> uint32_t {
                    if (depth == MDLIndexBitDepthUInt8) return ibytes[k];
                    if (depth == MDLIndexBitDepthUInt16) return reinterpret_cast<const uint16_t*>(ibytes)[k];
                    return reinterpret_cast<const uint32_t*>(ibytes)[k];
                };

                for (NSUInteger k = 0; k + 2 < triSub.indexCount; k += 3) {
                    for (NSUInteger c = 0; c < 3; ++c) {
                        const uint32_t idx = readIndex(k + c);
                        if (idx >= vcount) continue;
                        const float* fp = reinterpret_cast<const float*>(vbytes + static_cast<size_t>(idx) * 32);
                        RawVertex rv;
                        rv.pos = TransformPoint(worldTransform, {fp[0], fp[1], fp[2]});
                        rv.norm = TransformDirection(worldTransform, {fp[3], fp[4], fp[5]});
                        rv.u = fp[6];
                        rv.v = 1.0f - fp[7];
                        rv.color[0] = baseColor[0];
                        rv.color[1] = baseColor[1];
                        rv.color[2] = baseColor[2];
                        rawSm.vertices.push_back(rv);
                    }
                }
                if (rawSm.vertices.size() >= 3) {
                    scene.submeshes.push_back(std::move(rawSm));
                }
            }
        }
    }

    for (MDLObject* child in obj.children.objects) {
        TraverseMDLObject(child, worldTransform, baseDir, scene, texCache);
    }
}

bool LoadViaModelIO(const std::string& path, RawScene& scene) {
    @autoreleasepool {
        NSString* nsPath = [NSString stringWithUTF8String:path.c_str()];
        NSURL* url = [NSURL fileURLWithPath:nsPath];
        if (!url) return false;
        @try {
            MDLAsset* asset = [[MDLAsset alloc] initWithURL:url];
            if (!asset || asset.count == 0) return false;
            [asset loadTextures];
            std::string baseDir;
            const auto slash = path.find_last_of('/');
            if (slash != std::string::npos) baseDir = path.substr(0, slash);

            std::unordered_map<std::string, int> texCache;
            for (NSUInteger i = 0; i < asset.count; ++i) {
                MDLObject* obj = [asset objectAtIndex:i];
                TraverseMDLObject(obj, matrix_identity_float4x4, baseDir, scene, texCache);
            }
        } @catch (NSException* ex) {
            Newt_Logf(NEWT_LOG_WARNING, "ModelIO exception loading %s: %s",
                      path.c_str(), ex.reason.UTF8String);
            return false;
        }
    }
    return !scene.submeshes.empty();
}





struct ObjMaterial {
    float kd[3]{0.82f, 0.84f, 0.86f};
    int texIndex = -1;
};

void ParseMtlFile(const std::string& mtlPath,
                  const std::string& baseDir,
                  std::unordered_map<std::string, ObjMaterial>& materials,
                  RawScene& scene,
                  std::unordered_map<std::string, int>& texCache) {
    std::ifstream in(mtlPath);
    if (!in.is_open()) return;
    std::string line;
    std::string current;
    while (std::getline(in, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        std::istringstream ss(line);
        std::string tok;
        if (!(ss >> tok)) continue;
        if (tok == "newmtl") {
            ss >> current;
            materials[current] = ObjMaterial{};
        } else if (tok == "Kd" && !current.empty()) {
            ss >> materials[current].kd[0] >> materials[current].kd[1] >> materials[current].kd[2];
        } else if (tok == "map_Kd" && !current.empty() && scene.textures.size() < kMaxModelTextures) {
            std::string texFile;
            std::getline(ss >> std::ws, texFile);
            if (!texFile.empty()) {
                std::string fullPath = (texFile[0] == '/' || baseDir.empty()) ? texFile : (baseDir + "/" + texFile);
                auto it = texCache.find(fullPath);
                if (it != texCache.end()) {
                    materials[current].texIndex = it->second;
                } else {
                    PixelImage img = LoadImageFile(fullPath, 2048);
                    if (img.width > 0 && img.height > 0) {
                        const int idx = static_cast<int>(scene.textures.size());
                        scene.textures.push_back(std::move(img));
                        texCache[fullPath] = idx;
                        materials[current].texIndex = idx;
                    }
                }
            }
        }
    }
}

bool LoadObjDirect(const std::string& path, RawScene& scene) {
    std::ifstream in(path);
    if (!in.is_open()) return false;

    std::string baseDir;
    const auto slash = path.find_last_of('/');
    if (slash != std::string::npos) baseDir = path.substr(0, slash);

    std::vector<Vec3> positions;
    std::vector<Vec3> normals;
    std::vector<std::pair<float, float>> uvs;
    std::unordered_map<std::string, ObjMaterial> materials;
    std::unordered_map<std::string, int> texCache;
    std::string activeMtl;

    std::unordered_map<std::string, RawSubmesh> groups;
    groups["default"] = RawSubmesh{};

    std::string line;
    while (std::getline(in, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        if (line.empty() || line[0] == '#') continue;
        std::istringstream ss(line);
        std::string tok;
        if (!(ss >> tok)) continue;
        if (tok == "v") {
            Vec3 p{0, 0, 0};
            ss >> p.x >> p.y >> p.z;
            positions.push_back(p);
        } else if (tok == "vn") {
            Vec3 n{0, 1, 0};
            ss >> n.x >> n.y >> n.z;
            normals.push_back(n);
        } else if (tok == "vt") {
            float u = 0, v = 0;
            ss >> u >> v;
            uvs.push_back({u, 1.0f - v});
        } else if (tok == "mtllib") {
            std::string mtlFile;
            std::getline(ss >> std::ws, mtlFile);
            if (!mtlFile.empty()) {
                std::string full = (mtlFile[0] == '/' || baseDir.empty()) ? mtlFile : (baseDir + "/" + mtlFile);
                ParseMtlFile(full, baseDir, materials, scene, texCache);
            }
        } else if (tok == "usemtl") {
            ss >> activeMtl;
            if (groups.find(activeMtl) == groups.end()) {
                RawSubmesh sm;
                auto it = materials.find(activeMtl);
                if (it != materials.end()) sm.textureIndex = it->second.texIndex;
                groups[activeMtl] = std::move(sm);
            }
        } else if (tok == "f") {
            std::vector<RawVertex> poly;
            std::string vertSpec;
            ObjMaterial mat;
            auto mit = materials.find(activeMtl);
            if (mit != materials.end()) mat = mit->second;

            while (ss >> vertSpec) {
                int vi = 0, ti = 0, ni = 0;
                const auto s1 = vertSpec.find('/');
                if (s1 == std::string::npos) {
                    vi = std::stoi(vertSpec);
                } else {
                    vi = std::stoi(vertSpec.substr(0, s1));
                    const auto s2 = vertSpec.find('/', s1 + 1);
                    if (s2 == std::string::npos) {
                        if (s1 + 1 < vertSpec.size()) ti = std::stoi(vertSpec.substr(s1 + 1));
                    } else {
                        if (s2 > s1 + 1) ti = std::stoi(vertSpec.substr(s1 + 1, s2 - s1 - 1));
                        if (s2 + 1 < vertSpec.size()) ni = std::stoi(vertSpec.substr(s2 + 1));
                    }
                }
                auto resolveIdx = [](int idx, size_t count) -> int {
                    if (idx > 0) return idx - 1;
                    if (idx < 0) return static_cast<int>(count) + idx;
                    return -1;
                };
                const int pIdx = resolveIdx(vi, positions.size());
                if (pIdx < 0 || static_cast<size_t>(pIdx) >= positions.size()) continue;
                RawVertex rv;
                rv.pos = positions[pIdx];
                const int tIdx = resolveIdx(ti, uvs.size());
                if (tIdx >= 0 && static_cast<size_t>(tIdx) < uvs.size()) {
                    rv.u = uvs[tIdx].first;
                    rv.v = uvs[tIdx].second;
                }
                const int nIdx = resolveIdx(ni, normals.size());
                if (nIdx >= 0 && static_cast<size_t>(nIdx) < normals.size()) {
                    rv.norm = normals[nIdx];
                } else {
                    rv.norm = {0, 0, 0};
                }
                rv.color[0] = mat.kd[0];
                rv.color[1] = mat.kd[1];
                rv.color[2] = mat.kd[2];
                poly.push_back(rv);
            }
            if (poly.size() >= 3) {
                auto& dst = groups[activeMtl.empty() ? "default" : activeMtl];
                dst.textureIndex = mat.texIndex;
                for (size_t i = 1; i + 1 < poly.size(); ++i) {
                    dst.vertices.push_back(poly[0]);
                    dst.vertices.push_back(poly[i]);
                    dst.vertices.push_back(poly[i + 1]);
                }
            }
        }
    }

    for (auto& kv : groups) {
        if (kv.second.vertices.size() >= 3) {
            scene.submeshes.push_back(std::move(kv.second));
        }
    }
    return !scene.submeshes.empty();
}

}

bool IsModelFilePath(const std::string& path) {
    const std::string ext = LowercaseExt(path);
    return ext == "usdz" || ext == "usd" || ext == "usda" || ext == "usdc" ||
           ext == "obj" || ext == "gltf" || ext == "glb";
}

EnvironmentModel LoadModelFile(const std::string& path) {
    RawScene raw;
    const std::string ext = LowercaseExt(path);
    std::string filename = path;
    const auto slash = path.find_last_of('/');
    if (slash != std::string::npos) filename = path.substr(slash + 1);

    bool ok = false;
    if (ext == "gltf" || ext == "glb") {
        ok = LoadGltfOrGlbModel(path, raw);
        if (!ok) ok = LoadViaModelIO(path, raw);
    } else if (ext == "obj") {
        ok = LoadObjDirect(path, raw);
        if (!ok) ok = LoadViaModelIO(path, raw);
    } else {
        ok = LoadViaModelIO(path, raw);
    }
    if (!ok) {
        EnvironmentModel empty;
        return empty;
    }
    return FinalizeRawScene(raw, filename);
}
