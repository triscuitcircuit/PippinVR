#include "AddonSpatialAudio.h"
#include <cmath>
#include <cstdio>
#include <vector>
#include <cstdlib>

static void require(bool condition, const char* message) { if (!condition) { std::fprintf(stderr, "FAIL: %s\n", message); std::exit(1); } }
int main() {
    AddonSpatialAudio audio;
    AddonSpatialConfig cfg;
    std::vector<float> input(480), out;
    input[479] = 1;
    cfg.itdUs = 1000.0f;
    cfg.ildDb = 6.0f;
    require(audio.render(input.data(), input.size(), cfg, out), "cue render");
    require(std::abs(out[479 * 2 + 1] - std::pow(10.0f, -6.0f / 20.0f)) < 0.00001f, "right attenuation");
    require(out[479 * 2] == 0, "left delayed");
    std::fill(input.begin(), input.end(), 0);
    require(audio.render(input.data(), input.size(), cfg, out), "next chunk");
    require(std::abs(out[47 * 2] - 1) < 0.00001f, "delay crosses chunks");
    audio.reset();
    cfg.itdUs = -10.4166667f; cfg.ildDb = -6;
    input[0] = 1;
    require(audio.render(input.data(), input.size(), cfg, out), "fractional cue");
    require(std::abs(out[0] - std::pow(10.0f, -6.0f / 20.0f)) < 0.00001f, "left attenuation");
    require(std::abs(out[1] - 0.5f) < 0.0001f && std::abs(out[3] - 0.5f) < 0.0001f, "fractional right delay");
    audio.reset(); cfg = {}; cfg.mode = AddonSpatialConfig::Hrtf; cfg.x = 1; cfg.z = -1;
    input.assign(1920, 0); input[0] = 0.1f;
    require(audio.render(input.data(), input.size(), cfg, out), "HRTF render");
    float energy = 0, difference = 0;
    for (size_t i = 0; i < input.size(); ++i) { energy += std::abs(out[i*2]) + std::abs(out[i*2+1]); difference += std::abs(out[i*2] - out[i*2+1]); }
    require(energy > 0.0001f && difference > 0.0001f, "HRTF produces binaural signal");
    audio.reset(); cfg.mode = AddonSpatialConfig::HrtfHQ;
    require(audio.render(input.data(), input.size(), cfg, out), "HRTF HQ render");
    energy = 0;
    for (float sample : out) energy += std::abs(sample);
    require(energy > 0.0001f, "HRTF HQ produces audio");
    audio.reset(); cfg = {}; cfg.mode = AddonSpatialConfig::HrtfHQ; cfg.z = -4; cfg.rolloff = 0;
    require(audio.render(input.data(), input.size(), cfg, out), "HRTF no distance attenuation");
    float unattenuated = 0;
    for (float sample : out) unattenuated += std::abs(sample);
    audio.reset(); cfg.rolloff = 1;
    require(audio.render(input.data(), input.size(), cfg, out), "HRTF distance attenuation");
    float distant = 0;
    for (float sample : out) distant += std::abs(sample);
    require(unattenuated > 0.0001f && std::abs(distant / unattenuated - 0.25f) < 0.01f, "four-meter inverse gain");
    audio.reset(); cfg.mode = AddonSpatialConfig::Cues; cfg.z = -4; cfg.rolloff = 1;
    require(audio.render(input.data(), input.size(), cfg, out) && std::abs(out[0] - input[0]) < 0.00001f, "cues ignore distance");
    puts("PASS: cue delay, levels, HRTF, HQ and distance attenuation");
}
