#pragma once
#include <cstddef>
#include <vector>

struct AddonCueProcessor {
    float history[2][98] = {};
    size_t cursor = 0;
    void reset();
    void process(float* stereo, size_t frames, float itdUs, float ildDb, float gain);
};

struct AddonSpatialConfig {
    enum Mode { Cues, Hrtf, HrtfHQ } mode = Cues;
    float x = 0, y = 0, z = -1;
    float itdUs = 0, ildDb = 0, gain = 1;
    float referenceDistance = 1, rolloff = 1;
};

class AddonSpatialAudio {
public:
    AddonSpatialAudio();
    ~AddonSpatialAudio();
    void reset();
    bool render(const float* mono, size_t frames, const AddonSpatialConfig& config, std::vector<float>& stereo);
private:
    struct Impl;
    Impl* impl;
};
