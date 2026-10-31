#include "AddonCameraBridge.h"
#import <Foundation/Foundation.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#include <atomic>
#include <chrono>
#include <cstdlib>
#include <sys/stat.h>

namespace {
dispatch_queue_t queue;
std::atomic<bool> active{false};
std::atomic<bool> busy{false};
std::atomic<int64_t> lastSubmission{0};
NSString* directory;
CIContext* imageContext;

NSString* ValidLease(NSString* eye) {
    NSString* path = [directory stringByAppendingPathComponent:[eye stringByAppendingString:@".request"]];
    NSDictionary* attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    NSDate* date = attributes[NSFileModificationDate];
    if (!date || fabs(date.timeIntervalSinceNow) > 2.0) return nil;
    NSString* lease = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    return [[NSUUID alloc] initWithUUIDString:lease] ? lease : nil;
}

void SaveFrame(NSString* eye, CVPixelBufferRef buffer, int64_t captureNs, CIContext* context) {
    NSString* lease = ValidLease(eye);
    if (!lease || !active.load()) return;
    CIImage* image = [CIImage imageWithCVPixelBuffer:buffer];
    CGRect bounds = image.extent;
    if (bounds.size.width <= 0 || bounds.size.height <= 0) return;
    CGFloat scale = MIN(1.0, 320.0 / MAX(bounds.size.width, bounds.size.height));
    image = [image imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
    CGImageRef cg = [context createCGImage:image fromRect:image.extent];
    if (!cg) return;
    NSMutableData* jpeg = [NSMutableData data];
    CGImageDestinationRef dest = CGImageDestinationCreateWithData((__bridge CFMutableDataRef)jpeg, CFSTR("public.jpeg"), 1, nullptr);
    if (dest) {
        CGImageDestinationAddImage(dest, cg, (__bridge CFDictionaryRef)@{(NSString*)kCGImageDestinationLossyCompressionQuality: @0.5});
        if (!CGImageDestinationFinalize(dest)) [jpeg setLength:0];
        CFRelease(dest);
    }
    size_t width = CGImageGetWidth(cg), height = CGImageGetHeight(cg);
    CGImageRelease(cg);
    if (!jpeg.length || jpeg.length > 36000 || !active.load() || ![lease isEqualToString:ValidLease(eye)]) return;
    NSDictionary* frame = @{@"lease": lease, @"eye": eye, @"format": @"jpeg", @"width": @(width), @"height": @(height), @"captureTimestampNs": [NSString stringWithFormat:@"%lld", (long long)captureNs], @"data": [jpeg base64EncodedStringWithOptions:0]};
    NSData* data = [NSJSONSerialization dataWithJSONObject:frame options:0 error:nil];
    NSString* path = [directory stringByAppendingPathComponent:[eye stringByAppendingString:@".json"]];
    if (!data || ![data writeToFile:path options:NSDataWritingAtomic error:nil]) return;
    chmod(path.fileSystemRepresentation, 0600);
    if (!active.load() || ![lease isEqualToString:ValidLease(eye)]) [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
}
}

void StartAddonCameraBridge() {
    if (active.exchange(true)) return;
    NSString* root = nil;
    if (const char* value = std::getenv("NEWT_STATE_DIR")) root = [NSString stringWithUTF8String:value];
    if (!root.length) root = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Newt"];
    directory = [root stringByAppendingPathComponent:@"ui/api-camera"];
    queue = dispatch_queue_create("org.newt.addon-camera", DISPATCH_QUEUE_SERIAL);
    lastSubmission.store(0);
}

void StopAddonCameraBridge() {
    if (!active.exchange(false)) return;
    dispatch_sync(queue, ^{});
    queue = nil;
    directory = nil;
    imageContext = nil;
}

void SubmitAddonCameraFrames(CVPixelBufferRef left, CVPixelBufferRef right, int64_t captureNs) {
    if (!active.load() || !left || !right) return;
    auto now = std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();
    if (now - lastSubmission.load() < 500000000 || busy.exchange(true)) return;
    lastSubmission.store(now);
    CVPixelBufferRetain(left);
    CVPixelBufferRetain(right);
    dispatch_async(queue, ^{
        @autoreleasepool {
            if (active.load() && (ValidLease(@"left") || ValidLease(@"right"))) {
                if (!imageContext) imageContext = [CIContext contextWithOptions:nil];
                SaveFrame(@"left", left, captureNs, imageContext);
                SaveFrame(@"right", right, captureNs, imageContext);
            }
            CVPixelBufferRelease(left);
            CVPixelBufferRelease(right);
            busy.store(false);
        }
    });
}
