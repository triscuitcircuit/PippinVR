#pragma once
// SPDX-License-Identifier: MIT
#include <CoreVideo/CoreVideo.h>
#include <cstdint>
#include <string>

bool HandBenchmarkEnabled();
void HandBenchmarkStart(bool cameraAllowed);
bool HandBenchmarkNeedsFrames();

void HandBenchmarkSubmit(CVPixelBufferRef left, CVPixelBufferRef right, int64_t captureNs);
void HandBenchmarkTick();
void HandBenchmarkRenderFrame(bool shouldRender);
void HandBenchmarkStop();


bool HandBenchmarkCopyPreview(uint64_t& sequence, CVPixelBufferRef& left, CVPixelBufferRef& right,
                              std::string& status);
