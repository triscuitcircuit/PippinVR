#include "HandStereo.h"
#include "hand_stereo_synth.h"
#include <cstdio>
#include <unistd.h>
#include <chrono>
using namespace stereo;

static double Hash(int x, int y, int z) { uint32_t h = x * 374761393u + y * 668265263u + z * 2147483647u; h = (h ^ (h >> 13)) * 1274126177u; return (h & 0xffff) / 65535.0; }
static double Noise(V3 p) {
    const double s = 120; double x = p[0] * s, y = p[1] * s, z = p[2] * s;
    int ix = int(std::floor(x)), iy = int(std::floor(y)), iz = int(std::floor(z)); double fx = x - ix, fy = y - iy, fz = z - iz;
    double r = 0;
    for (int a = 0; a < 2; ++a) for (int b = 0; b < 2; ++b) for (int c = 0; c < 2; ++c)
        r += Hash(ix + a, iy + b, iz + c) * (a ? fx : 1 - fx) * (b ? fy : 1 - fy) * (c ? fz : 1 - fz);
    return r;
}

static V3 kBall{0.03, -0.12, -0.40}; static double kRadius = 0.06; static const double kWall = 1.5;

static double kFingerX = 0.13, kFingerZ = -0.38;
static const double kFingerR = 0.009, kFingerTop = -0.03, kFingerBottom = -0.17;


static bool Trace(V3 o, V3 d, V3& hit, int& what) {
    double best = 1e9;
    what = 0;
    const V3 oc{o[0] - kBall[0], o[1] - kBall[1], o[2] - kBall[2]};
    const double b = Dot(oc, d), c = Dot(oc, oc) - kRadius * kRadius, disc = b * b - c;
    if (disc > 0) { const double t = -b - std::sqrt(disc); if (t > 0) { best = t; what = 1; } }

    const double px = o[0] - kFingerX, pz = o[2] - kFingerZ, A = d[0] * d[0] + d[2] * d[2];
    const double B = px * d[0] + pz * d[2], C = px * px + pz * pz - kFingerR * kFingerR, D = B * B - A * C;
    if (A > 1e-12 && D > 0) {
        const double t = (-B - std::sqrt(D)) / A, y = o[1] + t * d[1];
        if (t > 0 && t < best && y < kFingerTop && y > kFingerBottom) { best = t; what = 2; }
    }
    if (what == 0) {
        if (d[2] >= -1e-6) return false;
        best = (-kWall - o[2]) / d[2];
    }
    hit = {o[0] + best * d[0], o[1] + best * d[1], o[2] + best * d[2]};
    return true;
}
static CVPixelBufferRef Render(const PassthroughCamera& cam, std::vector<uint8_t>& truth) {
    CVPixelBufferRef p = nullptr;
    NSDictionary* a = @{(id)kCVPixelBufferIOSurfacePropertiesKey:@{}, (id)kCVPixelBufferMetalCompatibilityKey:@YES};
    CVPixelBufferCreate(kCFAllocatorDefault, cam.width, cam.height, kCVPixelFormatType_32BGRA, (__bridge CFDictionaryRef)a, &p);
    CVPixelBufferLockBaseAddress(p, 0);
    uint8_t* base = (uint8_t*)CVPixelBufferGetBaseAddress(p); const size_t row = CVPixelBufferGetBytesPerRow(p);
    M3 hc; V3 cc; HeadFromCamera(cam, hc, cc); const LensModel m = LensModelOf(cam);
    truth.assign(size_t(cam.width) * cam.height, 0);
    for (int y = 0; y < cam.height; ++y) for (int x = 0; x < cam.width; ++x) {
        double ra, rb; uint8_t v = 0;
        if (Unproject(cam, m, x + 0.5, y + 0.5, ra, rb)) {
            const V3 dir = Normalize(Mul(hc, V3{ra, rb, 1})); V3 hit; int what;
            if (Trace(cc, dir, hit, what)) { v = uint8_t(40 + 180 * Noise(hit)); truth[size_t(y) * cam.width + x] = uint8_t(what); }
        }

        const uint8_t t = truth[size_t(y) * cam.width + x];
        uint8_t* px = base + y * row + x * 4;
        if (t) { px[0] = uint8_t(v * 0.55); px[1] = uint8_t(v * 0.72); px[2] = v; }
        else { px[0] = v; px[1] = uint8_t(v * 0.85); px[2] = uint8_t(v * 0.75); }
        px[3] = 255;
    }
    CVPixelBufferUnlockBaseAddress(p, 0);
    return p;
}
int main() {
    @autoreleasepool {
        PassthroughCamera L = SynthCamera(-0.032, 1.5), R = SynthCamera(0.032, -1.0);
        for (auto* c : {&L, &R}) { c->width = 1164; c->height = 874; c->projection[0] = 450; c->projection[1] = 582 + 3; c->projection[2] = 437 - 2; }
        auto rig = BuildRig(L, R);
        HandStereoConfigure(rig);
        for (int i = 0; i < 200 && !HandStereoConfigured(); ++i) usleep(10000);
        if (!HandStereoConfigured()) { puts("FAIL: not configured"); return 1; }
        int failures = 0;
        for (int scene = 0; scene < 2; ++scene) {
        if (scene == 1) { kBall = {0.03, -0.10, -0.22}; kRadius = 0.04; kFingerX = 0.12; kFingerZ = -0.24; }
        printf("scene %d: ball %.0f cm, finger %.0f cm from the head\n", scene, -kBall[2] * 100, -kFingerZ * 100);
        std::vector<uint8_t> truthL, truthR;
        CVPixelBufferRef left = Render(L, truthL), right = Render(R, truthR);
        HandStereoInput input;
        for (double dx : {-0.02, 0.0, 0.02}) for (double dy : {-0.02, 0.0, 0.02})
            input.joints[1].push_back({kBall[0] + dx, kBall[1] + dy, kBall[2] + 0.01});
        for (double y = kFingerTop - 0.01; y > kFingerBottom; y -= 0.02) input.joints[1].push_back({kFingerX, y, kFingerZ});


        uint64_t seq = 0; HandMaskOutput out;
        auto submitAndWait = [&](int64_t capture, HandMaskOutput& result) {
            for (int attempt = 0; attempt < 50; ++attempt) {
                HandStereoSubmit(left, right, capture, input);
                for (int w = 0; w < 100; ++w) {
                    HandMaskOutput o;
                    if (HandStereoCopyLatest(seq, o)) {
                        if (o.captureNs == capture) { result = o; return true; }
                        for (auto c : o.cutout) if (c) CVPixelBufferRelease(c);
                    }
                    usleep(1000);
                }
            }
            return false;
        };
        if (!submitAndWait(42 + scene, out)) { puts("FAIL: no result"); return 1; }
        printf("GPU %.2f ms for the first pair\n", out.gpuMs);
        printf("capture %lld found L%d R%d cutouts %p %p\n", (long long)out.captureNs, out.hand[0][1], out.hand[1][1], (void*)out.cutout[0], (void*)out.cutout[1]);
        for (int k = 0; k < 2; ++k) {
            if (!out.cutout[k]) { printf("camera %d: no cutout\n", k); ++failures; continue; }
            const auto& truth = k ? truthR : truthL;
            CVPixelBufferRef c = out.cutout[k]; CVPixelBufferLockBaseAddress(c, kCVPixelBufferLock_ReadOnly);
            const uint8_t* b = (const uint8_t*)CVPixelBufferGetBaseAddress(c); const size_t row = CVPixelBufferGetBytesPerRow(c);
            size_t ballN = 0, ballHit = 0, bgN = 0, bgHit = 0, fingerN = 0, fingerHit = 0;
            for (int y = 0; y < L.height; ++y) for (int x = 0; x < L.width; ++x) {
                const uint8_t* px = b + y * row + x * 4; const bool on = px[3] > 127;
                const uint8_t t = truth[size_t(y) * L.width + x];
                if (t == 1) { ++ballN; ballHit += on; } else if (t == 2) { ++fingerN; fingerHit += on; } else { ++bgN; bgHit += on; }
            }
            CVPixelBufferUnlockBaseAddress(c, kCVPixelBufferLock_ReadOnly);
            printf("camera %d: ball pixels kept %.1f%% (%zu), finger kept %.1f%% (%zu), background shown %.3f%% (%zu px)\n", k,
                   100.0 * ballHit / ballN, ballN, 100.0 * fingerHit / fingerN, fingerN, 100.0 * bgHit / bgN, bgHit);
            if (ballHit < 0.85 * ballN || fingerHit < 0.6 * fingerN || bgHit > 0.01 * bgN) ++failures;
        }
        for (auto c : out.cutout) if (c) CVPixelBufferRelease(c);

        auto t0 = std::chrono::steady_clock::now();
        for (int i = 0; i < 20; ++i) {
            HandMaskOutput o;
            submitAndWait(100 + scene * 100 + i, o);
            for (auto c : o.cutout) if (c) CVPixelBufferRelease(c);
        }
        printf("steady state: %.1f ms per pair\n", std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - t0).count() / 20);
        CVPixelBufferRelease(left); CVPixelBufferRelease(right);
        }
        HandStereoReset();
        puts(failures ? "FAIL" : "PASS: stereo pipeline keeps the near object and drops the background");
        return failures ? 1 : 0;
    }
}
