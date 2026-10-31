#include "AudioSamples.h"
#include "ql_audio_buffer.h"

#include <cassert>
#include <cstdio>
#include <deque>
#include <limits>
#include <random>

int main() {
    const float left[] = {1, 2, 3}, right[] = {4, 5, 6}, stereo[] = {1, 4, 2, 5, 3, 6};
    std::vector<float> a, b;
    assert(systemaudio::CopyStereo(left, sizeof(left), right, sizeof(right), 3, 1, a, b));
    assert((a == std::vector<float>{1, 2, 3}) && (b == std::vector<float>{4, 5, 6}));
    assert(systemaudio::CopyStereo(stereo, sizeof(stereo), stereo + 1,
                                   sizeof(stereo) - sizeof(float), 3, 2, a, b));
    assert((a == std::vector<float>{1, 2, 3}) && (b == std::vector<float>{4, 5, 6}));
    assert(!systemaudio::CopyStereo(left, sizeof(left), right, sizeof(float), 3, 1, a, b));
    assert(!systemaudio::CopyStereo(left, sizeof(left), nullptr, 0, 3, 1, a, b));
    assert(!systemaudio::CopyStereo(left, sizeof(left), right, sizeof(right), 3, 0, a, b));
    assert(!systemaudio::CopyStereo(left, sizeof(left), right, sizeof(right),
                                    std::numeric_limits<size_t>::max(), 2, a, b));
    assert(systemaudio::CopyStereo(left, sizeof(left), left, sizeof(left), 3, 1, a, b) && a == b);

    float mix[] = {0.5f, -0.5f, 0.9f, -0.9f};
    const float other[] = {0.1f, -0.1f, 0.8f, -0.8f};
    QlMixStereo(mix, other, 2);
    assert(mix[0] > 0.59f && mix[0] < 0.61f && mix[1] < -0.59f && mix[1] > -0.61f);
    assert(mix[2] == 1.0f && mix[3] == -1.0f);

    QlAudioBuffer<17> ring;
    std::deque<float> expected;
    std::mt19937 random(42);
    float output[34];
    assert(!ring.push(nullptr, 1) && ring.push(nullptr, 0));
    assert(!ring.pop(output, 1) && ring.pop(nullptr, 0));
    for (int step = 0; step < 10000; ++step) {
        if (step % 101 == 0) {
            ring.clear();
            expected.clear();
        }
        const size_t frames = random() % 60;
        std::vector<float> input(frames * 2);
        for (size_t i = 0; i < input.size(); ++i)
            input[i] = float(step * 120 + i);
        assert(ring.push(input.data(), frames));
        expected.insert(expected.end(), input.begin(), input.end());
        while (expected.size() > 34)
            expected.pop_front();
        assert(ring.size() * 2 == expected.size());
        const size_t take = random() % 18;
        const bool available = take <= ring.size();
        assert(ring.pop(output, take) == available);
        if (available)
            for (size_t i = 0; i < take * 2; ++i) {
                assert(output[i] == expected.front());
                expected.pop_front();
            }
    }
    puts(
        "PASS: stereo/mono conversion, truncated right channel, overflow-safe bounds, audio ring "
        "wrap/overflow/reset");
}
