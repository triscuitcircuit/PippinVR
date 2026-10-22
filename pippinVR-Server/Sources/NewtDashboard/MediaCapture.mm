#include "include/NewtLog.h"
#include "Newt/CaptureInternal.h"
#import <AVFoundation/AVFoundation.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
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
@property (nonatomic, strong) id loopObserver;
@property (nonatomic, strong) AVCaptureSession* cameraSession;
@property (nonatomic, copy) NSString* activeSourceName;
@property (nonatomic, assign) int sourceMode; // 0 = Auto/Video/Camera, 1 = Camera, 2 = Stereo Live Visualizer
@property (nonatomic, assign) uint64_t lastCameraFrameMs;
@property (nonatomic, assign) double animPhase;
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
        _animPhase = 0.0;
    }
    return self;
}

- (NSString*)findVideoFilePath {
    if (!_manager->VideoPath().empty()) return [NSString stringWithUTF8String:_manager->VideoPath().c_str()];
    const char* envPath = std::getenv("NEWT_VIDEO_PATH");
    NSFileManager* fm = [NSFileManager defaultManager];
    if (envPath && envPath[0] != '\0') {
        NSString* p = [NSString stringWithUTF8String:envPath];
        if ([fm fileExistsAtPath:p]) return p;
    }
    NSArray<NSString*>* dirs = @[
        [fm currentDirectoryPath],
        [NSHomeDirectory() stringByAppendingPathComponent:@"Movies"],
        [NSHomeDirectory() stringByAppendingPathComponent:@"Desktop"]
    ];
    NSArray<NSString*>* exts = @[@"mp4", @"mov", @"m4v"];
    for (NSString* dir in dirs) {
        NSArray<NSString*>* files = [fm contentsOfDirectoryAtPath:dir error:nil];
        for (NSString* f in files) {
            if ([exts containsObject:f.pathExtension.lowercaseString]) {
                return [dir stringByAppendingPathComponent:f];
            }
        }
    }
    return nil;
}

- (void)setupVideoPlayerIfAvailable {
    NSString* videoPath = [self findVideoFilePath];
    if (!videoPath) return;

    NSURL* url = [NSURL fileURLWithPath:videoPath];
    AVAsset* asset = [AVAsset assetWithURL:url];
    AVPlayerItem* item = [AVPlayerItem playerItemWithAsset:asset];
    NSDictionary* pixAttrs = @{
        (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
        (id)kCVPixelBufferWidthKey : @(kTextureWidth),
        (id)kCVPixelBufferHeightKey : @(kTextureHeight)
    };
    _videoOutput = [[AVPlayerItemVideoOutput alloc] initWithPixelBufferAttributes:pixAttrs];
    [item addOutput:_videoOutput];

    _player = [AVPlayer playerWithPlayerItem:item];
    _player.muted = NO;
    _player.volume = MediaVolume();
    _player.actionAtItemEnd = AVPlayerActionAtItemEndNone;

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
    _activeSourceName = [NSString stringWithFormat:@"VIDEO  •  %@", videoPath.lastPathComponent];
    Newt_Logf(NEWT_LOG_INFO, "Media player started (%s)", videoPath.UTF8String);
}

- (void)setupCameraIfAuthorized {
    // Only touch AVCaptureDevice ifNSCameraUsageDescription is present in main bundle Info.plist
    // or if authorization is already granted, avoiding macOS TCC abort on unsigned CLI invocations.
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
        if (!self.player) {
            [self setupCameraIfAuthorized];
        }

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
        _player = nil;
    }
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
    if (_sourceMode == 2) return; // Visualizer mode selected
    if (_sourceMode == 0 && _player != nil) return; // Video file has priority in mode 0
    CVImageBufferRef pb = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (!pb || !_manager) return;
    _lastCameraFrameMs = NowMs();
    _manager->PublishCVPixelBuffer(pb,
                                   _activeSourceName ? _activeSourceName.UTF8String : "LIVE CAMERA");
}

- (void)tickFrame {
    _player.volume = MediaVolume();
    if (!_manager) return;

    if (_sourceMode == 0 && _player && _videoOutput) {
        CMTime itemTime = [_videoOutput itemTimeForHostTime:CACurrentMediaTime()];
        if ([_videoOutput hasNewPixelBufferForItemTime:itemTime]) {
            CVPixelBufferRef pb = [_videoOutput copyPixelBufferForItemTime:itemTime
                                                        itemTimeForDisplay:nullptr];
            if (pb) {
                _manager->PublishCVPixelBuffer(pb, _activeSourceName.UTF8String);
                CVPixelBufferRelease(pb);
                return;
            }
        }
    }

    // 2. If camera is active and delivering frames in the last 300ms, let camera callback drive it
    if (_sourceMode != 2 && _cameraSession && (NowMs() - _lastCameraFrameMs) < 300) {
        return;
    }

    // 3. Render live 30 FPS animated Stereo / Media Feed stream so Media tab is always live
    _animPhase += 1.0 / 30.0;
    const double t = _animPhase;

    PixelImage img = MakeImage(^(NSRect bounds) {
        FillRounded(bounds, 24, RGB(0.045f, 0.06f, 0.08f, 0.99f));
        NSColor* white = RGB(0.94f, 0.96f, 0.95f);
        NSColor* cyan = RGB(0.38f, 0.86f, 0.82f);
        NSColor* amber = RGB(0.95f, 0.70f, 0.25f);
        NSColor* muted = RGB(0.60f, 0.66f, 0.70f);

        DrawText(@"Media  •  Live Stereo & Video Feed", NSMakeRect(48, 28, 650, 44), 34, YES, white);

        int mins = static_cast<int>(t) / 60;
        int secs = static_cast<int>(t) % 60;
        int frames = static_cast<int>(std::fmod(t * 30.0, 30.0));
        NSString* tc = [NSString stringWithFormat:@"LIVE 30 FPS  •  %02d:%02d:%02d", mins, secs, frames];
        DrawText(tc, NSMakeRect(680, 36, 296, 30), 20, YES, cyan, NSTextAlignmentRight);

        NSRect leftRect = NSMakeRect(48, 92, 448, 390);
        NSRect rightRect = NSMakeRect(528, 92, 448, 390);
        FillRounded(leftRect, 16, RGB(0.10f, 0.14f, 0.19f));
        FillRounded(rightRect, 16, RGB(0.12f, 0.13f, 0.18f));

        for (int eye = 0; eye < 2; ++eye) {
            NSRect vp = (eye == 0) ? leftRect : rightRect;
            const double parallax = (eye == 0) ? -8.0 : 8.0;
            for (int b = 0; b < 14; ++b) {
                double phase = t * 2.4 + b * 0.42;
                double h = 60.0 + 110.0 * (0.5 + 0.5 * std::sin(phase));
                double x = vp.origin.x + 26.0 + b * 29.0 + parallax * std::cos(t * 1.5);
                double y = vp.origin.y + 210.0 - h * 0.5;
                NSColor* barColor = (eye == 0)
                    ? RGB(0.22f + 0.04f * b, 0.62f, 0.85f, 0.88f)
                    : RGB(0.90f, 0.48f + 0.025f * b, 0.26f, 0.88f);
                FillRounded(NSMakeRect(x, y, 20, h), 6, barColor);
            }
            double rx = vp.origin.x + vp.size.width * 0.5 + std::sin(t * 1.7) * 90.0 + parallax;
            double ry = vp.origin.y + vp.size.height * 0.5 + std::cos(t * 1.2) * 55.0;
            FillRounded(NSMakeRect(rx - 14, ry - 14, 28, 28), 14,
                        (eye == 0) ? cyan : amber);

            DrawText((eye == 0) ? @"LEFT EYE STREAM" : @"RIGHT EYE STREAM",
                     NSMakeRect(vp.origin.x + 20, vp.origin.y + 16, 260, 28),
                     20, YES, white);
        }

        FillRounded(NSMakeRect(48, 502, 928, 76), 12, RGB(0.09f, 0.12f, 0.15f));
        DrawText(@"Drop an .mp4/.mov in ~/Movies (or set NEWT_VIDEO_PATH) for video playback, or connect a camera.",
                 NSMakeRect(68, 514, 888, 28), 19, NO, white);
        DrawText(@"Trigger / Select cycles Media source  •  Menu button toggles Pippin dashboard",
                 NSMakeRect(68, 544, 888, 24), 17, NO, muted);
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
