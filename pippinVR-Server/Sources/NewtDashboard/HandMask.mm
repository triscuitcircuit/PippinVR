// SPDX-License-Identifier: MIT




#include "HandMask.h"
#import <Accelerate/Accelerate.h>
#import <CoreImage/CoreImage.h>
#import <Vision/Vision.h>
#include <atomic>
#include <mutex>

namespace {
constexpr size_t kVisionWidth = 640;

struct PoolSlot {
    CVPixelBufferPoolRef pool = nullptr;
    size_t width = 0, height = 0;
    CVPixelBufferRef Make(size_t w, size_t h) {
        if (!pool || width != w || height != h) {
            if (pool) CVPixelBufferPoolRelease(pool);
            pool = nullptr;
            NSDictionary* attributes = @{(id)kCVPixelBufferPixelFormatTypeKey:@(kCVPixelFormatType_32BGRA),
                                         (id)kCVPixelBufferWidthKey:@(w), (id)kCVPixelBufferHeightKey:@(h),
                                         (id)kCVPixelBufferIOSurfacePropertiesKey:@{},
                                         (id)kCVPixelBufferMetalCompatibilityKey:@YES};
            if (CVPixelBufferPoolCreate(kCFAllocatorDefault, nullptr, (__bridge CFDictionaryRef)attributes, &pool) !=
                kCVReturnSuccess) return nullptr;
            width = w;
            height = h;
        }
        CVPixelBufferRef out = nullptr;
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out);
        return out;
    }
};

struct State {
    dispatch_queue_t queue = dispatch_queue_create("pippin.hand-mask", DISPATCH_QUEUE_SERIAL);
    __strong CIContext* context = [CIContext contextWithOptions:@{kCIContextCacheIntermediates:@NO}];
    std::atomic<bool> busy{false};
    std::atomic<uint64_t> generation{1};
    PoolSlot small[2], full[2];
    std::mutex mutex;
    HandMaskOutput result;
    uint64_t sequence = 0;
};
State& Shared() {
    static State* state = new State;
    return *state;
}

void Release(HandMaskOutput& out) {
    for (auto& buffer : out.cutout) {
        if (buffer) CVPixelBufferRelease(buffer);
        buffer = nullptr;
    }
}


CVPixelBufferRef Cutout(State& state, int camera, CVPixelBufferRef source,
                        const std::vector<std::vector<HandMask::Point>>& hands, bool found[2]) {
    found[0] = found[1] = false;
    bool any = false;
    for (const auto& points : hands) any = any || !points.empty();
    const size_t width = CVPixelBufferGetWidth(source), height = CVPixelBufferGetHeight(source);
    if (!any || !width || !height) return nullptr;
    const double scale = std::min(1.0, double(kVisionWidth) / width);
    CVPixelBufferRef small = state.small[camera].Make(size_t(width * scale), size_t(height * scale));
    if (!small) return nullptr;
    CIImage* image = [CIImage imageWithCVPixelBuffer:source];
    [state.context render:[image imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)]
          toCVPixelBuffer:small];
    VNImageRequestHandler* handler = [[VNImageRequestHandler alloc] initWithCVPixelBuffer:small
                                                                              orientation:kCGImagePropertyOrientationUp
                                                                                  options:@{}];
    VNGenerateForegroundInstanceMaskRequest* request = [VNGenerateForegroundInstanceMaskRequest new];
    NSError* error = nil;
    CVPixelBufferRef out = nullptr;
    if ([handler performRequests:@[request] error:&error]) {
        VNInstanceMaskObservation* observation = request.results.firstObject;
        CVPixelBufferRef labels = observation.instanceMask;
        NSMutableIndexSet* chosen = [NSMutableIndexSet indexSet];
        if (labels && CVPixelBufferGetPixelFormatType(labels) == kCVPixelFormatType_OneComponent8 &&
            CVPixelBufferLockBaseAddress(labels, kCVPixelBufferLock_ReadOnly) == kCVReturnSuccess) {
            const auto selection = HandMask::SelectLabels(
                static_cast<const uint8_t*>(CVPixelBufferGetBaseAddress(labels)), CVPixelBufferGetWidth(labels),
                CVPixelBufferGetHeight(labels), CVPixelBufferGetBytesPerRow(labels), hands);
            CVPixelBufferUnlockBaseAddress(labels, kCVPixelBufferLock_ReadOnly);
            for (size_t h = 0; h < 2 && h < selection.hand.size(); ++h) {
                const int label = selection.hand[h];
                if (label > 0 && [observation.allInstances containsIndex:NSUInteger(label)]) {
                    found[h] = true;
                    [chosen addIndex:NSUInteger(label)];
                }
            }
        }

        if (chosen.count) {
            CVPixelBufferRef mask = [observation generateScaledMaskForImageForInstances:chosen
                                                                     fromRequestHandler:handler
                                                                                  error:&error];
            out = mask ? state.full[camera].Make(width, height) : nullptr;
            if (out) {
                CIImage* maskImage = [[CIImage imageWithCVPixelBuffer:mask]
                    imageByApplyingTransform:CGAffineTransformMakeScale(1.0 / scale, 1.0 / scale)];
                CIImage* cut = [image imageByApplyingFilter:@"CIBlendWithMask" withInputParameters:@{
                    kCIInputBackgroundImageKey:[CIImage emptyImage], kCIInputMaskImageKey:maskImage}];
                [state.context render:cut toCVPixelBuffer:out];


                if (CVPixelBufferLockBaseAddress(out, 0) == kCVReturnSuccess) {
                    vImage_Buffer pixels{CVPixelBufferGetBaseAddress(out), vImagePixelCount(height),
                                         vImagePixelCount(width), CVPixelBufferGetBytesPerRow(out)};
                    vImageUnpremultiplyData_BGRA8888(&pixels, &pixels, kvImageNoFlags);
                    CVPixelBufferUnlockBaseAddress(out, 0);
                }
            }
            if (mask) CVPixelBufferRelease(mask);
        }
    }
    CVPixelBufferRelease(small);
    if (!out) found[0] = found[1] = false;
    return out;
}
}

void HandMaskSubmit(CVPixelBufferRef left, CVPixelBufferRef right, int64_t captureNs, const HandMaskInput& input) {
    State& state = Shared();
    if (!left || !right || state.busy.exchange(true)) return;
    CVPixelBufferRetain(left);
    CVPixelBufferRetain(right);
    const uint64_t generation = state.generation.load();
    auto work = std::make_shared<HandMaskInput>(input);
    dispatch_async(state.queue, ^{
        @autoreleasepool {
            __block HandMaskOutput output;
            output.captureNs = captureNs;
            HandMaskOutput* results = &output;
            dispatch_apply(2, dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^(size_t camera) {
                @autoreleasepool {
                    results->cutout[camera] = Cutout(state, int(camera), camera ? right : left, work->hands[camera],
                                                     results->hand[camera]);
                }
            });
            CVPixelBufferRelease(left);
            CVPixelBufferRelease(right);
            {
                std::lock_guard<std::mutex> lock(state.mutex);
                if (generation == state.generation.load()) {
                    Release(state.result);
                    state.result = output;
                    ++state.sequence;
                } else {
                    Release(output);
                }
            }
            state.busy = false;
        }
    });
}

bool HandMaskCopyLatest(uint64_t& sequence, HandMaskOutput& out) {
    State& state = Shared();
    std::lock_guard<std::mutex> lock(state.mutex);
    if (state.sequence == 0 || sequence == state.sequence) return false;
    sequence = state.sequence;
    out = state.result;
    for (auto& buffer : out.cutout)
        if (buffer) CVPixelBufferRetain(buffer);
    return true;
}

void HandMaskReset() {
    State& state = Shared();
    ++state.generation;
    dispatch_sync(state.queue, ^{});
    std::lock_guard<std::mutex> lock(state.mutex);
    Release(state.result);
    state.result = HandMaskOutput{};
    ++state.sequence;
}
