#include "include/NewtLog.h"
#include "Newt/CaptureInternal.h"
#include "SpatialVideoOutput.h"
#import <AVFoundation/AVFoundation.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <VideoToolbox/VideoToolbox.h>
#include <chrono>
#include <cmath>
#include <cstring>
#include <iostream>
using namespace NewtCaptureInternal;

@interface NewtMediaCaptureDelegate : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property (nonatomic, assign) MediaCaptureManager* manager;
@property (nonatomic, strong) dispatch_queue_t mediaQueue;
@property (nonatomic, strong) dispatch_source_t tickTimer;
@property (nonatomic, strong) AVPlayer* player;
@property (nonatomic, strong) AVPlayerItemVideoOutput* videoOutput;
@property (nonatomic, strong) id stereoVideoOutput;
@property (nonatomic, assign) BOOL loggedMVHEVC;
@property (nonatomic, strong) id loopObserver;
@property (nonatomic, strong) AVCaptureSession* cameraSession;
@property (nonatomic, copy) NSString* activeSourceName;
@property (nonatomic, assign) int sourceMode;
@property (nonatomic, assign) uint64_t lastCameraFrameMs;
@property (nonatomic, assign) BOOL placeholderPublished;
- (instancetype)initWithManager:(MediaCaptureManager*)mgr;
- (void)start;
- (void)stop;
@end

@implementation NewtMediaCaptureDelegate

- (instancetype)initWithManager:(MediaCaptureManager*)mgr {
    if ((self = [super init])) {
        _manager = mgr;
        _mediaQueue = dispatch_queue_create("com.newt.xr.mediacapture", DISPATCH_QUEUE_SERIAL);
        _activeSourceName = @"Initializing Media Feed...";
        _sourceMode = 0;
        _lastCameraFrameMs = 0;
        _placeholderPublished = NO;
    }
    return self;
}

- (NSString*)findVideoFilePath {
    if (!_manager || _manager->VideoPath().empty()) return nil;
    NSString* path = [NSString stringWithUTF8String:_manager->VideoPath().c_str()];
    return [[NSFileManager defaultManager] fileExistsAtPath:path] ? path : nil;
}

- (void)setupVideoPlayerIfAvailable {
    NSString* videoPath = [self findVideoFilePath];
    if (!videoPath) return;

    NSURL* url = [NSURL fileURLWithPath:videoPath];
    AVAsset* asset = [AVAsset assetWithURL:url];
    AVPlayerItem* item = [AVPlayerItem playerItemWithAsset:asset];
    NSDictionary* pixAttrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferIOSurfacePropertiesKey : @{}
    };
    _videoOutput = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:pixAttrs];
    [item addOutput:_videoOutput];

    _player = [AVPlayer playerWithPlayerItem:item];
    _player.muted = NO;
    _player.volume = MediaVolume();
    _player.actionAtItemEnd = AVPlayerActionAtItemEndNone;
    _stereoVideoOutput = AttachSpatialVideoOutputToPlayer(_player, pixAttrs);

    __weak AVPlayer* weakPlayer = _player;
    _loopObserver = [[NSNotificationCenter defaultCenter]
        addObserverForName:AVPlayerItemDidPlayToEndTimeNotification
                    object:item
                     queue:nil
                usingBlock:^(NSNotification* /*note*/) {
                    [weakPlayer seekToTime:kCMTimeZero];
                    [weakPlayer play];
                }];
    [_player play];
    const bool hwMVHEVC = VTIsStereoMVHEVCDecodeSupported() != 0;
    _activeSourceName = [NSString stringWithFormat:@"VIDEO  •  %@", videoPath.lastPathComponent];
    Newt_Logf(NEWT_LOG_INFO, "Media player started (%s, MV-HEVC hardware decode=%s)",
              videoPath.UTF8String, hwMVHEVC ? "yes" : "no");
}

- (void)setupCameraIfAuthorized {
    NSDictionary* info = [[NSBundle mainBundle] infoDictionary];
    BOOL hasPlistKey = (info[@"NSCameraUsageDescription"] != nil);
    AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    if (!hasPlistKey && status != AVAuthorizationStatusAuthorized) {
        return;
    }
    if (status == AVAuthorizationStatusRestricted || status == AVAuthorizationStatusDenied) {
        return;
    }

    @try {
        NSArray<AVCaptureDevice*>* devices = [AVCaptureDeviceDiscoverySession
            discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeBuiltInWideAngleCamera, AVCaptureDeviceTypeExternal]
            mediaType:nil position:AVCaptureDevicePositionUnspecified].devices;
        const uint32_t index = _manager ? _manager->CameraIndex() : 0;
        AVCaptureDevice* device = index < devices.count ? devices[index] : nil;
        if (_manager && !_manager->CameraID().empty())
            device = [AVCaptureDevice deviceWithUniqueID:[NSString stringWithUTF8String:_manager->CameraID().c_str()]];
        if (!device) return;
        NSError* err = nil;
        AVCaptureDeviceInput* input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&err];
        if (!input || err) return;

        AVCaptureSession* session = [[AVCaptureSession alloc] init];
        if ([session canSetSessionPreset:AVCaptureSessionPreset1280x720]) {
            session.sessionPreset = AVCaptureSessionPreset1280x720;
        }
        if (![session canAddInput:input]) return;
        [session addInput:input];

        AVCaptureVideoDataOutput* output = [[AVCaptureVideoDataOutput alloc] init];
        output.alwaysDiscardsLateVideoFrames = YES;
        output.videoSettings = @{
            (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA)
        };
        [output setSampleBufferDelegate:self queue:_mediaQueue];
        if (![session canAddOutput:output]) return;
        [session addOutput:output];

        _cameraSession = session;
        _activeSourceName = [NSString stringWithFormat:@"LIVE CAMERA  •  %@", device.localizedName];
        [session startRunning];
        Newt_Logf(NEWT_LOG_INFO, "Camera capture started (%s)", device.localizedName.UTF8String);
    } @catch (NSException* ex) {
        Newt_Logf(NEWT_LOG_WARNING, "Camera init skipped (%s)", ex.reason.UTF8String);
    }
}

- (void)start {
    dispatch_async(_mediaQueue, ^{
        [self setupVideoPlayerIfAvailable];
        if (!self.tickTimer) {
            self.tickTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, self.mediaQueue);
            dispatch_source_set_timer(self.tickTimer,
                                      dispatch_time(DISPATCH_TIME_NOW, 0),
                                      NSEC_PER_SEC / 30,
                                      NSEC_PER_MSEC * 5);
            __weak NewtMediaCaptureDelegate* weakSelf = self;
            dispatch_source_set_event_handler(self.tickTimer, ^{
                [weakSelf tickFrame];
            });
            dispatch_resume(self.tickTimer);
        }
    });
}

- (void)stop {
    if (_tickTimer) {
        dispatch_source_cancel(_tickTimer);
        _tickTimer = nil;
    }
    if (_loopObserver) {
        [[NSNotificationCenter defaultCenter] removeObserver:_loopObserver];
        _loopObserver = nil;
    }
    if (_player) {
        [_player pause];
        if (@available(macOS 14.2, *)) {
            _player.videoOutput = nil;
        }
        _player = nil;
    }
    _stereoVideoOutput = nil;
    _videoOutput = nil;
    if (_cameraSession) {
        [_cameraSession stopRunning];
        _cameraSession = nil;
    }
}

- (void)captureOutput:(AVCaptureOutput*)output
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
           fromConnection:(AVCaptureConnection*)connection {
    (void)output;
    (void)connection;
    if (_sourceMode == 2) return;
    if (_sourceMode == 0 && _player != nil) return;
    CVImageBufferRef pb = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pb || !_manager) return;
    _lastCameraFrameMs = NowMs();
    PublishMediaPixelBuffers(_manager,
                             pb,
                             nullptr,
                             _activeSourceName ? _activeSourceName.UTF8String : "LIVE CAMERA",
                             0);
}

- (void)tickFrame {
    _player.volume = MediaVolume();
    if (!_manager) return;

    if (_sourceMode == 0 && _player && _stereoVideoOutput) {
        if (PollSpatialVideoOutput(_stereoVideoOutput, _manager, _activeSourceName, &_loggedMVHEVC)) {
            return;
        }
    }

    if (_sourceMode == 0 && _player && _videoOutput) {
        CMTime itemTime = [_videoOutput itemTimeForHostTime:CACurrentMediaTime()];
        if ([_videoOutput hasNewPixelBufferForItemTime:itemTime]) {
            CVPixelBufferRef pb = [_videoOutput copyPixelBufferForItemTime:itemTime
                                                        itemTimeForDisplay:nullptr];
            if (pb) {
                PublishMediaPixelBuffers(_manager, pb, nullptr, _activeSourceName.UTF8String, 0);
                CVPixelBufferRelease(pb);
                return;
            }
        }
    }

    if (_sourceMode != 2 && _cameraSession && (NowMs() - _lastCameraFrameMs) < 300) {
        return;
    }

    if (_placeholderPublished) return;
    _placeholderPublished = YES;
    const BOOL selected = !_manager->VideoPath().empty();
    PixelImage img = MakeImage(^(NSRect bounds) {
        FillRounded(bounds, 24, RGB(0.045f, 0.06f, 0.08f, 0.99f));
        DrawText(@"Media", NSMakeRect(48, 28, 650, 44), 34, YES, RGB(0.94f, 0.96f, 0.95f));
        DrawText(selected ? @"Waiting for the selected video…" : @"No video selected",
                 NSMakeRect(80, 250, 864, 50), 28, YES, RGB(0.94f, 0.96f, 0.95f), NSTextAlignmentCenter);
        DrawText(@"Choose a video using Media in the headset or Add Media on your Mac.",
                 NSMakeRect(80, 325, 864, 60), 20, NO, RGB(0.60f, 0.66f, 0.70f), NSTextAlignmentCenter);
    });

    _manager->PublishImage(std::move(img));
}

@end

MediaCaptureManager::MediaCaptureManager() = default;

MediaCaptureManager::~MediaCaptureManager() {
    Stop();
}

void MediaCaptureManager::Start() {
    if (mRunning.exchange(true)) return;
    @autoreleasepool {
        NewtMediaCaptureDelegate* del =
            [[NewtMediaCaptureDelegate alloc] initWithManager:this];
        mImpl.reset((__bridge_retained void*)del);
        [del start];
    }
}

void MediaCaptureManager::Stop() {
    if (!mRunning.exchange(false)) return;
    @autoreleasepool {
        if (mImpl) {
            NewtMediaCaptureDelegate* del =
                (__bridge_transfer NewtMediaCaptureDelegate*)mImpl.release();
            dispatch_sync(del.mediaQueue, ^{
                del.manager = nullptr;
                [del stop];
            });
        }
    }
    RemoveMediaState(this);
}

void MediaCaptureManager::StartCamera(uint32_t index, uint32_t fps) {
    mCameraIndex = index;
    mFPS = fps;
    if (mRunning.exchange(true)) return;
    NewtMediaCaptureDelegate* del = [[NewtMediaCaptureDelegate alloc] initWithManager:this];
    mImpl.reset((__bridge_retained void*)del);
    dispatch_async(del.mediaQueue, ^{
        del.sourceMode = 1;
        [del setupCameraIfAuthorized];
        if (!del.cameraSession && del.manager) {
            del.manager->PublishImage(MakeImage(^(NSRect bounds) {
                FillRounded(bounds, 20, RGB(0.06, 0.08, 0.1));
                DrawText(@"Camera unavailable — allow Camera access in macOS Settings",
                         NSMakeRect(40, 240, 944, 120), 28, YES, RGB(0.9, 0.9, 0.9));
            }));
        }
    });
}

void MediaCaptureManager::SetFPS(uint32_t fps) { mFPS = fps; }

void MediaCaptureManager::PublishCVPixelBuffer(void* cvPixelBuffer, const std::string& badge) {
    if (!mRunning.load()) return;
    const uint64_t now = NowMs();
    if (now - mLastPublishMs.load() < 1000 / mFPS.load()) return;
    mLastPublishMs = now;
    PixelImage img = PixelImageFromCVPixelBuffer(static_cast<CVPixelBufferRef>(cvPixelBuffer), badge);
    {
        std::lock_guard<std::mutex> lock(mMutex);
        mLatestFrame = std::move(img);
    }
    mFrameSeq.fetch_add(1);
}

void MediaCaptureManager::PublishImage(PixelImage&& img) {
    if (!mRunning.load()) return;
    {
        std::lock_guard<std::mutex> lock(mMutex);
        mLatestFrame = std::move(img);
    }
    mFrameSeq.fetch_add(1);
}

bool MediaCaptureManager::GetLatestFrame(uint64_t& lastSeq, PixelImage& outImage) {
    const uint64_t cur = mFrameSeq.load();
    if (cur == 0 || cur == lastSeq) return false;
    std::lock_guard<std::mutex> lock(mMutex);
    if (mLatestFrame.pixels.empty()) return false;
    outImage = std::move(mLatestFrame);
    lastSeq = cur;
    return true;
}
