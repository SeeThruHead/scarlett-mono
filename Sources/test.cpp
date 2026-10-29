#include "Audio.h"
#include <array>
#include <cassert>
#include <iostream>
#include <limits>

int main() {
    const std::array<float, 8> input{0.25, -0.8, 0.5, 0.9, -0.75, 1, 0.125, -1};
    std::array<float, 8> output{};
    const Channel source{input.data(), 2, 4};
    assert(copyChannel(source, output.data(), 2, 4) == 0.75f);
    copyChannel(source, output.data() + 1, 2, 4);
    assert((output == std::array<float, 8>{0.25, 0.25, 0.5, 0.5, -0.75, -0.75, 0.125, 0.125}));
    std::array<float, 2> shortOutput{};
    copyChannel(source, shortOutput.data(), 1, 2);
    assert((shortOutput == std::array<float, 2>{0.25, 0.5}));
    const std::array<float, 3> corrupt{std::numeric_limits<float>::infinity(), std::numeric_limits<float>::quiet_NaN(), -0.5};
    std::array<float, 3> cleaned{};
    copyChannel({corrupt.data(), 1, 3}, cleaned.data(), 1, 3);
    assert((cleaned == std::array<float, 3>{0, 0, -0.5}));
    assert(copyChannel({nullptr, 0, 0}, cleaned.data(), 1, 3) == 0);
    assert(copyChannel(source, nullptr, 1, 3) == 0);
    std::cout << "PASS: selected channel, equal left/right, unchanged gain, bounded copy, nonfinite samples, missing input\n";
}
