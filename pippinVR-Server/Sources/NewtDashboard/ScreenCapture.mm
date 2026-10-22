#include "include/NewtLog.h"
#include "Newt/CaptureInternal.h"
#import <AVFoundation/AVFoundation.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#include <chrono>
#include <cmath>
#include <cstring>
#include <iostream>
using namespace NewtCaptureInternal;
@interface NewtScreenCaptureDelegate : NSObject <SCStreamOutput, SCStreamDelegate>
@property (nonatomic, assign) ScreenCaptureManager* manager;
@property (nonatomic, strong) SCStream* stream;
@property (nonatomic, strong) dispatch_queue_t captureQueue;
@property (nonatomic, strong) dispatch_source_t fallbackTimer;
@property (nonatomic, copy) NSString* displayLabel;
@property (nonatomic, assign) NSUInteger displayRetries;
- (instancetype)initWithManager:(ScreenCaptureManager*)mgr;
- (void)startStreamForDisplayIndex:(uint32_t)idx;
- (void)stopStream;
@end

@implementation NewtScreenCaptureDelegate

- (instancetype)initWithManager:(ScreenCaptureManager*)mgr {
    if ((self = [super init])) {
        _manager = mgr;
        _captureQueue = dispatch_queue_create("com.newt.xr.screencapture", DISPATCH_QUEUE_SERIAL);
        _displayLabel = @"macOS Desktop  •  Live Screen Share";
    }
    return self;
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
                cfg.width = LiveWidth();
                cfg.height = LiveHeight();
                cfg.pixelFormat = kCVPixelFormatType_32BGRA;
                cfg.showsCursor = YES;
                cfg.scalesToFit = YES;
                if (@available(macOS 14.0, *)) cfg.preservesAspectRatio = YES;
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
    _manager->PublishCVPixelBuffer(pb,
                                   _displayLabel ? _displayLabel.UTF8String : "Live Desktop");
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
