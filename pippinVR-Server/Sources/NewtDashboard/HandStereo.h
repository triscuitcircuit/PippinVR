#pragma once
// SPDX-License-Identifier: MIT




#include <CoreVideo/CoreVideo.h>
#include <cstdint>
#include <memory>
#include <vector>
#include "HandMask.h"
#include "HandStereoMath.h"


void HandStereoConfigure(std::shared_ptr<const stereo::Rig> rig);
bool HandStereoConfigured();

struct HandStereoInput {


    std::vector<stereo::V3> joints[2];
};

void HandStereoSubmit(CVPixelBufferRef left, CVPixelBufferRef right, int64_t captureNs, const HandStereoInput& input);
bool HandStereoCopyLatest(uint64_t& sequence, HandMaskOutput& out);
void HandStereoReset();
