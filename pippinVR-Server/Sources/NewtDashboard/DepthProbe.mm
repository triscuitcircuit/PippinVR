// SPDX-License-Identifier: MIT


#include "NewtXRApp.h"
#include "include/NewtLog.h"
#include "HandOcclusion.h"
#include <algorithm>
#include <cstdlib>
#include <ctime>
#include <cstring>

namespace {
bool ProbeEnabled() {
    static const bool enabled = [] { const char* v = std::getenv("QL_FLOAT_PROBE"); return v && std::strcmp(v, "1") == 0; }();
    return enabled;
}
double ProbeSeconds() {
    const char* v = std::getenv("QL_FLOAT_PROBE_SECONDS");
    const double s = v ? std::atof(v) : 90;
    return s > 0 ? s : 90;
}
Vec3 Apply(const Mat4& m, const Vec3& p) {
    return {m.m[0] * p.x + m.m[4] * p.y + m.m[8] * p.z + m.m[12], m.m[1] * p.x + m.m[5] * p.y + m.m[9] * p.z + m.m[13],
            m.m[2] * p.x + m.m[6] * p.y + m.m[10] * p.z + m.m[14]};
}
double Median(std::vector<double> v) {
    if (v.empty()) return NAN;
    std::nth_element(v.begin(), v.begin() + v.size() / 2, v.end());
    return v[v.size() / 2];
}
}

void NewtXR::ProbeFloatDepth() {
    if (!ProbeEnabled() || mFloatProbeDone || !mCopyFloat || !EnsurePassthroughCalibration() || !mHeadPoseAt ||
        !mHandJointsAt) return;
    const int64_t now = static_cast<int64_t>(clock_gettime_nsec_np(CLOCK_MONOTONIC));
    if (now - mFloatProbeLastNs < 500000000LL) return;
    if (mFloatProbeStartNs && now - mFloatProbeStartNs > int64_t(ProbeSeconds() * 1e9)) {
        mFloatProbeDone = true;
        Newt_Logf(NEWT_LOG_INFO, "DEPTH_PROBE finished");
        return;
    }
    for (int eye = 0; eye < 2; ++eye) {
        std::vector<float> grid(512 * 512);
        int width = 0, height = 0;
        int64_t captureNs = 0;
        if (!mCopyFloat(eye, &mFloatProbeSeq[eye], grid.data(), int(grid.size()), &width, &height, &captureNs)) continue;
        mFloatProbeLastNs = now;
        if (!mFloatProbeStartNs) {
            mFloatProbeStartNs = now;
            Newt_Logf(NEWT_LOG_INFO, "DEPTH_PROBE started: float grid %dx%d vs tracked hand joints (summary numbers only)",
                      width, height);
        }
        float head[7];
        if (!mHeadPoseAt(captureNs, head)) {
            Newt_Logf(NEWT_LOG_INFO, "DEPTH_PROBE eye %d: no head pose at the float capture time", eye);
            continue;
        }
        const XrPosef headPose{{head[3], head[4], head[5], head[6]}, {head[0], head[1], head[2]}};
        const PassthroughCamera& c = mPassthroughCameras[eye];
        const LensModel model = LensModelOf(c);
        const Mat4 cameraFromWorld = Multiply(CameraFromHead(c), PoseMatrix(InversePose(headPose)));
        struct Sample { double u, v, range, z; };
        std::vector<Sample> samples;
        for (int hand = 0; hand < 2; ++hand) {
            float raw[XR_HAND_JOINT_COUNT_EXT * 7];
            if (!mHandJointsAt(hand, captureNs, raw)) continue;
            for (int j = 0; j < XR_HAND_JOINT_COUNT_EXT; ++j) {
                const Vec3 p = Apply(cameraFromWorld, {raw[j * 7], raw[j * 7 + 1], raw[j * 7 + 2]});
                double px, py;
                if (p.z < 0.05f || !LensProject(c, model, p.x, p.y, p.z, px, py)) continue;
                const double u = px / c.width, v = py / c.height;
                if (u < 0 || u >= 1 || v < 0 || v >= 1) continue;
                samples.push_back({u, v, std::sqrt(double(p.x) * p.x + double(p.y) * p.y + double(p.z) * p.z), p.z});
            }
        }
        if (samples.size() < 6) {
            Newt_Logf(NEWT_LOG_INFO, "DEPTH_PROBE eye %d: %zu hand joints in view (need 6; put the controllers down, "
                      "hands in front)", eye, samples.size());
            continue;
        }

        char line[1024];
        int used = std::snprintf(line, sizeof(line), "DEPTH_PROBE eye %d: %zu joints %.2f-%.2f m |", eye, samples.size(),
                                 std::min_element(samples.begin(), samples.end(), [](auto& a, auto& b) { return a.range < b.range; })->range,
                                 std::max_element(samples.begin(), samples.end(), [](auto& a, auto& b) { return a.range < b.range; })->range);
        int best = -1;
        double bestSpread = 1e9;
        for (int o = 0; o < 8; ++o) {
            std::vector<double> ratio, spread;
            double sx = 0, sy = 0, sxx = 0, syy = 0, sxy = 0;
            for (const auto& s : samples) {
                double u = s.u, v = s.v;
                if (o & 4) std::swap(u, v);
                if (o & 1) u = 1 - u;
                if (o & 2) v = 1 - v;
                const int x = std::clamp(int(std::lround(u * (width - 1))), 0, width - 1);
                const int y = std::clamp(int(std::lround(v * (height - 1))), 0, height - 1);
                const double value = grid[size_t(y) * width + x];
                if (!(value > 0)) continue;
                ratio.push_back((1.0 / value) / s.range);
                const double a = value, b = 1.0 / s.range;
                sx += a; sy += b; sxx += a * a; syy += b * b; sxy += a * b;
            }
            const double n = double(ratio.size());
            const double med = Median(ratio);
            for (double r : ratio) spread.push_back(std::fabs(std::log(r / med)));
            const double spr = Median(spread);
            const double cov = sxy / n - sx / n * sy / n;
            const double corr = cov / std::sqrt(std::max(1e-12, (sxx / n - sx * sx / n / n) * (syy / n - sy * sy / n / n)));
            used += std::snprintf(line + used, sizeof(line) - used, " o%d r%.2f s%.2f c%.2f", o, med, spr, corr);
            if (n >= 6 && spr < bestSpread) { bestSpread = spr; best = o; }
        }
        Newt_Logf(NEWT_LOG_INFO, "%s | best o%d", line, best);



        double farthest = 0, ju = 0, jv = 0, ju0 = 1, ju1 = 0, jv0 = 1, jv1 = 0;
        std::vector<double> ranges;
        for (const auto& s : samples) {
            farthest = std::max(farthest, s.range);
            ju += s.u / samples.size(); jv += s.v / samples.size();
            ju0 = std::min(ju0, s.u); ju1 = std::max(ju1, s.u); jv0 = std::min(jv0, s.v); jv1 = std::max(jv1, s.v);
            ranges.push_back(s.range);
        }
        const double threshold = 1.0 / (farthest + 0.15);
        double bu = 0, bv = 0, bu0 = 1, bu1 = 0, bv0 = 1, bv1 = 0;
        std::vector<double> blob;
        for (int y = 0; y < height; ++y)
            for (int x = 0; x < width; ++x) {
                const double value = grid[size_t(y) * width + x];
                if (!(value > threshold)) continue;
                const double u = double(x) / (width - 1), v = double(y) / (height - 1);
                bu += u; bv += v; blob.push_back(1.0 / value);
                bu0 = std::min(bu0, u); bu1 = std::max(bu1, u); bv0 = std::min(bv0, v); bv1 = std::max(bv1, v);
            }
        if (!blob.empty()) { bu /= blob.size(); bv /= blob.size(); }
        Newt_Logf(NEWT_LOG_INFO, "DEPTH_REG eye %d: joints c(%.3f %.3f) box(%.3f-%.3f %.3f-%.3f) med %.2f m | near<%.2f m: "
                  "%zu cells c(%.3f %.3f) box(%.3f-%.3f %.3f-%.3f) med %.2f m",
                  eye, ju, jv, ju0, ju1, jv0, jv1, Median(ranges), 1.0 / threshold, blob.size(), bu, bv, bu0, bu1, bv0,
                  bv1, Median(blob));
    }
}
