#pragma once
// SPDX-License-Identifier: MIT



#include <CoreVideo/CoreVideo.h>
#include <cstdint>
#include <vector>
#include "HandMaskMath.h"

struct HandMaskInput {


    std::vector<std::vector<HandMask::Point>> hands[2];
};


void HandMaskSubmit(CVPixelBufferRef left, CVPixelBufferRef right, int64_t captureNs, const HandMaskInput& input);

struct HandMaskOutput {
    CVPixelBufferRef cutout[2] = {};
    bool hand[2][2] = {};
    int64_t captureNs = 0;


    int jointsInView[2][2] = {};
    float jointsOnMask[2][2] = {{-1, -1}, {-1, -1}};
    float workMs = 0, gpuMs = 0, zNear = 0, zFar = 0;
};

bool HandMaskCopyLatest(uint64_t& sequence, HandMaskOutput& out);

void HandMaskReset();
