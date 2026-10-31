#include "AddonSpatialAudio.h"
#import <AVFoundation/AVFoundation.h>
#include <algorithm>
#include <cmath>
#include <cstring>

void AddonCueProcessor::reset() { std::memset(history, 0, sizeof(history)); cursor = 0; }
void AddonCueProcessor::process(float* stereo, size_t frames, float itdUs, float ildDb, float gain) {
    const float delay[2] = {std::max(0.0f, itdUs) * 0.048f, std::max(0.0f, -itdUs) * 0.048f};
    const float level[2] = {gain * std::pow(10.0f, std::min(0.0f, ildDb) / 20.0f),
                            gain * std::pow(10.0f, -std::max(0.0f, ildDb) / 20.0f)};
    for (size_t i = 0; i < frames; ++i) {
        for (int ear = 0; ear < 2; ++ear) {
            history[ear][cursor] = stereo[i * 2 + ear];
            size_t whole = size_t(delay[ear]);
            float fraction = delay[ear] - whole;
            float a = history[ear][(cursor + 98 - whole) % 98];
            float b = history[ear][(cursor + 97 - whole) % 98];
            stereo[i * 2 + ear] = (a + (b - a) * fraction) * level[ear];
        }
        cursor = (cursor + 1) % 98;
    }
}

struct AddonSpatialAudio::Impl {
    AVAudioEngine* engine = nil;
    AVAudioEnvironmentNode* environment = nil;
    AVAudioSourceNode* source = nil;
    AVAudioPCMBuffer* rendered = nil;
    const float* input = nullptr;
    size_t inputOffset = 0, inputFrames = 0;
    AddonCueProcessor cues;
    float distanceGain = 1;
    bool distanceGainInitialized = false;
    bool ensureEngine() {
        if (engine) return true;
        AVAudioEngine* e = [[AVAudioEngine alloc] init];
        AVAudioFormat* stereo = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:2];
        AVAudioFormat* mono = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:48000 channels:1];
        NSError* error = nil;
        if (![e enableManualRenderingMode:AVAudioEngineManualRenderingModeOffline format:stereo maximumFrameCount:480 error:&error]) return false;
        AVAudioEnvironmentNode* env = [[AVAudioEnvironmentNode alloc] init];
        [e attachNode:env];
        env.distanceAttenuationParameters.rolloffFactor = 0;
        env.reverbParameters.enable = NO;
        if (@available(macOS 13.0, *)) env.outputType = AVAudioEnvironmentOutputTypeHeadphones;
        Impl* state = this;
        AVAudioSourceNode* src = [[AVAudioSourceNode alloc] initWithFormat:mono renderBlock:^OSStatus(BOOL* silence, const AudioTimeStamp*, AVAudioFrameCount count, AudioBufferList* out) {
            float* dst = static_cast<float*>(out->mBuffers[0].mData);
            if (!state->input) { std::fill(dst, dst + count, 0); *silence = YES; }
            else {
                size_t available = state->inputFrames - std::min(state->inputOffset, state->inputFrames);
                size_t n = std::min<size_t>(count, available);
                std::memcpy(dst, state->input + state->inputOffset, n * sizeof(float));
                std::fill(dst + n, dst + count, 0); state->inputOffset += n; *silence = n == 0;
            }
            return noErr;
        }];
        [e attachNode:src];
        [e connect:src to:env format:mono];
        [e connect:env to:e.mainMixerNode format:stereo];
        if (![e startAndReturnError:&error]) return false;
        engine = e; environment = env; source = src;
        rendered = [[AVAudioPCMBuffer alloc] initWithPCMFormat:e.manualRenderingFormat frameCapacity:480];
        return rendered != nil;
    }
    void reset() { if (engine) [engine stop]; engine = nil; environment = nil; source = nil; rendered = nil; input = nullptr; cues.reset(); distanceGain = 1; distanceGainInitialized = false; }
};
AddonSpatialAudio::AddonSpatialAudio() : impl(new Impl) {}
AddonSpatialAudio::~AddonSpatialAudio() { impl->reset(); delete impl; }
void AddonSpatialAudio::reset() { impl->reset(); }
bool AddonSpatialAudio::render(const float* mono, size_t frames, const AddonSpatialConfig& config, std::vector<float>& stereo) {
    stereo.resize(frames * 2);
    if (config.mode == AddonSpatialConfig::Cues) {
        for (size_t i = 0; i < frames; ++i) stereo[i * 2] = stereo[i * 2 + 1] = mono[i];
    } else {
        if (!impl->ensureEngine()) return false;
        impl->source.renderingAlgorithm = config.mode == AddonSpatialConfig::HrtfHQ ? AVAudio3DMixingRenderingAlgorithmHRTFHQ : AVAudio3DMixingRenderingAlgorithmHRTF;
        if (@available(macOS 13.0, *)) impl->source.sourceMode = AVAudio3DMixingSourceModePointSource;
        impl->source.position = AVAudioMake3DPoint(config.x, config.y, config.z);
        impl->input = mono; impl->inputOffset = 0; impl->inputFrames = frames;
        for (size_t i = 0; i < frames; i += 480) {
            NSError* error = nil;
            if ([impl->engine renderOffline:480 toBuffer:impl->rendered error:&error] != AVAudioEngineManualRenderingStatusSuccess || impl->rendered.frameLength != 480) { impl->input = nullptr; return false; }
            const float* const* output = impl->rendered.floatChannelData;
            for (size_t j = 0; j < 480; ++j) { stereo[(i+j)*2] = output[0][j]; stereo[(i+j)*2+1] = output[1][j]; }
        }
        impl->input = nullptr;
        const float distance = std::sqrt(config.x * config.x + config.y * config.y + config.z * config.z);
        const float target = config.referenceDistance / (config.referenceDistance + config.rolloff * std::max(0.0f, distance - config.referenceDistance));
        if (!impl->distanceGainInitialized) { impl->distanceGain = target; impl->distanceGainInitialized = true; }
        const size_t ramp = std::min<size_t>(frames, 480);
        const float start = impl->distanceGain;
        for (size_t i = 0; i < frames; ++i) {
            const float mix = std::min(1.0f, float(i + 1) / float(ramp));
            const float volume = start + (target - start) * mix;
            stereo[i * 2] *= volume; stereo[i * 2 + 1] *= volume;
        }
        impl->distanceGain = target;
    }
    impl->cues.process(stereo.data(), frames, config.itdUs, config.ildDb, config.gain);
    return true;
}
