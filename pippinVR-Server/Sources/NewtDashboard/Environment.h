#ifndef NEWT_ENVIRONMENT_H
#define NEWT_ENVIRONMENT_H
#include "Newt/PixelImage.h"
#include <string>

PixelImage LoadImageFile(const std::string& path, uint32_t maxDimension = 4096);
void FlipImageVertical(PixelImage& image);
void FlipImageHorizontal(PixelImage& image);

#endif // NEWT_ENVIRONMENT_H
