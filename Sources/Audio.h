#pragma once
#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdint>
#include <numeric>
#include <vector>
#include <ranges>
#include <span>

struct Channel {
    const float *samples;
    uint32_t stride;
    uint32_t frames;
};

inline float copyChannel(Channel input, float *output, uint32_t stride, uint32_t frames) {
    if (!input.samples || !output || stride == 0 || input.stride == 0) return 0;
    const auto count = std::min(input.frames, frames);
    const auto positions = std::views::iota(uint32_t{0}, count);
    std::ranges::for_each(positions, [=](const auto i) {
        output[i * stride] = std::isfinite(input.samples[i * input.stride]) ? input.samples[i * input.stride] : 0;
    });
    return std::transform_reduce(positions.begin(), positions.end(), 0.0f,
        [](float a, float b) { return std::max(a, b); },
        [=](const auto i) { return std::abs(output[i * stride]); });
}

struct AudioStats {
    std::atomic<uint64_t> callbacks{0};
    std::atomic<uint64_t> verifiedFrames{0};
    std::atomic<float> inputPeak{0};
    std::atomic<float> leftPeak{0};
    std::atomic<float> rightPeak{0};
    std::atomic<float> difference{0};
};
