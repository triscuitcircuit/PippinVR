#pragma once
// SPDX-License-Identifier: MIT

#include <cstdint>

void LoadMetalFXSettings();
void SetMetalFXScale(float scale);
float MetalFXScale();
void SetMetalFXUpscaleEnabled(bool enabled);
bool MetalFXUpscaleEnabled();
bool MetalFXUpscaleActive();
void GetMetalFXDimensions(uint32_t& inputWidth, uint32_t& inputHeight,
                          uint32_t& outputWidth, uint32_t& outputHeight);
