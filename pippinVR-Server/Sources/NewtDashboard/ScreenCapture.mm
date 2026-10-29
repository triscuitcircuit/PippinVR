#include "include/NewtLog.h"
#include "Metrics.h"
#include "MetalFXResolution.h"
#include "Newt/CaptureInternal.h"
#import <AVFoundation/AVFoundation.h>
#import <CoreVideo/CoreVideo.h>
#import <IOSurface/IOSurface.h>
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstring>
#include <iostream>
using namespace NewtCaptureInternal;

namespace {
std::atomic<bool> gMetalFXEnabled{true};
std::atomic<bool> gMetalFXEnabledInitialized{false};
std::atomic<bool> gMetalFXActive{false};
std::atomic<float> gMetalFXScale{0.0f};
std::atomic<uint32_t> gMetalFXInW{0}, gMetalFXInH{0}, gMetalFXOutW{0}, gMetalFXOutH{0};

bool InitialMetalFXEnabled() {
    const char* env = std::getenv("NEWT_METALFX_UPSCALE");
    if (env) return std::strcmp(env, "0") != 0;
    NSNumber* value = [[NSUserDefaults standardUserDefaults] objectForKey:@"directMetalFXUpscale"];
    return value ? value.boolValue : true;
}
}

void SetMetalFXScale(float scale) {
    if (ValidMetalFXScale(scale)) {
        gMetalFXScale.store(scale, std::memory_order_relaxed);
        gMetalFXActive.store(false, std::memory_order_relaxed);
    }
}

float MetalFXScale() { return gMetalFXScale.load(std::memory_order_relaxed); }

void LoadMetalFXSettings() {
    SetMetalFXUpscaleEnabled(InitialMetalFXEnabled());
    float scale = [[NSUserDefaults standardUserDefaults] floatForKey:@"directMetalFXScale"];
    if (const char* value = std::getenv("NEWT_METALFX_SCALE")) {
        char* end = nullptr;
        scale = std::strtof(value, &end);
        if (end == value || *end != '\0') scale = 0;
    }
    SetMetalFXScale(ValidMetalFXScale(scale) ? scale : 0);
}

void SetMetalFXUpscaleEnabled(bool enabled) {
    gMetalFXEnabled.store(enabled, std::memory_order_relaxed);
    gMetalFXEnabledInitialized.store(true, std::memory_order_relaxed);
    if (!enabled) gMetalFXActive.store(false, std::memory_order_relaxed);
}

bool MetalFXUpscaleEnabled() {
    if (!gMetalFXEnabledInitialized.load(std::memory_order_relaxed)) {
        gMetalFXEnabled.store(InitialMetalFXEnabled(), std::memory_order_relaxed);
        gMetalFXEnabledInitialized.store(true, std::memory_order_relaxed);
    }
    return gMetalFXEnabled.load(std::memory_order_relaxed);
}

bool MetalFXUpscaleActive() {
    return gMetalFXActive.load(std::memory_order_relaxed);
}

void GetMetalFXDimensions(uint32_t& inputWidth, uint32_t& inputHeight,
                          uint32_t& outputWidth, uint32_t& outputHeight) {
    inputWidth = gMetalFXInW.load(std::memory_order_relaxed);
    inputHeight = gMetalFXInH.load(std::memory_order_relaxed);
    outputWidth = gMetalFXOutW.load(std::memory_order_relaxed);
    outputHeight = gMetalFXOutH.load(std::memory_order_relaxed);
}
@interface NewtScreenCaptureDelegate : NSObject <SCStreamOutput, SCStreamDelegate>
@property (nonatomic, assign) ScreenCaptureManager* manager;
@property (nonatomic, strong) SCStream* stream;
@property (nonatomic, strong) dispatch_queue_t captureQueue;
@property (nonatomic, strong) dispatch_source_t fallbackTimer;
@property (nonatomic, copy) NSString* displayLabel;
@property (nonatomic, assign) NSUInteger displayRetries;
@property (nonatomic, strong) id<MTLDevice> mtlDevice;
@property (nonatomic, strong) id<MTLCommandQueue> mtlQueue;
@property (nonatomic, strong) id<MTLFXSpatialScaler> spatialScaler;
@property (nonatomic, assign) size_t scalerInW;
@property (nonatomic, assign) size_t scalerInH;
@property (nonatomic, assign) size_t scalerOutW;
@property (nonatomic, assign) size_t scalerOutH;
- (instancetype)initWithManager:(ScreenCaptureManager*)mgr;
- (void)startStreamForDisplayIndex:(uint32_t)idx;
- (void)stopStream;
@end

@implementation NewtScreenCaptureDelegate {
    CVPixelBufferPoolRef _upscalePool;
}

- (instancetype)initWithManager:(ScreenCaptureManager*)mgr {
    if ((self = [super init])) {
        _manager = mgr;
        _captureQueue = dispatch_queue_create("com.newt.xr.screencapture", DISPATCH_QUEUE_SERIAL);
        _displayLabel = @"macOS Desktop  •  Live Screen Share";
        _upscalePool = nullptr;
    }
    return self;
}

- (void)dealloc {
    if (_upscalePool) {
        CVPixelBufferPoolRelease(_upscalePool);
        _upscalePool = nullptr;
    }
}

- (CVPixelBufferRef)createUpscaledPixelBuffer:(CVPixelBufferRef)srcPB {
    if (!srcPB) return nullptr;
    if (!MetalFXUpscaleEnabled()) {
        gMetalFXActive.store(false, std::memory_order_relaxed);
        return nullptr;
    }
    if (CVPixelBufferGetPixelFormatType(srcPB) != kCVPixelFormatType_32BGRA) return nullptr;
    IOSurfaceRef srcSurface = CVPixelBufferGetIOSurface(srcPB);
    if (!srcSurface) return nullptr;

    const size_t srcW = CVPixelBufferGetWidth(srcPB);
    const size_t srcH = CVPixelBufferGetHeight(srcPB);
    if (srcW < 64 || srcH < 64 || srcW >= 3840) return nullptr;

    const auto output = MetalFXOutputResolution(static_cast<uint32_t>(srcW), static_cast<uint32_t>(srcH), MetalFXScale());
    if (output.width == 0) return nullptr;
    const size_t dstW = output.width, dstH = output.height;

    if (!_mtlDevice) {
        _mtlDevice = MTLCreateSystemDefaultDevice();
        if (_mtlDevice) {
            _mtlQueue = [_mtlDevice newCommandQueue];
        }
    }
    if (!_mtlDevice || !_mtlQueue) return nullptr;
    if (![MTLFXSpatialScalerDescriptor supportsDevice:_mtlDevice]) return nullptr;

    if (!_spatialScaler || _scalerInW != srcW || _scalerInH != srcH ||
        _scalerOutW != dstW || _scalerOutH != dstH || !_upscalePool) {
        MTLFXSpatialScalerDescriptor* desc = [[MTLFXSpatialScalerDescriptor alloc] init];
        desc.inputWidth = srcW;
        desc.inputHeight = srcH;
        desc.outputWidth = dstW;
        desc.outputHeight = dstH;
        desc.colorTextureFormat = MTLPixelFormatBGRA8Unorm;
        desc.outputTextureFormat = MTLPixelFormatBGRA8Unorm;
        desc.colorProcessingMode = MTLFXSpatialScalerColorProcessingModePerceptual;
        _spatialScaler = [desc newSpatialScalerWithDevice:_mtlDevice];
        if (!_spatialScaler) return nullptr;

        if (_upscalePool) {
            CVPixelBufferPoolRelease(_upscalePool);
            _upscalePool = nullptr;
        }
        NSDictionary* poolAttrs = @{
            (id)kCVPixelBufferPoolMinimumBufferCountKey : @4
        };
        NSDictionary* pbAttrs = @{
            (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
            (id)kCVPixelBufferWidthKey : @(dstW),
            (id)kCVPixelBufferHeightKey : @(dstH),
            (id)kCVPixelBufferMetalCompatibilityKey : @YES,
            (id)kCVPixelBufferIOSurfacePropertiesKey : @{}
        };
        if (CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                    (__bridge CFDictionaryRef)poolAttrs,
                                    (__bridge CFDictionaryRef)pbAttrs,
                                    &_upscalePool) != kCVReturnSuccess || !_upscalePool) {
            _spatialScaler = nil;
            return nullptr;
        }
        _scalerInW = srcW;
        _scalerInH = srcH;
        _scalerOutW = dstW;
        _scalerOutH = dstH;
        Newt_Logf(NEWT_LOG_INFO,
                  "MetalFX Spatial Scaler active (%zux%zu -> %zux%zu, Perceptual)",
                  srcW, srcH, dstW, dstH);
    }

    CVPixelBufferRef dstPB = nullptr;
    if (CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, _upscalePool, &dstPB) != kCVReturnSuccess || !dstPB) {
        return nullptr;
    }
    IOSurfaceRef dstSurface = CVPixelBufferGetIOSurface(dstPB);
    if (!dstSurface) {
        CVPixelBufferRelease(dstPB);
        return nullptr;
    }

    MTLTextureDescriptor* srcDesc =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                           width:srcW
                                                          height:srcH
                                                       mipmapped:NO];
    srcDesc.storageMode = MTLStorageModeShared;
    srcDesc.usage = _spatialScaler.colorTextureUsage | MTLTextureUsageShaderRead;
    id<MTLTexture> srcTex = [_mtlDevice newTextureWithDescriptor:srcDesc iosurface:srcSurface plane:0];

    MTLTextureDescriptor* dstDesc =
        [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                           width:dstW
                                                          height:dstH
                                                       mipmapped:NO];
    dstDesc.storageMode = MTLStorageModeShared;
    dstDesc.usage = _spatialScaler.outputTextureUsage | MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
    id<MTLTexture> dstTex = [_mtlDevice newTextureWithDescriptor:dstDesc iosurface:dstSurface plane:0];

    if (!srcTex || !dstTex) {
        CVPixelBufferRelease(dstPB);
        return nullptr;
    }

    _spatialScaler.colorTexture = srcTex;
    _spatialScaler.inputContentWidth = srcW;
    _spatialScaler.inputContentHeight = srcH;
    _spatialScaler.outputTexture = dstTex;

    id<MTLCommandBuffer> cmdBuf = [_mtlQueue commandBuffer];
    if (!cmdBuf) {
        CVPixelBufferRelease(dstPB);
        return nullptr;
    }
    [_spatialScaler encodeToCommandBuffer:cmdBuf];
    [cmdBuf commit];
    [cmdBuf waitUntilCompleted];
    if (cmdBuf.status == MTLCommandBufferStatusError) {
        gMetalFXActive.store(false, std::memory_order_relaxed);
        CVPixelBufferRelease(dstPB);
        return nullptr;
    }
    gMetalFXInW.store(static_cast<uint32_t>(srcW), std::memory_order_relaxed);
    gMetalFXInH.store(static_cast<uint32_t>(srcH), std::memory_order_relaxed);
    gMetalFXOutW.store(static_cast<uint32_t>(dstW), std::memory_order_relaxed);
    gMetalFXOutH.store(static_cast<uint32_t>(dstH), std::memory_order_relaxed);
    gMetalFXActive.store(MetalFXUpscaleEnabled(), std::memory_order_relaxed);
    return dstPB;
}

- (void)startStreamForDisplayIndex:(uint32_t)idx {

    if (!_fallbackTimer) {
        _fallbackTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _captureQueue);
        dispatch_source_set_timer(_fallbackTimer,
                                  dispatch_time(DISPATCH_TIME_NOW, 0),
                                  NSEC_PER_SEC / 15,
                                  NSEC_PER_MSEC * 10);
        __weak NewtScreenCaptureDelegate* weakSelf = self;
        dispatch_source_set_event_handler(_fallbackTimer, ^{
            NewtScreenCaptureDelegate* strongSelf = weakSelf;
            if (strongSelf && strongSelf.manager) {
                strongSelf.manager->TickFallback();
            }
        });
        dispatch_resume(_fallbackTimer);
    }

    if (@available(macOS 12.3, *)) {
        [SCShareableContent getShareableContentExcludingDesktopWindows:NO
                                                   onScreenWindowsOnly:YES
                                                     completionHandler:^(SCShareableContent* content,
                                                                         NSError* error) {
            if (error || content.displays.count == 0) {
                if (error) {
                    Newt_Logf(NEWT_LOG_WARNING, "SCShareableContent fallback (%s)", error.localizedDescription.UTF8String);
                }
                return;
            }
            dispatch_async(self.captureQueue, ^{
                if (!self.manager) return;
                if (self.stream) {
                    [self.stream stopCaptureWithCompletionHandler:nil];
                    self.stream = nil;
                }
                NSUInteger chosen = idx % content.displays.count;
                if (self.manager->DisplayID()) {
                    const uint32_t wanted = self.manager->DisplayID();
                    NSUInteger found = [content.displays indexOfObjectPassingTest:^BOOL(SCDisplay* d, NSUInteger, BOOL*) {
                        return d.displayID == wanted;
                    }];
                    if (found == NSNotFound) {
                        if (self.displayRetries++ < 10) {
                            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_MSEC * 200), self.captureQueue, ^{
                                if (self.manager) [self startStreamForDisplayIndex:idx];
                            });
                        }
                        return;
                    }
                    chosen = found;
                }
                SCDisplay* display = content.displays[chosen];
                self.manager->SetDisplayID(display.displayID);
                self.displayRetries = 0;
                self.displayLabel = [NSString stringWithFormat:@"Display %lu (%ldx%ld)  •  ScreenCaptureKit Live",
                                     (unsigned long)(chosen + 1),
                                     (long)display.width, (long)display.height];

                SCContentFilter* filter =
                    [[SCContentFilter alloc] initWithDisplay:display excludingWindows:@[]];
                SCStreamConfiguration* cfg = [[SCStreamConfiguration alloc] init];
                const size_t dispW = std::max<size_t>(1, static_cast<size_t>(display.width));
                const size_t dispH = std::max<size_t>(1, static_cast<size_t>(display.height));
                const size_t baseW = std::max<size_t>(static_cast<size_t>(LiveWidth()), std::min<size_t>(dispW, 1920));
                const size_t streamW = std::max<size_t>(2, baseW & ~size_t(1));
                const size_t streamH = std::max<size_t>(2, ((streamW * dispH + dispW / 2) / dispW) & ~size_t(1));
                cfg.width = streamW;
                cfg.height = streamH;
                cfg.pixelFormat = kCVPixelFormatType_32BGRA;
                cfg.showsCursor = YES;
                cfg.scalesToFit = YES;
                if (@available(macOS 14.0, *)) cfg.preservesAspectRatio = NO;
                cfg.minimumFrameInterval = CMTimeMake(1, self.manager ? self.manager->FPS() : 30);
                cfg.queueDepth = 5;

                SCStream* stream = [[SCStream alloc] initWithFilter:filter
                                                      configuration:cfg
                                                           delegate:self];
                NSError* addErr = nil;
                if ([stream addStreamOutput:self
                                       type:SCStreamOutputTypeScreen
                         sampleHandlerQueue:self.captureQueue
                                      error:&addErr]) {
                    self.stream = stream;
                    [stream startCaptureWithCompletionHandler:^(NSError* startErr) {
                        if (startErr) {
                            Newt_Logf(NEWT_LOG_WARNING, "SCStream startCapture failed (%s), using CoreGraphics display capture.",
                                      startErr.localizedDescription.UTF8String);
                        } else {
                            Newt_Logf(NEWT_LOG_INFO, "ScreenCaptureKit streaming Display %lu", static_cast<unsigned long>(chosen + 1));
                        }
                    }];
                }
            });
        }];
    }
}

- (void)stopStream {
    if (_fallbackTimer) {
        dispatch_source_cancel(_fallbackTimer);
        _fallbackTimer = nil;
    }
    if (_stream) {
        [_stream stopCaptureWithCompletionHandler:nil];
        _stream = nil;
    }
}

- (void)stream:(SCStream*)stream
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
                   ofType:(SCStreamOutputType)type {
    (void)stream;
    if (type != SCStreamOutputTypeScreen || !CMSampleBufferIsValid(sampleBuffer)) return;
    NSArray* attachments = (__bridge NSArray*)CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, false);
    NSNumber* status = attachments.firstObject[SCStreamFrameInfoStatus];
    if (status && status.integerValue != SCFrameStatusComplete) return;
    CVImageBufferRef pb = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pb || !_manager) return;
    CVPixelBufferRef upscaled = [self createUpscaledPixelBuffer:pb];
    if (upscaled) {
        _manager->PublishCVPixelBuffer(upscaled,
                                       _displayLabel ? _displayLabel.UTF8String : "Live Desktop");
        CVPixelBufferRelease(upscaled);
    } else {
        _manager->PublishCVPixelBuffer(pb,
                                       _displayLabel ? _displayLabel.UTF8String : "Live Desktop");
    }
}

@end





ScreenCaptureManager::ScreenCaptureManager() = default;

ScreenCaptureManager::~ScreenCaptureManager() {
    Stop();
}

void ScreenCaptureManager::Start(uint32_t displayIndex, uint32_t fps) {
    mDisplayIndex = displayIndex;
    mFPS = fps;
    if (mRunning.exchange(true)) return;
    @autoreleasepool {
        NewtScreenCaptureDelegate* del =
            [[NewtScreenCaptureDelegate alloc] initWithManager:this];
        mImpl.reset((__bridge_retained void*)del);
        [del startStreamForDisplayIndex:mDisplayIndex.load()];
    }
}

void ScreenCaptureManager::Stop() {
    if (!mRunning.exchange(false)) return;
    @autoreleasepool {
        if (mImpl) {
            NewtScreenCaptureDelegate* del =
                (__bridge_transfer NewtScreenCaptureDelegate*)mImpl.release();
            dispatch_sync(del.captureQueue, ^{
                del.manager = nullptr;
                [del stopStream];
            });
        }
    }
    std::lock_guard<std::mutex> lock(mMutex);
    mLatestBuffer.reset();
    mLatestFrame.pixels.clear();
}

void ScreenCaptureManager::SetFPS(uint32_t fps) {
    const uint32_t index = mDisplayIndex.load();
    Stop();
    Start(index, fps);
}

void ScreenCaptureManager::PublishCVPixelBuffer(void* cvPixelBuffer, const std::string& label) {
    if (!mRunning.load()) return;
    mLastSCStreamTimeMs.store(NowMs());
    auto pixels = static_cast<CVPixelBufferRef>(cvPixelBuffer);
    const char* option = std::getenv("NEWT_GPU_CAPTURE");
    const bool gpu = !option || std::strcmp(option, "0") != 0;
    if (gpu && CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA &&
        CVPixelBufferGetIOSurface(pixels)) {
        std::lock_guard<std::mutex> lock(mMutex);
        mLatestBuffer.reset(CVPixelBufferRetain(pixels));
        mLatestLabel = label;
        mLatestFrame.pixels.clear();
        mFrameSeq.fetch_add(1);
    } else {
        PixelImage img = PixelImageFromCVPixelBuffer(pixels, label);
        std::lock_guard<std::mutex> lock(mMutex);
        mLatestBuffer.reset();
        mLatestFrame = std::move(img);
        mFrameSeq.fetch_add(1);
    }
}

void ScreenCaptureManager::TickFallback() {
    if (!mRunning.load()) return;

    const uint64_t now = NowMs();
    const uint64_t lastSc = mLastSCStreamTimeMs.load();
    if (lastSc > 0 && (now - lastSc) < 500) return;

    @autoreleasepool {

        if (mFrameSeq.load() == 0) {
            NSScreen* mainScreen = [NSScreen mainScreen];
            NSRect frame = mainScreen ? mainScreen.frame : NSMakeRect(0, 0, 1920, 1080);
            PixelImage out = MakeImage(^(NSRect bounds) {
                FillRounded(bounds, 24, RGB(0.05f, 0.065f, 0.085f, 0.99f));
                NSColor* white = RGB(0.94f, 0.96f, 0.95f);
                NSColor* cyan = RGB(0.45f, 0.86f, 0.80f);
                NSColor* muted = RGB(0.62f, 0.68f, 0.72f);
                DrawText(@"Screens  •  macOS Desktop Stream", NSMakeRect(48, 32, 650, 44), 34, YES, white);
                NSString* resInfo = [NSString stringWithFormat:@"Primary Display %.0fx%.0f",
                                     frame.size.width, frame.size.height];
                DrawText(resInfo, NSMakeRect(680, 40, 296, 30), 20, YES, cyan, NSTextAlignmentRight);
                FillRounded(NSMakeRect(64, 110, 896, 380), 16, RGB(0.10f, 0.14f, 0.18f));
                DrawText(@"Connecting to macOS ScreenCaptureKit...",
                         NSMakeRect(100, 260, 824, 40), 28, YES, white, NSTextAlignmentCenter);
                DrawText(@"If prompted by macOS, allow Screen Recording for Pippin in System Settings > Privacy & Security.",
                         NSMakeRect(100, 315, 824, 60), 20, NO, muted, NSTextAlignmentCenter);
                DrawText(@"Trigger / Select cycles Displays  •  Menu button toggles Pippin dashboard",
                         NSMakeRect(64, 520, 896, 30), 19, NO, muted, NSTextAlignmentCenter);
            });
            {
                std::lock_guard<std::mutex> lock(mMutex);
                mLatestFrame = std::move(out);
            }
            mFrameSeq.fetch_add(1);
        }
    }
}

bool ScreenCaptureManager::GetLatestFrame(uint64_t& lastSeq, PixelImage& outImage) {
    std::lock_guard<std::mutex> lock(mMutex);
    const uint64_t cur = mFrameSeq.load();
    if (cur == 0 || cur == lastSeq) return false;
    if (mLatestFrame.pixels.empty()) return false;
    outImage = std::move(mLatestFrame);
    lastSeq = cur;
    return true;
}





bool ScreenCaptureManager::GetLatestPixelBuffer(uint64_t& lastSeq, RetainedObject& pixels, std::string& label) {
    std::lock_guard<std::mutex> lock(mMutex);
    const auto sequence = mFrameSeq.load();
    if (sequence == lastSeq || !mLatestBuffer) return false;
    pixels = std::move(mLatestBuffer);
    label = mLatestLabel;
    lastSeq = sequence;
    return true;
}
