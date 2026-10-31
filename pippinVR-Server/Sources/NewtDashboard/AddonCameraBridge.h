#pragma once
#include <CoreVideo/CoreVideo.h>
#include <stdint.h>
void StartAddonCameraBridge();
void StopAddonCameraBridge();
void SubmitAddonCameraFrames(CVPixelBufferRef left, CVPixelBufferRef right, int64_t captureNs);
