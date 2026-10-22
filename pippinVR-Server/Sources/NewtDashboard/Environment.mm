#include "Environment.h"
#import <AppKit/AppKit.h>
#import <ImageIO/ImageIO.h>
#include <algorithm>
#include <cstdint>
#include <cstring>

PixelImage LoadImageFile(const std::string& path, uint32_t maxDimension) {
    PixelImage result;
    @autoreleasepool {
        NSString* nsPath = [NSString stringWithUTF8String:path.c_str()];
        NSURL* url = [NSURL fileURLWithPath:nsPath];
        CGImageSourceRef source = CGImageSourceCreateWithURL((CFURLRef)url, nullptr);
        if (!source) return result;
        CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, nullptr);
        CFRelease(source);
        if (!image) return result;

        uint32_t width = static_cast<uint32_t>(CGImageGetWidth(image));
        uint32_t height = static_cast<uint32_t>(CGImageGetHeight(image));
        if (width == 0 || height == 0) { CGImageRelease(image); return result; }
        const uint32_t longest = std::max(width, height);
        if (longest > maxDimension) {
            const float scale = static_cast<float>(maxDimension) / longest;
            width = std::max<uint32_t>(1, static_cast<uint32_t>(width * scale));
            height = std::max<uint32_t>(1, static_cast<uint32_t>(height * scale));
        }

        result.width = width;
        result.height = height;
        result.pixels.assign(static_cast<size_t>(width) * height * 4, 0);
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate(
            result.pixels.data(), width, height, 8, width * 4, cs,
            kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
        CGContextTranslateCTM(ctx, 0.0, height);
        CGContextScaleCTM(ctx, 1.0, -1.0);
        CGContextDrawImage(ctx, CGRectMake(0, 0, width, height), image);
        CGContextRelease(ctx);
        CGColorSpaceRelease(cs);
        CGImageRelease(image);
    }
    return result;
}

void FlipImageVertical(PixelImage& image) {
    if (image.width == 0 || image.height == 0) return;
    const size_t rowBytes = static_cast<size_t>(image.width) * 4;
    std::vector<uint8_t> temp(rowBytes);
    for (uint32_t y = 0; y < image.height / 2; ++y) {
        uint8_t* rowA = image.pixels.data() + static_cast<size_t>(y) * rowBytes;
        uint8_t* rowB = image.pixels.data() + static_cast<size_t>(image.height - 1 - y) * rowBytes;
        std::memcpy(temp.data(), rowA, rowBytes);
        std::memcpy(rowA, rowB, rowBytes);
        std::memcpy(rowB, temp.data(), rowBytes);
    }
}

void FlipImageHorizontal(PixelImage& image) {
    if (image.width == 0 || image.height == 0) return;
    for (uint32_t y = 0; y < image.height; ++y) {
        auto* row = reinterpret_cast<uint32_t*>(image.pixels.data() + static_cast<size_t>(y) * image.width * 4);
        std::reverse(row, row + image.width);
    }
}
