// SPDX-License-Identifier: MIT


#include "HandStereo.h"
#import <Metal/Metal.h>
#import <CoreVideo/CVMetalTextureCache.h>
#include <atomic>
#include <cstdio>
#include <ctime>
#include <cstring>
#include <mutex>

namespace {
const char* kShaders = R"METAL(
#include <metal_stdlib>
using namespace metal;

struct Box { int x0, y0, x1, y1; };

kernel void rectify(texture2d<float, access::sample> color [[texture(0)]],
                    texture2d<float, access::read> map [[texture(1)]],
                    texture2d<float, access::write> gray [[texture(2)]],
                    texture2d<float, access::write> rgb [[texture(3)]],
                    uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= gray.get_width() || gid.y >= gray.get_height()) return;
    constexpr sampler s(coord::normalized, filter::linear, address::clamp_to_edge);
    const float2 uv = map.read(gid).xy;
    float3 c = 0;
    if (uv.x >= 0) c = color.sample(s, uv).rgb;
    gray.write(float4(dot(c, float3(0.299, 0.587, 0.114))), gid);
    rgb.write(float4(c, 1), gid);
}

kernel void census(texture2d<float, access::read> gray [[texture(0)]],
                   texture2d<uint, access::write> out [[texture(1)]],
                   uint2 gid [[thread_position_in_grid]]) {
    const int w = gray.get_width(), h = gray.get_height();
    if (int(gid.x) >= w || int(gid.y) >= h) return;
    const float center = gray.read(gid).r;
    uint lo = 0, hi = 0, bit = 0;
    for (int dy = -3; dy <= 3; ++dy)
        for (int dx = -3; dx <= 3; ++dx) {
            if (dx == 0 && dy == 0) continue;
            const uint2 p = uint2(clamp(int(gid.x) + dx, 0, w - 1), clamp(int(gid.y) + dy, 0, h - 1));
            const uint set = gray.read(p).r < center ? 1u : 0u;
            if (bit < 32) lo |= set << bit; else hi |= set << (bit - 32);
            ++bit;
        }
    out.write(uint4(lo, hi, 0, 0), gid);
}

struct DisparityParams { Box box; int dmin, dmax, sign, maxCost; float minMargin; int useCoarse; };


kernel void downsample(texture2d<float, access::read> in [[texture(0)]],
                       texture2d<float, access::write> out [[texture(1)]],
                       uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
    const uint2 b = gid * 2, m = uint2(in.get_width() - 1, in.get_height() - 1);
    const float v = in.read(min(b, m)).r + in.read(min(b + uint2(1, 0), m)).r + in.read(min(b + uint2(0, 1), m)).r +
                    in.read(min(b + uint2(1, 1), m)).r;
    out.write(float4(v * 0.25), gid);
}

inline uint Cost(texture2d<uint, access::read> ref, texture2d<uint, access::read> other, int x, int y, int xo) {
    uint c = 0;
    for (int dy = -1; dy <= 1; ++dy)
        for (int dx = -1; dx <= 1; ++dx) {
            const uint2 a = ref.read(uint2(x + dx, y + dy)).xy, b = other.read(uint2(xo + dx, y + dy)).xy;
            c += popcount(a.x ^ b.x) + popcount(a.y ^ b.y);
        }
    return c;
}




kernel void disparity(texture2d<uint, access::read> ref [[texture(0)]],
                      texture2d<uint, access::read> other [[texture(1)]],
                      texture2d<float, access::write> out [[texture(2)]],
                      texture2d<float, access::read> coarse [[texture(3)]],
                      constant DisparityParams& p [[buffer(0)]],
                      uint2 gid [[thread_position_in_grid]]) {
    const int x = p.box.x0 + int(gid.x), y = p.box.y0 + int(gid.y);
    if (x >= p.box.x1 || y >= p.box.y1) return;
    const int w = ref.get_width();
    int dmin = p.dmin, dmax = p.dmax;
    if (p.useCoarse) {
        const int cw = coarse.get_width(), ch = coarse.get_height();
        float lo = 1e9, hi = -1;
        for (int dy = -1; dy <= 1; ++dy)
            for (int dx = -1; dx <= 1; ++dx) {
                const int cx = clamp(x / 2 + dx, 0, cw - 1), cy = clamp(y / 2 + dy, 0, ch - 1);
                const float c = coarse.read(uint2(cx, cy)).x;
                if (c > 0) { lo = min(lo, c); hi = max(hi, c); }
            }
        if (hi < 0) { out.write(float4(-1, 0, 0, 0), uint2(x, y)); return; }
        dmin = max(p.dmin, int(floor(lo * 2)) - 2);
        dmax = min(p.dmax, int(ceil(hi * 2)) + 2);
    }
    uint best = 0xffffffffu, second = 0xffffffffu;
    int bestD = -1;
    for (int d = dmin; d <= dmax; ++d) {
        const int xo = x + p.sign * d;
        if (xo < 2 || xo > w - 3) continue;
        const uint c = Cost(ref, other, x, y, xo);
        if (c < best) {
            if (bestD >= 0 && abs(d - bestD) > 1) second = min(second, best);
            best = c;
            bestD = d;
        } else if (abs(d - bestD) > 1 && c < second) {
            second = c;
        }
    }
    float result = -1, margin = 0;
    if (bestD >= 0 && best <= uint(p.maxCost)) {
        margin = float(second - best) / float(max(best, 1u));
        if (margin >= p.minMargin) {
            result = float(bestD);
            const int xm = x + p.sign * (bestD - 1), xp = x + p.sign * (bestD + 1);
            if (bestD > dmin && bestD < dmax && xm >= 2 && xm <= w - 3 && xp >= 2 && xp <= w - 3) {
                const float cm = float(Cost(ref, other, x, y, xm)), cp = float(Cost(ref, other, x, y, xp));
                const float denom = cm - 2 * float(best) + cp;
                if (denom > 0) result += clamp(0.5f * (cm - cp) / denom, -0.5f, 0.5f);
            }
        }
    }
    out.write(float4(result, margin, 0, 0), uint2(x, y));
}

struct MaskParams { Box box[2]; float zNear[2], zFar[2]; int count, sign; float fb, lrTolerance; };

kernel void clearDisparity(texture2d<float, access::write> out [[texture(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x < out.get_width() && gid.y < out.get_height()) out.write(float4(-1, 0, 0, 0), gid);
}


kernel void validate(texture2d<float, access::read> disp [[texture(0)]],
                     texture2d<float, access::read> otherDisp [[texture(1)]],
                     texture2d<float, access::write> out [[texture(2)]],
                     constant MaskParams& p [[buffer(0)]],
                     uint2 gid [[thread_position_in_grid]]) {
    const int x = int(gid.x), y = int(gid.y), w = int(out.get_width());
    if (x >= w || y >= int(out.get_height())) return;
    const float d = disp.read(gid).x;
    float valid = -1;
    if (d > 0) {
        const int xo = int(round(float(x) + p.sign * d));
        const float back = (xo >= 0 && xo < w) ? otherDisp.read(uint2(xo, y)).x : -1;
        if (back > 0 && abs(back - d) <= p.lrTolerance) valid = d;
    }
    out.write(float4(valid), gid);
}







kernel void classify(texture2d<float, access::read> valid [[texture(0)]],
                     texture2d<float, access::write> out [[texture(1)]],
                     constant MaskParams& p [[buffer(0)]],
                     uint2 gid [[thread_position_in_grid]]) {
    const int x = int(gid.x), y = int(gid.y), w = int(out.get_width());
    if (x >= w || y >= int(out.get_height())) return;
    bool inside = false;
    for (int i = 0; i < p.count; ++i)
        inside = inside || (x >= p.box[i].x0 && x < p.box[i].x1 && y >= p.box[i].y0 && y < p.box[i].y1);
    float value = 0;
    if (inside) {
        float d = valid.read(gid).x;
        if (d <= 0) {
            float left = -1, right = -1;
            for (int s = 1; s <= 72 && (left <= 0 || right <= 0); ++s) {
                if (left <= 0 && x - s >= 0) left = valid.read(uint2(x - s, y)).x;
                if (right <= 0 && x + s < w) right = valid.read(uint2(x + s, y)).x;
            }



            const float outer = p.sign < 0 ? left : right, inner = p.sign < 0 ? right : left;



            d = outer > 0 ? outer : -1;
            (void)inner;
        }
        value = 0.5;
        if (d > 0) {
            const float z = p.fb / d;
            bool inRange = false;
            for (int i = 0; i < p.count; ++i)
                inRange = inRange || (x >= p.box[i].x0 && x < p.box[i].x1 && y >= p.box[i].y0 && y < p.box[i].y1 &&
                                      z >= p.zNear[i] && z <= p.zFar[i]);

            value = inRange ? (valid.read(gid).x > 0 ? 1.0 : 0.5) : 0.0;
        }
    }
    out.write(float4(value), gid);
}






struct FillParams { int count; float radius; float2 joints[64]; };

kernel void fill(texture2d<float, access::read> in [[texture(0)]],
                 texture2d<float, access::write> out [[texture(1)]],
                 texture2d<float, access::read> rgb [[texture(2)]],
                 constant FillParams& p [[buffer(0)]],
                 uint2 gid [[thread_position_in_grid]]) {
    const int w = in.get_width(), h = in.get_height();
    if (int(gid.x) >= w || int(gid.y) >= h) return;
    const float v = in.read(gid).r;
    float result = v;
    if (v > 0.25 && v < 0.75) {
        float3 handSum = 0, backSum = 0;
        float hand = 0, background = 0;
        for (int dy = -7; dy <= 7; ++dy)
            for (int dx = -7; dx <= 7; ++dx) {
                const uint2 q = uint2(clamp(int(gid.x) + dx, 0, w - 1), clamp(int(gid.y) + dy, 0, h - 1));
                const float n = in.read(q).r;
                if (n > 0.75) { handSum += rgb.read(q).rgb; hand += 1; }
                else if (n < 0.25) { backSum += rgb.read(q).rgb; background += 1; }
            }


        for (int dy = -21; background == 0 && dy <= 21; dy += 3)
            for (int dx = -21; dx <= 21; dx += 3) {
                if (abs(dx) <= 7 && abs(dy) <= 7) continue;
                const uint2 q = uint2(clamp(int(gid.x) + dx, 0, w - 1), clamp(int(gid.y) + dy, 0, h - 1));
                const float n = in.read(q).r;
                if (n < 0.25) { backSum += rgb.read(q).rgb; background += 1; }
            }


        float nearest = 1e9;
        for (int i = 0; i < p.count; ++i) nearest = min(nearest, distance(float2(gid), p.joints[i]));
        if (nearest <= p.radius) {
            for (int i = 0; i < p.count; ++i) {
                const uint2 q = uint2(clamp(int(p.joints[i].x), 0, w - 1), clamp(int(p.joints[i].y), 0, h - 1));
                handSum += rgb.read(q).rgb;
                hand += 1;
            }
        }
        if (hand == 0) result = 0;
        else if (background == 0) result = 1;
        else {
            const float3 c = rgb.read(gid).rgb;
            result = distance(c, handSum / hand) < distance(c, backSum / background) ? 1.0 : 0.0;
        }
    }
    out.write(float4(result), gid);
}


kernel void morph(texture2d<float, access::read> in [[texture(0)]],
                  texture2d<float, access::write> out [[texture(1)]],
                  constant int& op [[buffer(0)]],
                  uint2 gid [[thread_position_in_grid]]) {
    const int w = in.get_width(), h = in.get_height();
    if (int(gid.x) >= w || int(gid.y) >= h) return;
    float r = op == 0 ? 0.0 : 1.0;
    for (int dy = -1; dy <= 1; ++dy)
        for (int dx = -1; dx <= 1; ++dx) {
            const float n = in.read(uint2(clamp(int(gid.x) + dx, 0, w - 1), clamp(int(gid.y) + dy, 0, h - 1))).r;
            r = op == 0 ? max(r, n) : min(r, n);
        }
    out.write(float4(r), gid);
}

struct CutoutParams { Box box; float step, rectWidth, rectHeight; };






struct TemporalParams { Box box[2]; float shift[2][2]; float keep[2]; int count; };

kernel void temporal(texture2d<float, access::read> mask [[texture(0)]],
                     texture2d<float, access::sample> previous [[texture(1)]],
                     texture2d<float, access::write> average [[texture(2)]],
                     texture2d<float, access::write> binary [[texture(3)]],
                     constant TemporalParams& p [[buffer(0)]],
                     uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= mask.get_width() || gid.y >= mask.get_height()) return;
    constexpr sampler linear(coord::pixel, filter::linear, address::clamp_to_zero);
    const float current = mask.read(gid).r;
    float value = current;
    for (int i = 0; i < p.count; ++i) {
        const int x = int(gid.x), y = int(gid.y);
        if (x >= p.box[i].x0 && x < p.box[i].x1 && y >= p.box[i].y0 && y < p.box[i].y1) {
            const float before = previous.sample(linear, float2(gid) + 0.5 - float2(p.shift[i][0], p.shift[i][1])).r;
            value = mix(current, before, p.keep[i]);
            break;
        }
    }
    average.write(float4(value), gid);
    binary.write(float4(value > 0.5 ? 1.0 : 0.0), gid);
}



inline float2 InverseAt(texture2d<float, access::read> inverse, float2 g) {
    const int w = inverse.get_width(), h = inverse.get_height();
    const int2 i0 = int2(floor(g));
    const float2 t = g - float2(i0);
    if (i0.x < 0 || i0.y < 0 || i0.x + 1 >= w || i0.y + 1 >= h) return float2(-1);
    const float2 a = inverse.read(uint2(i0)).xy, b = inverse.read(uint2(i0 + int2(1, 0))).xy;
    const float2 c = inverse.read(uint2(i0 + int2(0, 1))).xy, d = inverse.read(uint2(i0 + int2(1, 1))).xy;
    if (min(min(a.x, b.x), min(c.x, d.x)) < 0) return float2(-1);
    return mix(mix(a, b, t.x), mix(c, d, t.x), t.y);
}

kernel void cutout(texture2d<float, access::read> color [[texture(0)]],
                   texture2d<float, access::read> inverse [[texture(1)]],
                   texture2d<float, access::sample> mask [[texture(2)]],
                   texture2d<float, access::write> out [[texture(3)]],
                   texture2d<float, access::sample> average [[texture(4)]],
                   constant CutoutParams& p [[buffer(0)]],
                   uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= out.get_width() || gid.y >= out.get_height()) return;
    const int x = int(gid.x), y = int(gid.y);
    float alpha = 0;
    if (x >= p.box.x0 && x < p.box.x1 && y >= p.box.y0 && y < p.box.y1) {
        constexpr sampler linear(coord::pixel, filter::linear, address::clamp_to_edge);

        const float2 rect = InverseAt(inverse, float2(gid) / p.step);
        if (rect.x >= 0 && rect.y >= 0 && rect.x < p.rectWidth && rect.y < p.rectHeight)

            alpha = mask.sample(linear, rect + 0.5).r * smoothstep(0.3, 0.7, average.sample(linear, rect + 0.5).r);
    }
    const float4 c = color.read(gid);
    out.write(float4(c.rgb, alpha), gid);
}
)METAL";

struct Box { int x0, y0, x1, y1; };
struct DisparityParams { Box box; int dmin, dmax, sign, maxCost; float minMargin; int useCoarse; };
struct FillParams { int count; float radius; float joints[64][2]; };
struct MaskParams { Box box[2]; float zNear[2], zFar[2]; int count, sign; float fb, lrTolerance; };
struct CutoutParams { Box box; float step, rectWidth, rectHeight; };
struct TemporalParams { Box box[2]; float shift[2][2]; float keep[2]; int count; };



constexpr int kMaxCost = 9 * 48 * 30 / 100;
constexpr float kMinMargin = 0.06f;
constexpr int kMaxDisparity = 160;

struct Gpu {
    id<MTLDevice> device = nil;
    id<MTLCommandQueue> queue = nil;
    id<MTLComputePipelineState> rectify = nil, census = nil, disparity = nil, classify = nil, fill = nil, morph = nil,
                                cutout = nil, clear = nil, validate = nil, downsample = nil, temporal = nil;
    CVMetalTextureCacheRef cache = nullptr;
    id<MTLTexture> forward[2], inverse[2], gray[2], rgb[2], censusTex[2], disp[2], valid[2], cls[2], tmpA[2], tmpB[2];
    id<MTLTexture> grayHalf[2], censusHalf[2], dispHalf[2];
    id<MTLTexture> average[2][2], stable[2];
    int averageIndex = 0;
    std::shared_ptr<const stereo::Rig> rig;
};

struct PoolSlot {
    CVPixelBufferPoolRef pool = nullptr;
    size_t width = 0, height = 0;
    CVPixelBufferRef Make(size_t w, size_t h) {
        if (!pool || width != w || height != h) {
            if (pool) CVPixelBufferPoolRelease(pool);
            pool = nullptr;
            NSDictionary* attributes = @{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA),
                                         (id)kCVPixelBufferWidthKey:@(w), (id)kCVPixelBufferHeightKey:@(h),
                                         (id)kCVPixelBufferIOSurfacePropertiesKey:@{},
                                         (id)kCVPixelBufferMetalCompatibilityKey:@YES};
            if (CVPixelBufferPoolCreate(kCFAllocatorDefault, nullptr, (__bridge CFDictionaryRef)attributes, &pool) !=
                kCVReturnSuccess) return nullptr;
            width = w;
            height = h;
        }
        CVPixelBufferRef out = nullptr;
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out);
        return out;
    }
};

struct State {
    dispatch_queue_t queue = dispatch_queue_create("pippin.hand-stereo", DISPATCH_QUEUE_SERIAL);
    std::atomic<bool> busy{false}, configured{false};


    std::atomic<int64_t> nextAllowedNs{0};
    std::atomic<uint64_t> generation{1};
    Gpu gpu;
    PoolSlot out[2];
    int logged = 0;


    double previousMean[2][2][2] = {};
    bool previousHand[2][2] = {};
    int64_t previousNs = 0;
    std::mutex mutex;
    HandMaskOutput result;
    uint64_t sequence = 0;
};
State& Shared() {
    static State* state = new State;
    return *state;
}

void Release(HandMaskOutput& out) {
    for (auto& buffer : out.cutout) {
        if (buffer) CVPixelBufferRelease(buffer);
        buffer = nullptr;
    }
}

id<MTLTexture> MakeTexture(id<MTLDevice> device, MTLPixelFormat format, int width, int height, bool shared = false) {
    MTLTextureDescriptor* d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:NSUInteger(width)
                                                                                height:NSUInteger(height) mipmapped:NO];
    d.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite;
    d.storageMode = shared ? MTLStorageModeShared : MTLStorageModePrivate;
    return [device newTextureWithDescriptor:d];
}

id<MTLTexture> UploadMap(id<MTLDevice> device, const std::vector<float>& data, int width, int height) {
    MTLTextureDescriptor* d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRG32Float
        width:NSUInteger(width) height:NSUInteger(height) mipmapped:NO];
    d.usage = MTLTextureUsageShaderRead;
    d.storageMode = MTLStorageModeShared;
    id<MTLTexture> t = [device newTextureWithDescriptor:d];
    [t replaceRegion:MTLRegionMake2D(0, 0, NSUInteger(width), NSUInteger(height)) mipmapLevel:0
           withBytes:data.data() bytesPerRow:NSUInteger(width) * 8];
    return t;
}

bool SetUp(Gpu& gpu, std::shared_ptr<const stereo::Rig> rig) {
    if (!gpu.device) {
        gpu.device = MTLCreateSystemDefaultDevice();
        if (!gpu.device) return false;
        gpu.queue = [gpu.device newCommandQueue];
        NSError* error = nil;
        id<MTLLibrary> library = [gpu.device newLibraryWithSource:@(kShaders) options:nil error:&error];
        if (!library) {
            NSLog(@"Hand stereo: shader compile failed: %@", error);
            gpu.device = nil;
            return false;
        }
        auto pipe = [&](NSString* name) {
            id<MTLFunction> f = [library newFunctionWithName:name];
            return f ? [gpu.device newComputePipelineStateWithFunction:f error:nil] : nil;
        };
        gpu.rectify = pipe(@"rectify"); gpu.census = pipe(@"census"); gpu.disparity = pipe(@"disparity");
        gpu.classify = pipe(@"classify"); gpu.fill = pipe(@"fill"); gpu.morph = pipe(@"morph");
        gpu.cutout = pipe(@"cutout"); gpu.clear = pipe(@"clearDisparity"); gpu.validate = pipe(@"validate");
        gpu.downsample = pipe(@"downsample");
        gpu.temporal = pipe(@"temporal");
        if (!gpu.temporal || !gpu.downsample || !gpu.clear || !gpu.validate || !gpu.rectify || !gpu.census || !gpu.disparity || !gpu.classify || !gpu.fill || !gpu.morph || !gpu.cutout ||
            CVMetalTextureCacheCreate(kCFAllocatorDefault, nullptr, gpu.device, nullptr, &gpu.cache) != kCVReturnSuccess) {
            gpu.device = nil;
            return false;
        }
    }
    gpu.rig = rig;
    for (int k = 0; k < 2; ++k) {
        gpu.forward[k] = UploadMap(gpu.device, rig->forward[k], rig->width, rig->height);
        gpu.inverse[k] = UploadMap(gpu.device, rig->inverse[k], rig->gridWidth, rig->gridHeight);
        gpu.gray[k] = MakeTexture(gpu.device, MTLPixelFormatR16Float, rig->width, rig->height);
        gpu.rgb[k] = MakeTexture(gpu.device, MTLPixelFormatRGBA16Float, rig->width, rig->height);
        gpu.censusTex[k] = MakeTexture(gpu.device, MTLPixelFormatRG32Uint, rig->width, rig->height);
        gpu.disp[k] = MakeTexture(gpu.device, MTLPixelFormatRG32Float, rig->width, rig->height);
        gpu.valid[k] = MakeTexture(gpu.device, MTLPixelFormatR32Float, rig->width, rig->height);
        const int hw = (rig->width + 1) / 2, hh = (rig->height + 1) / 2;
        gpu.grayHalf[k] = MakeTexture(gpu.device, MTLPixelFormatR16Float, hw, hh);
        gpu.censusHalf[k] = MakeTexture(gpu.device, MTLPixelFormatRG32Uint, hw, hh);
        gpu.dispHalf[k] = MakeTexture(gpu.device, MTLPixelFormatRG32Float, hw, hh);
        gpu.average[k][0] = MakeTexture(gpu.device, MTLPixelFormatR16Float, rig->width, rig->height);
        gpu.average[k][1] = MakeTexture(gpu.device, MTLPixelFormatR16Float, rig->width, rig->height);
        gpu.stable[k] = MakeTexture(gpu.device, MTLPixelFormatR8Unorm, rig->width, rig->height, true);
        gpu.cls[k] = MakeTexture(gpu.device, MTLPixelFormatR16Float, rig->width, rig->height);
        gpu.tmpA[k] = MakeTexture(gpu.device, MTLPixelFormatR16Float, rig->width, rig->height);
        gpu.tmpB[k] = MakeTexture(gpu.device, MTLPixelFormatR8Unorm, rig->width, rig->height, true);
    }
    return true;
}

id<MTLTexture> Wrap(Gpu& gpu, CVPixelBufferRef buffer, CVMetalTextureRef& holder) {
    holder = nullptr;
    if (CVMetalTextureCacheCreateTextureFromImage(kCFAllocatorDefault, gpu.cache, buffer, nullptr,
            MTLPixelFormatBGRA8Unorm, CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer), 0, &holder) !=
        kCVReturnSuccess) return nil;
    return CVMetalTextureGetTexture(holder);
}

void Dispatch(id<MTLComputeCommandEncoder> e, id<MTLComputePipelineState> p, int width, int height) {
    [e setComputePipelineState:p];
    const NSUInteger tw = p.threadExecutionWidth, th = std::max<NSUInteger>(1, p.maxTotalThreadsPerThreadgroup / tw);
    [e dispatchThreads:MTLSizeMake(NSUInteger(std::max(width, 1)), NSUInteger(std::max(height, 1)), 1)
        threadsPerThreadgroup:MTLSizeMake(tw, th, 1)];
}

struct Plan {
    struct Hand {
        bool any = false;
        Box rect{};
        int dmin = 0, dmax = 0;
        float zNear = 0, zFar = 0;
    } hands[2];
    int count = 0;
    Box color[2]{};
    float zNear = 0, zFar = 0;
    std::vector<std::array<double, 2>> joints[2][2];
};




Plan MakePlan(const stereo::Rig& rig, const HandStereoInput& input) {
    Plan plan;
    double cx0[2] = {1e9, 1e9}, cy0[2] = {1e9, 1e9}, cx1[2] = {-1e9, -1e9}, cy1[2] = {-1e9, -1e9};
    const double fb = rig.f * rig.baseline;
    plan.zNear = 1e9;
    for (int hand = 0; hand < 2; ++hand) {
        double x0 = 1e9, y0 = 1e9, x1 = -1e9, y1 = -1e9, zmin = 1e9, zmax = 0;
        for (const auto& joint : input.joints[hand])
            for (int k = 0; k < 2; ++k) {
                const stereo::V3 r = rig.RectPoint(k, joint);
                double x, y;
                if (!rig.RectPixel(r, x, y) || !std::isfinite(x) || !std::isfinite(y) || x < 0 || y < 0 ||
                    x > rig.width - 1 || y > rig.height - 1) continue;
                plan.joints[k][hand].push_back({x, y});
                x0 = std::min(x0, x); x1 = std::max(x1, x); y0 = std::min(y0, y); y1 = std::max(y1, y);
                zmin = std::min(zmin, r[2]); zmax = std::max(zmax, r[2]);
                const int ix = std::clamp(int(std::lround(x)), 0, rig.width - 1);
                const int iy = std::clamp(int(std::lround(y)), 0, rig.height - 1);
                const float u = rig.forward[k][(size_t(iy) * rig.width + ix) * 2];
                const float v = rig.forward[k][(size_t(iy) * rig.width + ix) * 2 + 1];
                if (u >= 0) {
                    cx0[k] = std::min(cx0[k], double(u)); cx1[k] = std::max(cx1[k], double(u));
                    cy0[k] = std::min(cy0[k], double(v)); cy1[k] = std::max(cy1[k], double(v));
                }
            }
        if (x1 < x0 || zmax <= 0) continue;
        Plan::Hand& h = plan.hands[hand];


        const double reach = rig.f * 0.05 / std::max(0.15, zmin);
        const double padX = std::max(reach, 0.3 * (x1 - x0)), padY = std::max(reach, 0.3 * (y1 - y0));

        h.rect = {std::clamp(int(x0 - padX), 5, rig.width - 5), std::clamp(int(y0 - padY), 5, rig.height - 5),
                  std::clamp(int(x1 + padX) + 1, 5, rig.width - 5), std::clamp(int(y1 + padY) + 1, 5, rig.height - 5)};



        h.zNear = float(std::max(0.10, zmin - 0.06));
        h.zFar = float(zmax + 0.05);
        h.dmin = std::max(1, int(std::floor(fb / 2.0)));
        h.dmax = std::min(kMaxDisparity, int(std::ceil(fb / std::max(0.12, double(h.zNear) - 0.03))));
        h.any = h.rect.x1 > h.rect.x0 + 4 && h.rect.y1 > h.rect.y0 + 4 && h.dmax > h.dmin;
        if (h.any) {
            ++plan.count;
            plan.zNear = std::min(plan.zNear, h.zNear);
            plan.zFar = std::max(plan.zFar, h.zFar);
        }
    }
    for (int k = 0; k < 2; ++k) {
        if (cx1[k] < cx0[k]) { plan.color[k] = {0, 0, 0, 0}; continue; }
        const double px = std::max(0.06, 0.3 * (cx1[k] - cx0[k])), py = std::max(0.06, 0.3 * (cy1[k] - cy0[k]));
        plan.color[k] = {std::clamp(int((cx0[k] - px) * rig.colorWidth), 0, rig.colorWidth),
                         std::clamp(int((cy0[k] - py) * rig.colorHeight), 0, rig.colorHeight),
                         std::clamp(int((cx1[k] + px) * rig.colorWidth) + 1, 0, rig.colorWidth),
                         std::clamp(int((cy1[k] + py) * rig.colorHeight) + 1, 0, rig.colorHeight)};
    }
    if (!plan.count) plan.zNear = 0;
    return plan;
}


HandMaskOutput Process(State& state, CVPixelBufferRef left, CVPixelBufferRef right, int64_t captureNs,
                       const HandStereoInput& input) {
    HandMaskOutput output;
    output.captureNs = captureNs;
    Gpu& gpu = state.gpu;
    if (!gpu.device || !gpu.rig) return output;
    const stereo::Rig& rig = *gpu.rig;
    if (int(CVPixelBufferGetWidth(left)) != rig.colorWidth || int(CVPixelBufferGetHeight(left)) != rig.colorHeight ||
        CVPixelBufferGetWidth(right) != CVPixelBufferGetWidth(left)) return output;
    const Plan plan = MakePlan(rig, input);
    if (!plan.count) return output;
    const int64_t began = static_cast<int64_t>(clock_gettime_nsec_np(CLOCK_MONOTONIC));
    CVMetalTextureRef holders[4] = {};
    CVPixelBufferRef outs[2] = {state.out[0].Make(rig.colorWidth, rig.colorHeight),
                                state.out[1].Make(rig.colorWidth, rig.colorHeight)};
    id<MTLTexture> colors[2] = {Wrap(gpu, left, holders[0]), Wrap(gpu, right, holders[1])};
    id<MTLTexture> targets[2] = {outs[0] ? Wrap(gpu, outs[0], holders[2]) : nil,
                                 outs[1] ? Wrap(gpu, outs[1], holders[3]) : nil};
    bool ok = colors[0] && colors[1] && targets[0] && targets[1];
    double mean[2][2][2] = {};
    bool have[2][2] = {};
    if (ok) {
        id<MTLCommandBuffer> cb = [gpu.queue commandBuffer];
        id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
        for (int k = 0; k < 2; ++k) {
            [e setTexture:colors[k] atIndex:0]; [e setTexture:gpu.forward[k] atIndex:1]; [e setTexture:gpu.gray[k] atIndex:2];
            [e setTexture:gpu.rgb[k] atIndex:3];
            Dispatch(e, gpu.rectify, rig.width, rig.height);
            [e setTexture:gpu.gray[k] atIndex:0]; [e setTexture:gpu.censusTex[k] atIndex:1];
            Dispatch(e, gpu.census, rig.width, rig.height);
            [e setTexture:gpu.gray[k] atIndex:0]; [e setTexture:gpu.grayHalf[k] atIndex:1];
            Dispatch(e, gpu.downsample, int(gpu.grayHalf[k].width), int(gpu.grayHalf[k].height));
            [e setTexture:gpu.grayHalf[k] atIndex:0]; [e setTexture:gpu.censusHalf[k] atIndex:1];
            Dispatch(e, gpu.census, int(gpu.grayHalf[k].width), int(gpu.grayHalf[k].height));
        }

        MaskParams m{};

        TemporalParams temporal[2]{};
        const bool recent = state.previousNs > 0 && captureNs > state.previousNs &&
                            captureNs - state.previousNs < 150000000LL;
        for (int k = 0; k < 2; ++k) {
            for (int hand = 0; hand < 2; ++hand) {
                const auto& joints = plan.joints[k][hand];
                if (joints.empty()) continue;
                for (const auto& j : joints) { mean[k][hand][0] += j[0] / joints.size(); mean[k][hand][1] += j[1] / joints.size(); }
                have[k][hand] = true;
            }
            for (int hand = 0; hand < 2; ++hand) {
                const auto& h = plan.hands[hand];
                if (!h.any) continue;
                TemporalParams& t = temporal[k];
                const int i = t.count++;
                t.box[i] = h.rect;
                const double dx = mean[k][hand][0] - state.previousMean[k][hand][0];
                const double dy = mean[k][hand][1] - state.previousMean[k][hand][1];


                const double limit = 0.25 * std::max(h.rect.x1 - h.rect.x0, h.rect.y1 - h.rect.y0);
                const bool known = recent && have[k][hand] && state.previousHand[k][hand] && std::hypot(dx, dy) < limit;
                t.keep[i] = known ? 0.6f : 0.0f;
                t.shift[i][0] = known ? float(dx) : 0;
                t.shift[i][1] = known ? float(dy) : 0;
            }
        }


        const int hw = int(gpu.dispHalf[0].width), hh = int(gpu.dispHalf[0].height);
        for (int k = 0; k < 2; ++k) {
            [e setTexture:gpu.dispHalf[k] atIndex:0];
            Dispatch(e, gpu.clear, hw, hh);
            [e setTexture:gpu.disp[k] atIndex:0];
            Dispatch(e, gpu.clear, rig.width, rig.height);
            for (const auto& h : plan.hands) {
                if (!h.any) continue;
                const Box half{std::max(h.rect.x0 / 2, 3), std::max(h.rect.y0 / 2, 3), std::min((h.rect.x1 + 1) / 2, hw - 3),
                               std::min((h.rect.y1 + 1) / 2, hh - 3)};
                if (half.x1 <= half.x0 || half.y1 <= half.y0) continue;
                const DisparityParams p{half, std::max(1, h.dmin / 2), (h.dmax + 1) / 2, k == 0 ? -1 : 1, kMaxCost,
                                        kMinMargin, 0};
                [e setTexture:gpu.censusHalf[k] atIndex:0]; [e setTexture:gpu.censusHalf[1 - k] atIndex:1];
                [e setTexture:gpu.dispHalf[k] atIndex:2]; [e setTexture:gpu.disp[k] atIndex:3];
                [e setBytes:&p length:sizeof p atIndex:0];
                Dispatch(e, gpu.disparity, half.x1 - half.x0, half.y1 - half.y0);
            }
        }
        for (int k = 0; k < 2; ++k)
            for (const auto& h : plan.hands) {
                if (!h.any) continue;
                const DisparityParams p{h.rect, h.dmin, h.dmax, k == 0 ? -1 : 1, kMaxCost, kMinMargin, 1};
                [e setTexture:gpu.censusTex[k] atIndex:0]; [e setTexture:gpu.censusTex[1 - k] atIndex:1];
                [e setTexture:gpu.disp[k] atIndex:2]; [e setTexture:gpu.dispHalf[k] atIndex:3];
                [e setBytes:&p length:sizeof p atIndex:0];
                Dispatch(e, gpu.disparity, h.rect.x1 - h.rect.x0, h.rect.y1 - h.rect.y0);
            }
        for (const auto& h : plan.hands) {
            if (!h.any) continue;
            m.box[m.count] = h.rect;
            m.zNear[m.count] = h.zNear;
            m.zFar[m.count] = h.zFar;
            ++m.count;
        }
        m.fb = float(rig.f * rig.baseline);
        m.lrTolerance = 1.0f;
        for (int k = 0; k < 2; ++k) {
            m.sign = k == 0 ? -1 : 1;
            [e setTexture:gpu.disp[k] atIndex:0]; [e setTexture:gpu.disp[1 - k] atIndex:1]; [e setTexture:gpu.valid[k] atIndex:2];
            [e setBytes:&m length:sizeof m atIndex:0];
            Dispatch(e, gpu.validate, rig.width, rig.height);
            [e setTexture:gpu.valid[k] atIndex:0]; [e setTexture:gpu.cls[k] atIndex:1];
            Dispatch(e, gpu.classify, rig.width, rig.height);
        }
        for (int k = 0; k < 2; ++k) {
            FillParams fp{};
            for (int hand = 0; hand < 2; ++hand)
                for (const auto& j : plan.joints[k][hand])
                    if (fp.count < 64) { fp.joints[fp.count][0] = float(j[0]); fp.joints[fp.count][1] = float(j[1]); ++fp.count; }

            fp.radius = float(rig.f * 0.06 / std::max(0.15, double(plan.zNear) + 0.06));
            [e setTexture:gpu.cls[k] atIndex:0]; [e setTexture:gpu.tmpA[k] atIndex:1]; [e setTexture:gpu.rgb[k] atIndex:2];
            [e setBytes:&fp length:sizeof fp atIndex:0];
            Dispatch(e, gpu.fill, rig.width, rig.height);
            int op = 0;
            [e setTexture:gpu.tmpA[k] atIndex:0]; [e setTexture:gpu.cls[k] atIndex:1]; [e setBytes:&op length:4 atIndex:0];
            Dispatch(e, gpu.morph, rig.width, rig.height);
            op = 1;
            [e setTexture:gpu.cls[k] atIndex:0]; [e setTexture:gpu.tmpB[k] atIndex:1]; [e setBytes:&op length:4 atIndex:0];
            Dispatch(e, gpu.morph, rig.width, rig.height);
            [e setTexture:gpu.tmpB[k] atIndex:0]; [e setTexture:gpu.average[k][1 - gpu.averageIndex] atIndex:1];
            [e setTexture:gpu.average[k][gpu.averageIndex] atIndex:2]; [e setTexture:gpu.stable[k] atIndex:3];
            [e setBytes:&temporal[k] length:sizeof temporal[k] atIndex:0];
            Dispatch(e, gpu.temporal, rig.width, rig.height);
        }
        [e endEncoding];
        [cb commit];
        [cb waitUntilCompleted];
        ok = cb.status == MTLCommandBufferStatusCompleted;
        output.gpuMs += float((cb.GPUEndTime - cb.GPUStartTime) * 1000);
        if (!ok) NSLog(@"Hand stereo: GPU work failed: %@", cb.error);
    }



    double handShare[2][2] = {};
    if (ok) {
        std::vector<uint8_t> mask(size_t(rig.width) * rig.height), keep;
        std::vector<int> stack;
        for (int k = 0; k < 2; ++k) {
            const MTLRegion all = MTLRegionMake2D(0, 0, NSUInteger(rig.width), NSUInteger(rig.height));
            [gpu.stable[k] getBytes:mask.data() bytesPerRow:NSUInteger(rig.width) fromRegion:all mipmapLevel:0];
            keep.assign(mask.size(), 0);
            for (int hand = 0; hand < 2; ++hand)
                for (const auto& j : plan.joints[k][hand]) {
                    const int jx = std::clamp(int(std::lround(j[0])), 0, rig.width - 1);
                    const int jy = std::clamp(int(std::lround(j[1])), 0, rig.height - 1);

                    for (int dy = -2; dy <= 2; ++dy)
                        for (int dx = -2; dx <= 2; ++dx) {
                            const int x = std::clamp(jx + dx, 0, rig.width - 1), y = std::clamp(jy + dy, 0, rig.height - 1);
                            const size_t i = size_t(y) * rig.width + x;
                            if (mask[i] > 127 && !keep[i]) { keep[i] = 255; stack.push_back(int(i)); }
                        }
                }
            while (!stack.empty()) {
                const int i = stack.back();
                stack.pop_back();
                const int x = i % rig.width, y = i / rig.width;
                const int next[4] = {x > 0 ? i - 1 : -1, x + 1 < rig.width ? i + 1 : -1, y > 0 ? i - rig.width : -1,
                                     y + 1 < rig.height ? i + rig.width : -1};
                for (int n : next)
                    if (n >= 0 && mask[size_t(n)] > 127 && !keep[size_t(n)]) { keep[size_t(n)] = 255; stack.push_back(n); }
            }
            [gpu.tmpB[k] replaceRegion:all mipmapLevel:0 withBytes:keep.data() bytesPerRow:NSUInteger(rig.width)];
            for (int hand = 0; hand < 2; ++hand) {
                const auto& joints = plan.joints[k][hand];
                if (joints.empty()) continue;
                int on = 0;
                for (const auto& j : joints) {
                    const int x = int(std::lround(j[0])), y = int(std::lround(j[1]));
                    if (x >= 0 && x < rig.width && y >= 0 && y < rig.height && keep[size_t(y) * rig.width + x]) ++on;
                }
                handShare[k][hand] = double(on) / joints.size();
                output.hand[k][hand] = handShare[k][hand] >= 1.0 / 3;
                output.jointsInView[k][hand] = int(joints.size());
                output.jointsOnMask[k][hand] = float(handShare[k][hand]);
            }
        }

        id<MTLCommandBuffer> cb = [gpu.queue commandBuffer];
        id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
        for (int k = 0; k < 2; ++k) {
            if (!output.hand[k][0] && !output.hand[k][1]) continue;
            const CutoutParams c{plan.color[k], float(rig.step), float(rig.width), float(rig.height)};
            [e setTexture:colors[k] atIndex:0]; [e setTexture:gpu.inverse[k] atIndex:1]; [e setTexture:gpu.tmpB[k] atIndex:2];
            [e setTexture:targets[k] atIndex:3]; [e setTexture:gpu.average[k][gpu.averageIndex] atIndex:4];
            [e setBytes:&c length:sizeof c atIndex:0];
            Dispatch(e, gpu.cutout, rig.colorWidth, rig.colorHeight);
        }
        [e endEncoding];
        [cb commit];
        [cb waitUntilCompleted];
        ok = cb.status == MTLCommandBufferStatusCompleted;
        output.gpuMs += float((cb.GPUEndTime - cb.GPUStartTime) * 1000);
        for (int k = 0; ok && k < 2; ++k)
            if (output.hand[k][0] || output.hand[k][1]) {
                output.cutout[k] = outs[k];
                outs[k] = nullptr;
            }
        if (!ok) for (auto& found : output.hand) found[0] = found[1] = false;

        gpu.averageIndex = 1 - gpu.averageIndex;
        std::memcpy(state.previousMean, mean, sizeof mean);
        std::memcpy(state.previousHand, have, sizeof have);
        state.previousNs = captureNs;
    }
    for (auto& h : holders) if (h) CFRelease(h);
    for (auto& o : outs) if (o) CVPixelBufferRelease(o);
    CVMetalTextureCacheFlush(gpu.cache, 0);
    output.workMs = float((static_cast<int64_t>(clock_gettime_nsec_np(CLOCK_MONOTONIC)) - began) / 1e6);
    output.zNear = plan.zNear;
    output.zFar = plan.zFar;
    return output;
}
}

void HandStereoConfigure(std::shared_ptr<const stereo::Rig> rig) {
    State& state = Shared();
    ++state.generation;
    state.configured = false;
    dispatch_async(state.queue, ^{
        @autoreleasepool {
            const bool ok = rig && SetUp(state.gpu, rig);
            if (!rig) state.gpu.rig.reset();
            state.configured = ok;
            if (rig) NSLog(@"Hand stereo: %s (rectified %dx%d, baseline %.1f mm)", ok ? "ready" : "unavailable",
                           rig->width, rig->height, rig->baseline * 1000);
        }
    });
}

bool HandStereoConfigured() { return Shared().configured.load(); }

void HandStereoSubmit(CVPixelBufferRef left, CVPixelBufferRef right, int64_t captureNs, const HandStereoInput& input) {
    State& state = Shared();
    if (!left || !right || !state.configured) return;
    if (static_cast<int64_t>(clock_gettime_nsec_np(CLOCK_MONOTONIC)) < state.nextAllowedNs.load()) return;
    if (state.busy.exchange(true)) return;
    CVPixelBufferRetain(left);
    CVPixelBufferRetain(right);
    const uint64_t generation = state.generation.load();
    auto work = std::make_shared<HandStereoInput>(input);
    dispatch_async(state.queue, ^{
        @autoreleasepool {
            HandMaskOutput output = Process(state, left, right, captureNs, *work);
            state.nextAllowedNs = static_cast<int64_t>(clock_gettime_nsec_np(CLOCK_MONOTONIC)) +
                                  static_cast<int64_t>(2.0 * output.gpuMs * 1e6);
            CVPixelBufferRelease(left);
            CVPixelBufferRelease(right);
            {
                std::lock_guard<std::mutex> lock(state.mutex);
                if (generation == state.generation.load()) {
                    Release(state.result);
                    state.result = output;
                    ++state.sequence;
                } else {
                    Release(output);
                }
            }
            state.busy = false;
        }
    });
}

bool HandStereoCopyLatest(uint64_t& sequence, HandMaskOutput& out) {
    State& state = Shared();
    std::lock_guard<std::mutex> lock(state.mutex);
    if (state.sequence == 0 || sequence == state.sequence) return false;
    sequence = state.sequence;
    out = state.result;
    for (auto& buffer : out.cutout)
        if (buffer) CVPixelBufferRetain(buffer);
    return true;
}

void HandStereoReset() {
    State& state = Shared();
    ++state.generation;
    dispatch_sync(state.queue, ^{});
    std::lock_guard<std::mutex> lock(state.mutex);
    Release(state.result);
    state.result = HandMaskOutput{};
    ++state.sequence;
}
