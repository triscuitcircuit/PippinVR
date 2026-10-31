#pragma once
// SPDX-License-Identifier: MIT


#include "Newt/MathTypes.h"
#include <cstdint>
#include <memory>
#include <vector>

namespace systemaudio {
enum Mode : int { Off = 0, Stereo = 1, Hrtf = 2, HrtfHQ = 3 };
inline int NextMode(int mode) { return (mode + 1) % 4; }

struct Settings {
    int mode = Stereo;
    bool macSpeakers = false;
};
Settings Load();
void Save(const Settings& settings);


struct Screen {
    uint32_t display = 0;
    XrPosef pose;
    float width = 0, height = 0;
};
}

class SystemAudio {
public:
    using Submit = bool (*)(const float* interleaved, uint32_t frames);
    explicit SystemAudio(Submit submit);
    ~SystemAudio();
    void Apply(const systemaudio::Settings& settings);


    void SetScene(const XrPosef& head, std::vector<systemaudio::Screen> screens, const Vec3& left, const Vec3& right);

private:
    struct Impl;
    std::unique_ptr<Impl> mImpl;
};
