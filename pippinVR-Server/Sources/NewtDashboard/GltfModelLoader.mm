#include "EnvironmentModel.h"
#include "Environment.h"
#import <AppKit/AppKit.h>
#import <ImageIO/ImageIO.h>
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <functional>
#include <unordered_map>

namespace NewtModelInternal {

namespace {

PixelImage DecodeImageFromNSData(NSData* data, uint32_t maxDimension = 2048) {
    PixelImage result;
    if (!data || data.length == 0) return result;
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, nullptr);
    if (!source) return result;
    CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, nullptr);
    CFRelease(source);
    if (!image) return result;

    uint32_t width = static_cast<uint32_t>(CGImageGetWidth(image));
    uint32_t height = static_cast<uint32_t>(CGImageGetHeight(image));
    if (width == 0 || height == 0) { CGImageRelease(image); return result; }
    const uint32_t longest = std::max(width, height);
    if (longest > maxDimension) {
        const float scale = static_cast<float>(maxDimension) / longest;
        width = std::max<uint32_t>(1, static_cast<uint32_t>(width * scale));
        height = std::max<uint32_t>(1, static_cast<uint32_t>(height * scale));
    }

    result.width = width;
    result.height = height;
    result.pixels.assign(static_cast<size_t>(width) * height * 4, 0);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(
        result.pixels.data(), width, height, 8, width * 4, cs,
        kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGContextTranslateCTM(ctx, 0.0, height);
    CGContextScaleCTM(ctx, 1.0, -1.0);
    CGContextDrawImage(ctx, CGRectMake(0, 0, width, height), image);
    CGContextRelease(ctx);
    CGColorSpaceRelease(cs);
    CGImageRelease(image);
    return result;
}

NSData* DecodeDataURI(NSString* uri) {
    NSRange comma = [uri rangeOfString:@","];
    if (comma.location == NSNotFound) return nil;
    NSString* b64 = [uri substringFromIndex:comma.location + 1];
    return [[NSData alloc] initWithBase64EncodedString:b64
                                               options:NSDataBase64DecodingIgnoreUnknownCharacters];
}

size_t ComponentByteSize(int componentType) {
    switch (componentType) {
    case 5120: case 5121: return 1;
    case 5122: case 5123: return 2;
    case 5125: case 5126: return 4;
    default: return 0;
    }
}

size_t TypeComponentCount(NSString* type) {
    if ([type isEqualToString:@"SCALAR"]) return 1;
    if ([type isEqualToString:@"VEC2"]) return 2;
    if ([type isEqualToString:@"VEC3"]) return 3;
    if ([type isEqualToString:@"VEC4"] || [type isEqualToString:@"MAT2"]) return 4;
    if ([type isEqualToString:@"MAT3"]) return 9;
    if ([type isEqualToString:@"MAT4"]) return 16;
    return 0;
}

float ReadGltfComponentAsFloat(const uint8_t* ptr, int componentType, bool normalized) {
    switch (componentType) {
    case 5126: {
        float v = 0;
        std::memcpy(&v, ptr, sizeof(float));
        return v;
    }
    case 5121: {
        const uint8_t v = *ptr;
        return normalized ? (v / 255.0f) : static_cast<float>(v);
    }
    case 5120: {
        const int8_t v = *reinterpret_cast<const int8_t*>(ptr);
        return normalized ? std::max(-1.0f, v / 127.0f) : static_cast<float>(v);
    }
    case 5123: {
        uint16_t v = 0;
        std::memcpy(&v, ptr, sizeof(uint16_t));
        return normalized ? (v / 65535.0f) : static_cast<float>(v);
    }
    case 5122: {
        int16_t v = 0;
        std::memcpy(&v, ptr, sizeof(int16_t));
        return normalized ? std::max(-1.0f, v / 32767.0f) : static_cast<float>(v);
    }
    case 5125: {
        uint32_t v = 0;
        std::memcpy(&v, ptr, sizeof(uint32_t));
        return static_cast<float>(v);
    }
    default:
        return 0.0f;
    }
}

uint32_t ReadGltfIndex(const uint8_t* ptr, int componentType) {
    switch (componentType) {
    case 5121: return *ptr;
    case 5123: { uint16_t v = 0; std::memcpy(&v, ptr, 2); return v; }
    case 5125: { uint32_t v = 0; std::memcpy(&v, ptr, 4); return v; }
    default: return 0;
    }
}

struct GltfAccessorView {
    const uint8_t* data = nullptr;
    size_t stride = 0;
    size_t count = 0;
    int componentType = 0;
    size_t numComponents = 0;
    bool normalized = false;
};

bool ResolveGltfAccessor(NSArray* accessors,
                         NSArray* bufferViews,
                         const std::vector<NSData*>& buffers,
                         NSNumber* accessorIdx,
                         GltfAccessorView& out) {
    if (!accessorIdx || accessorIdx.unsignedIntegerValue >= accessors.count) return false;
    NSDictionary* acc = accessors[accessorIdx.unsignedIntegerValue];
    NSNumber* bvIdx = acc[@"bufferView"];
    if (!bvIdx || bvIdx.unsignedIntegerValue >= bufferViews.count) return false;
    NSDictionary* bv = bufferViews[bvIdx.unsignedIntegerValue];
    NSNumber* bufIdx = bv[@"buffer"];
    if (!bufIdx || bufIdx.unsignedIntegerValue >= buffers.size()) return false;
    NSData* buf = buffers[bufIdx.unsignedIntegerValue];
    if (!buf) return false;

    const int compType = [acc[@"componentType"] intValue];
    const size_t compSize = ComponentByteSize(compType);
    const size_t numComp = TypeComponentCount(acc[@"type"]);
    if (compSize == 0 || numComp == 0) return false;

    const size_t accOffset = [acc[@"byteOffset"] unsignedLongValue];
    const size_t bvOffset = [bv[@"byteOffset"] unsignedLongValue];
    const size_t bvStride = [bv[@"byteStride"] unsignedLongValue];
    const size_t elemSize = compSize * numComp;
    const size_t stride = bvStride > 0 ? bvStride : elemSize;
    const size_t count = [acc[@"count"] unsignedLongValue];
    const size_t start = bvOffset + accOffset;
    if (count == 0 || start + (count - 1) * stride + elemSize > buf.length) return false;

    out.data = static_cast<const uint8_t*>(buf.bytes) + start;
    out.stride = stride;
    out.count = count;
    out.componentType = compType;
    out.numComponents = numComp;
    out.normalized = [acc[@"normalized"] boolValue];
    return true;
}

simd_float4x4 ParseGltfNodeMatrix(NSDictionary* node) {
    NSArray* mat = node[@"matrix"];
    if (mat && mat.count == 16) {
        simd_float4x4 m;
        for (int col = 0; col < 4; ++col) {
            for (int row = 0; row < 4; ++row) {
                m.columns[col][row] = [mat[col * 4 + row] floatValue];
            }
        }
        return m;
    }
    simd_float3 t = simd_make_float3(0, 0, 0);
    NSArray* tr = node[@"translation"];
    if (tr && tr.count == 3) {
        t = simd_make_float3([tr[0] floatValue], [tr[1] floatValue], [tr[2] floatValue]);
    }
    simd_quatf q = simd_quaternion(0.0f, 0.0f, 0.0f, 1.0f);
    NSArray* rot = node[@"rotation"];
    if (rot && rot.count == 4) {
        q = simd_quaternion([rot[0] floatValue], [rot[1] floatValue], [rot[2] floatValue], [rot[3] floatValue]);
    }
    simd_float3 s = simd_make_float3(1, 1, 1);
    NSArray* sc = node[@"scale"];
    if (sc && sc.count == 3) {
        s = simd_make_float3([sc[0] floatValue], [sc[1] floatValue], [sc[2] floatValue]);
    }
    simd_float4x4 rotMat = simd_matrix4x4(q);
    rotMat.columns[0] *= s.x;
    rotMat.columns[1] *= s.y;
    rotMat.columns[2] *= s.z;
    rotMat.columns[3] = simd_make_float4(t.x, t.y, t.z, 1.0f);
    return rotMat;
}

}

bool LoadGltfOrGlbModel(const std::string& path, RawScene& scene) {
    @autoreleasepool {
        NSString* nsPath = [NSString stringWithUTF8String:path.c_str()];
        NSData* fileData = [NSData dataWithContentsOfFile:nsPath];
        if (!fileData || fileData.length < 4) return false;

        std::string baseDir;
        const auto slash = path.find_last_of('/');
        if (slash != std::string::npos) baseDir = path.substr(0, slash);

        NSData* jsonData = nil;
        NSData* glbBinChunk = nil;

        const uint32_t* header = static_cast<const uint32_t*>(fileData.bytes);
        if (fileData.length >= 12 && header[0] == 0x46546C67) {
            size_t offset = 12;
            const uint8_t* bytes = static_cast<const uint8_t*>(fileData.bytes);
            while (offset + 8 <= fileData.length) {
                uint32_t chunkLen = 0, chunkType = 0;
                std::memcpy(&chunkLen, bytes + offset, 4);
                std::memcpy(&chunkType, bytes + offset + 4, 4);
                offset += 8;
                if (offset + chunkLen > fileData.length) break;
                NSData* sub = [fileData subdataWithRange:NSMakeRange(offset, chunkLen)];
                if (chunkType == 0x4E4F534A && !jsonData) {
                    jsonData = sub;
                } else if (chunkType == 0x004E4942 && !glbBinChunk) {
                    glbBinChunk = sub;
                }
                offset += chunkLen;
            }
        } else {
            jsonData = fileData;
        }
        if (!jsonData) return false;

        NSError* err = nil;
        NSDictionary* root = [NSJSONSerialization JSONObjectWithData:jsonData options:0 error:&err];
        if (![root isKindOfClass:[NSDictionary class]]) return false;

        NSArray* jsonBuffers = root[@"buffers"];
        std::vector<NSData*> buffers;
        for (NSUInteger i = 0; i < jsonBuffers.count; ++i) {
            NSDictionary* bdict = jsonBuffers[i];
            NSString* uri = bdict[@"uri"];
            if (!uri) {
                buffers.push_back(i == 0 ? glbBinChunk : nil);
            } else if ([uri hasPrefix:@"data:"]) {
                buffers.push_back(DecodeDataURI(uri));
            } else {
                NSString* decodedUri = [uri stringByRemovingPercentEncoding] ?: uri;
                std::string bpath = baseDir.empty() ? decodedUri.UTF8String : (baseDir + "/" + decodedUri.UTF8String);
                buffers.push_back([NSData dataWithContentsOfFile:[NSString stringWithUTF8String:bpath.c_str()]]);
            }
        }

        NSArray* accessors = root[@"accessors"];
        NSArray* bufferViews = root[@"bufferViews"];
        NSArray* materials = root[@"materials"];
        NSArray* textures = root[@"textures"];
        NSArray* images = root[@"images"];
        NSArray* meshes = root[@"meshes"];
        NSArray* nodes = root[@"nodes"];
        if (!meshes || meshes.count == 0) return false;

        std::unordered_map<int, int> gltfImageToSceneTex;
        auto loadGltfTexture = [&](int texIdx) -> int {
            if (texIdx < 0 || !textures || static_cast<NSUInteger>(texIdx) >= textures.count) return -1;
            NSDictionary* tdict = textures[texIdx];
            NSNumber* srcNum = tdict[@"source"];
            if (!srcNum || !images || srcNum.unsignedIntegerValue >= images.count) return -1;
            const int imgIdx = srcNum.intValue;
            auto it = gltfImageToSceneTex.find(imgIdx);
            if (it != gltfImageToSceneTex.end()) return it->second;
            if (scene.textures.size() >= kMaxModelTextures) return -1;

            NSDictionary* idict = images[imgIdx];
            PixelImage decoded;
            NSString* uri = idict[@"uri"];
            if (uri) {
                if ([uri hasPrefix:@"data:"]) {
                    decoded = DecodeImageFromNSData(DecodeDataURI(uri));
                } else {
                    NSString* decUri = [uri stringByRemovingPercentEncoding] ?: uri;
                    std::string ipath = baseDir.empty() ? decUri.UTF8String : (baseDir + "/" + decUri.UTF8String);
                    decoded = LoadImageFile(ipath, 2048);
                }
            } else if (idict[@"bufferView"]) {
                const NSUInteger bvIdx = [idict[@"bufferView"] unsignedIntegerValue];
                if (bufferViews && bvIdx < bufferViews.count) {
                    NSDictionary* bv = bufferViews[bvIdx];
                    const NSUInteger bufIdx = [bv[@"buffer"] unsignedIntegerValue];
                    const NSUInteger offset = [bv[@"byteOffset"] unsignedLongValue];
                    const NSUInteger length = [bv[@"byteLength"] unsignedLongValue];
                    if (bufIdx < buffers.size() && buffers[bufIdx] && offset + length <= buffers[bufIdx].length) {
                        NSData* sub = [buffers[bufIdx] subdataWithRange:NSMakeRange(offset, length)];
                        decoded = DecodeImageFromNSData(sub);
                    }
                }
            }
            if (decoded.width > 0 && decoded.height > 0) {
                const int sceneIdx = static_cast<int>(scene.textures.size());
                scene.textures.push_back(std::move(decoded));
                gltfImageToSceneTex[imgIdx] = sceneIdx;
                return sceneIdx;
            }
            return -1;
        };

        auto emitMesh = [&](NSUInteger meshIdx, const simd_float4x4& worldMat) {
            if (meshIdx >= meshes.count) return;
            NSDictionary* mdict = meshes[meshIdx];
            NSArray* prims = mdict[@"primitives"];
            for (NSDictionary* prim in prims) {
                const int mode = prim[@"mode"] ? [prim[@"mode"] intValue] : 4;
                if (mode != 4) continue;
                NSDictionary* attrs = prim[@"attributes"];
                if (!attrs) continue;

                GltfAccessorView posAcc{}, normAcc{}, uvAcc{}, colAcc{}, idxAcc{};
                if (!ResolveGltfAccessor(accessors, bufferViews, buffers, attrs[@"POSITION"], posAcc) ||
                    posAcc.numComponents < 3) {
                    continue;
                }
                const bool hasNorm = ResolveGltfAccessor(accessors, bufferViews, buffers, attrs[@"NORMAL"], normAcc) &&
                                     normAcc.numComponents >= 3;
                const bool hasUV = ResolveGltfAccessor(accessors, bufferViews, buffers, attrs[@"TEXCOORD_0"], uvAcc) &&
                                   uvAcc.numComponents >= 2;
                const bool hasCol = ResolveGltfAccessor(accessors, bufferViews, buffers, attrs[@"COLOR_0"], colAcc) &&
                                    colAcc.numComponents >= 3;
                const bool hasIdx = ResolveGltfAccessor(accessors, bufferViews, buffers, prim[@"indices"], idxAcc);

                float baseColor[3]{0.82f, 0.84f, 0.86f};
                int texIndex = -1;
                if (prim[@"material"] && materials) {
                    const NSUInteger matIdx = [prim[@"material"] unsignedIntegerValue];
                    if (matIdx < materials.count) {
                        NSDictionary* mat = materials[matIdx];
                        NSDictionary* pbr = mat[@"pbrMetallicRoughness"];
                        if (pbr) {
                            NSArray* factor = pbr[@"baseColorFactor"];
                            if (factor && factor.count >= 3) {
                                baseColor[0] = [factor[0] floatValue];
                                baseColor[1] = [factor[1] floatValue];
                                baseColor[2] = [factor[2] floatValue];
                            }
                            NSDictionary* bct = pbr[@"baseColorTexture"];
                            if (bct && bct[@"index"] && hasUV) {
                                texIndex = loadGltfTexture([bct[@"index"] intValue]);
                            }
                        }
                    }
                }

                const size_t vertCount = hasIdx ? idxAcc.count : posAcc.count;
                if (vertCount < 3) continue;

                RawSubmesh rawSm;
                rawSm.textureIndex = texIndex;
                rawSm.vertices.reserve(vertCount);

                const size_t posCompSize = ComponentByteSize(posAcc.componentType);
                const size_t normCompSize = hasNorm ? ComponentByteSize(normAcc.componentType) : 0;
                const size_t uvCompSize = hasUV ? ComponentByteSize(uvAcc.componentType) : 0;
                const size_t colCompSize = hasCol ? ComponentByteSize(colAcc.componentType) : 0;

                for (size_t k = 0; k + 2 < vertCount; k += 3) {
                    for (size_t c = 0; c < 3; ++c) {
                        const uint32_t vi = hasIdx
                            ? ReadGltfIndex(idxAcc.data + (k + c) * idxAcc.stride, idxAcc.componentType)
                            : static_cast<uint32_t>(k + c);
                        if (vi >= posAcc.count) continue;
                        const uint8_t* pPtr = posAcc.data + vi * posAcc.stride;
                        const float px = ReadGltfComponentAsFloat(pPtr + 0 * posCompSize, posAcc.componentType, posAcc.normalized);
                        const float py = ReadGltfComponentAsFloat(pPtr + 1 * posCompSize, posAcc.componentType, posAcc.normalized);
                        const float pz = ReadGltfComponentAsFloat(pPtr + 2 * posCompSize, posAcc.componentType, posAcc.normalized);

                        RawVertex rv;
                        rv.pos = TransformPoint(worldMat, {px, py, pz});
                        if (hasNorm && vi < normAcc.count) {
                            const uint8_t* nPtr = normAcc.data + vi * normAcc.stride;
                            const float nx = ReadGltfComponentAsFloat(nPtr + 0 * normCompSize, normAcc.componentType, normAcc.normalized);
                            const float ny = ReadGltfComponentAsFloat(nPtr + 1 * normCompSize, normAcc.componentType, normAcc.normalized);
                            const float nz = ReadGltfComponentAsFloat(nPtr + 2 * normCompSize, normAcc.componentType, normAcc.normalized);
                            rv.norm = TransformDirection(worldMat, {nx, ny, nz});
                        } else {
                            rv.norm = {0, 0, 0};
                        }
                        if (hasUV && vi < uvAcc.count) {
                            const uint8_t* uPtr = uvAcc.data + vi * uvAcc.stride;
                            rv.u = ReadGltfComponentAsFloat(uPtr + 0 * uvCompSize, uvAcc.componentType, uvAcc.normalized);
                            rv.v = ReadGltfComponentAsFloat(uPtr + 1 * uvCompSize, uvAcc.componentType, uvAcc.normalized);
                        }
                        rv.color[0] = baseColor[0];
                        rv.color[1] = baseColor[1];
                        rv.color[2] = baseColor[2];
                        if (hasCol && vi < colAcc.count) {
                            const uint8_t* cPtr = colAcc.data + vi * colAcc.stride;
                            rv.color[0] *= ReadGltfComponentAsFloat(cPtr + 0 * colCompSize, colAcc.componentType, true);
                            rv.color[1] *= ReadGltfComponentAsFloat(cPtr + 1 * colCompSize, colAcc.componentType, true);
                            rv.color[2] *= ReadGltfComponentAsFloat(cPtr + 2 * colCompSize, colAcc.componentType, true);
                        }
                        rawSm.vertices.push_back(rv);
                    }
                }
                if (rawSm.vertices.size() >= 3) {
                    scene.submeshes.push_back(std::move(rawSm));
                }
            }
        };

        std::function<void(NSUInteger, simd_float4x4, int)> visitNode =
            [&](NSUInteger nodeIdx, simd_float4x4 parentMat, int depth) {
                if (!nodes || nodeIdx >= nodes.count || depth > 64) return;
                NSDictionary* node = nodes[nodeIdx];
                simd_float4x4 worldMat = simd_mul(parentMat, ParseGltfNodeMatrix(node));
                if (node[@"mesh"]) {
                    emitMesh([node[@"mesh"] unsignedIntegerValue], worldMat);
                }
                NSArray* children = node[@"children"];
                for (NSNumber* childIdx in children) {
                    visitNode(childIdx.unsignedIntegerValue, worldMat, depth + 1);
                }
            };

        if (nodes && nodes.count > 0) {
            NSArray* scenes = root[@"scenes"];
            const NSUInteger sceneIdx = root[@"scene"] ? [root[@"scene"] unsignedIntegerValue] : 0;
            if (scenes && sceneIdx < scenes.count && scenes[sceneIdx][@"nodes"]) {
                for (NSNumber* nIdx in scenes[sceneIdx][@"nodes"]) {
                    visitNode(nIdx.unsignedIntegerValue, matrix_identity_float4x4, 0);
                }
            } else {
                for (NSUInteger i = 0; i < nodes.count; ++i) {
                    visitNode(i, matrix_identity_float4x4, 0);
                }
            }
        } else {
            for (NSUInteger i = 0; i < meshes.count; ++i) {
                emitMesh(i, matrix_identity_float4x4);
            }
        }
    }
    return !scene.submeshes.empty();
}

}
