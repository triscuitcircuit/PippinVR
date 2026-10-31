// SPDX-License-Identifier: MIT
#include "HandBenchmark.h"
#include "HandBenchmarkMath.h"
#import <AppKit/AppKit.h>
#import <CoreImage/CoreImage.h>
#import <Vision/Vision.h>
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <ctime>

@interface PippinHandBenchmarkWindow : NSWindowController <NSWindowDelegate>
@property(strong) NSTextField* status;
@property(strong) NSImageView* leftImage;
@property(strong) NSImageView* rightImage;
@property(copy) dispatch_block_t stopAction;
- (void)stopBenchmark:(id)sender;
@end
@implementation PippinHandBenchmarkWindow
- (instancetype)init {
    NSWindow* window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1100, 560)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable
        backing:NSBackingStoreBuffered defer:NO];
    if ((self = [super initWithWindow:window])) {
        window.title = @"Pippin — Hand segmentation benchmark";
        window.releasedWhenClosed = NO;
        window.delegate = self;

        window.sharingType = NSWindowSharingNone;
        _status = [NSTextField wrappingLabelWithString:@"Waiting for headset cameras…"];
        _status.frame = NSMakeRect(20, 445, 1060, 95);
        _status.font = [NSFont systemFontOfSize:15];
        [window.contentView addSubview:_status];
        _leftImage = [[NSImageView alloc] initWithFrame:NSMakeRect(20, 40, 520, 395)];
        _rightImage = [[NSImageView alloc] initWithFrame:NSMakeRect(560, 40, 520, 395)];
        for (NSImageView* view in @[_leftImage, _rightImage]) {
            view.imageScaling = NSImageScaleProportionallyUpOrDown;
            [window.contentView addSubview:view];
        }
        NSTextField* legend = [NSTextField labelWithString:@"Left camera                         Green = selected foreground instance at hand landmarks. No depth or artificial hand shapes.                         Right camera"];
        legend.frame = NSMakeRect(20, 15, 910, 20);
        legend.font = [NSFont systemFontOfSize:10];
        [window.contentView addSubview:legend];
        NSButton* stop = [NSButton buttonWithTitle:@"Stop test" target:self action:@selector(stopBenchmark:)];
        stop.frame = NSMakeRect(970, 10, 110, 28);
        [window.contentView addSubview:stop];
        [window center];
    }
    return self;
}
- (void)stopBenchmark:(id)sender { if (self.stopAction) self.stopAction(); }
- (BOOL)windowShouldClose:(NSWindow*)sender { [self stopBenchmark:nil]; return YES; }
@end

namespace {
int64_t Now() { return static_cast<int64_t>(clock_gettime_nsec_np(CLOCK_MONOTONIC)); }
const char* PhaseName(int phase) { return phase == 0 ? "baseline" : phase == 1 ? "warmup" : "measurement"; }
struct PixelRelease { void operator()(CVPixelBufferRef p) const { if (p) CVPixelBufferRelease(p); } };
using Pixel = std::unique_ptr<__CVBuffer, PixelRelease>;
using SharedPixel = std::shared_ptr<__CVBuffer>;

struct EyeResult {
    __strong NSImage* preview = nil;
    SharedPixel previewPixels;
    const char* status = "ok";
    int hands = 0, selected = 0;
    unsigned weakHands = 0;
    size_t selectedPixels = 0, clippedPixels = 0;
    double resizeMs = 0, poseMs = 0, segmentMs = 0, maskMs = 0, previewMs = 0, readyAgeMs = -1;
    double totalMs = 0;
};
struct Run {
    dispatch_queue_t queue = dispatch_queue_create("pippin.hand-benchmark", DISPATCH_QUEUE_SERIAL);
    __strong CIContext* context = [CIContext contextWithOptions:@{kCIContextCacheIntermediates:@NO}];
    __strong PippinHandBenchmarkWindow* window = nil;
    std::atomic<bool> finished{false}, stopRequested{false}, busy{false}, previewPending{false};
    std::atomic<int64_t> firstFrameNs{0};
    std::atomic<int64_t> lastFrameNs{0};
    int64_t launchedNs = Now(), lastOfferNs = 0, lastPreviewNs = 0;
    std::atomic<uint64_t> offered[3]{}, busyDropped[3]{}, throttled[3]{}, renderFrames[3]{};
    FILE* csv = nullptr;
    __strong NSString* directory = nil;
    unsigned width = 640;
    unsigned rate = 5;
    uint64_t pairIndex = 0;
    std::vector<double> pairTimes, readyAges;
    uint64_t measuredPairs = 0, measuredEyes = 0, matchedEyes = 0, errors = 0;
    uint64_t weakHands = 0, selectedPixels = 0, clippedPixels = 0;
    std::mutex previewMutex;
    SharedPixel headsetPixels[2];
    uint64_t previewSequence = 1;
    int64_t previewPublishedNs = 0;
    std::string headsetStatus = "Waiting for headset cameras. Keep the headset awake.";
    ~Run() { if (csv) fclose(csv); }
};
std::mutex runMutex;
std::shared_ptr<Run> current;
std::shared_ptr<Run> Current() { std::lock_guard<std::mutex> lock(runMutex); return current; }
int PhaseNow(const std::shared_ptr<Run>& run, int64_t now) {
    const auto first = run->firstFrameNs.load();
    return first ? HandBenchmark::Phase(double(now - first) / 1e9) : -1;
}


NSArray<VNHumanHandPoseObservationJointName>* JointOrder() {
    static NSArray* order = @[
        VNHumanHandPoseObservationJointNameWrist,
        VNHumanHandPoseObservationJointNameThumbCMC, VNHumanHandPoseObservationJointNameThumbMP,
        VNHumanHandPoseObservationJointNameThumbIP, VNHumanHandPoseObservationJointNameThumbTip,
        VNHumanHandPoseObservationJointNameIndexMCP, VNHumanHandPoseObservationJointNameIndexPIP,
        VNHumanHandPoseObservationJointNameIndexDIP, VNHumanHandPoseObservationJointNameIndexTip,
        VNHumanHandPoseObservationJointNameMiddleMCP, VNHumanHandPoseObservationJointNameMiddlePIP,
        VNHumanHandPoseObservationJointNameMiddleDIP, VNHumanHandPoseObservationJointNameMiddleTip,
        VNHumanHandPoseObservationJointNameRingMCP, VNHumanHandPoseObservationJointNameRingPIP,
        VNHumanHandPoseObservationJointNameRingDIP, VNHumanHandPoseObservationJointNameRingTip,
        VNHumanHandPoseObservationJointNameLittleMCP, VNHumanHandPoseObservationJointNameLittlePIP,
        VNHumanHandPoseObservationJointNameLittleDIP, VNHumanHandPoseObservationJointNameLittleTip];
    return order;
}


CIImage* RegionImage(const std::vector<uint8_t>& region, size_t width, size_t height) {
    if (region.size() != width * height || !width || !height) return nil;
    NSData* data = [NSData dataWithBytes:region.data() length:region.size()];
    return [CIImage imageWithBitmapData:data bytesPerRow:width size:CGSizeMake(width, height)
                                 format:kCIFormatL8 colorSpace:nil];
}

EyeResult Analyze(CVPixelBufferRef input, int64_t captureNs, bool inference, bool preview,
                  const std::shared_ptr<Run>& run) {
    EyeResult result;
    const int64_t start = Now();
    if (!input || CVPixelBufferGetWidth(input) == 0 || CVPixelBufferGetHeight(input) == 0) {
        result.status = "missing_image";
        return result;
    }
    const double scale = std::min(1.0, double(run->width) / CVPixelBufferGetWidth(input));
    const size_t width = size_t(CVPixelBufferGetWidth(input) * scale);
    const size_t height = size_t(CVPixelBufferGetHeight(input) * scale);
    CVPixelBufferRef resized = nullptr;
    CVReturn rc = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
        (__bridge CFDictionaryRef)@{(id)kCVPixelBufferIOSurfacePropertiesKey:@{},
                                   (id)kCVPixelBufferMetalCompatibilityKey:@YES}, &resized);
    if (rc != kCVReturnSuccess) { result.status = "resize_failed"; return result; }
    Pixel pixels(resized);
    CIImage* original = [CIImage imageWithCVPixelBuffer:input];
    [run->context render:[original imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)]
        toCVPixelBuffer:resized];
    CIImage* source = [CIImage imageWithCVPixelBuffer:resized];
    result.resizeMs = double(Now() - start) / 1e6;
    Pixel mask;
    CIImage* region = nil;
    if (inference) {
      do {
        VNImageRequestHandler* handler = [[VNImageRequestHandler alloc] initWithCVPixelBuffer:resized
            orientation:kCGImagePropertyOrientationUp options:@{}];
        VNDetectHumanHandPoseRequest* pose = [VNDetectHumanHandPoseRequest new];
        pose.revision = VNDetectHumanHandPoseRequestRevision1;
        pose.maximumHandCount = 2;
        NSError* error = nil;
        int64_t began = Now();
        const BOOL poseOK = [handler performRequests:@[pose] error:&error];
        result.poseMs = double(Now() - began) / 1e6;
        if (!poseOK) { result.status = "pose_failed"; break; }
        result.hands = int(pose.results.count);


        VNGenerateForegroundInstanceMaskRequest* request = [VNGenerateForegroundInstanceMaskRequest new];
        request.revision = VNGenerateForegroundInstanceMaskRequestRevision1;
        began = Now();
        const BOOL segmentOK = [handler performRequests:@[request] error:&error];
        result.segmentMs = double(Now() - began) / 1e6;
        if (!segmentOK) { result.status = "segmentation_failed"; break; }
        VNInstanceMaskObservation* observation = request.results.firstObject;
        NSMutableIndexSet* selected = [NSMutableIndexSet indexSet];
        CVPixelBufferRef labels = observation.instanceMask;
        began = Now();
        if (labels && CVPixelBufferGetPixelFormatType(labels) == kCVPixelFormatType_OneComponent8 &&
            CVPixelBufferLockBaseAddress(labels, kCVPixelBufferLock_ReadOnly) == kCVReturnSuccess) {
            std::vector<std::vector<HandBenchmark::Point>> hands;
            for (VNHumanHandPoseObservation* hand in pose.results) {
                std::vector<HandBenchmark::Point> points;
                for (VNHumanHandPoseObservationJointName name in hand.availableJointNames) {
                    VNRecognizedPoint* p = [hand recognizedPointForJointName:name error:nil];
                    NSUInteger joint = [JointOrder() indexOfObject:name];
                    if (p) points.push_back({p.location.x, p.location.y, p.confidence,
                                             joint == NSNotFound ? -1 : int(joint)});
                }
                hands.push_back(std::move(points));
            }
            const auto selection = HandBenchmark::SelectLabels(
                static_cast<const uint8_t*>(CVPixelBufferGetBaseAddress(labels)),
                CVPixelBufferGetWidth(labels), CVPixelBufferGetHeight(labels),
                CVPixelBufferGetBytesPerRow(labels), hands);
            result.weakHands = selection.weakHands;
            result.selectedPixels = selection.selectedPixels;
            result.clippedPixels = selection.clippedPixels;
            region = RegionImage(selection.region, CVPixelBufferGetWidth(labels), CVPixelBufferGetHeight(labels));
            for (size_t label = 1; label < selection.labels.size(); ++label)
                if (selection.labels[label] && [observation.allInstances containsIndex:label]) [selected addIndex:label];
            CVPixelBufferUnlockBaseAddress(labels, kCVPixelBufferLock_ReadOnly);
        } else if (observation) {
            result.status = "unsupported_label_buffer";
        }
        result.selected = int(selected.count);

        if (selected.count) {
            mask.reset([observation generateScaledMaskForImageForInstances:selected fromRequestHandler:handler error:&error]);
            if (!mask) result.status = "mask_failed";
        }
        result.maskMs = double(Now() - began) / 1e6;
        const int64_t ready = Now();
        if (captureNs > 0 && ready >= captureNs && ready - captureNs < 5'000'000'000LL)
            result.readyAgeMs = double(ready - captureNs) / 1e6;
      } while (false);
    }
    if (preview) {
        const int64_t began = Now();
        CIImage* display = source;
        if (mask) {
            CIImage* maskImage = [CIImage imageWithCVPixelBuffer:mask.get()];
            if (region) {

                CIImage* scaled = [region imageByApplyingTransform:CGAffineTransformMakeScale(
                    maskImage.extent.size.width / region.extent.size.width,
                    maskImage.extent.size.height / region.extent.size.height)];
                maskImage = [maskImage imageByApplyingFilter:@"CIMultiplyCompositing"
                                         withInputParameters:@{kCIInputBackgroundImageKey:scaled}];
            }
            CIImage* tint = [[CIImage imageWithColor:[CIColor colorWithRed:0 green:1 blue:0.4 alpha:0.5]]
                imageByCroppingToRect:source.extent];
            tint = [tint imageByCompositingOverImage:source];
            display = [tint imageByApplyingFilter:@"CIBlendWithMask" withInputParameters:@{
                kCIInputBackgroundImageKey:source, kCIInputMaskImageKey:maskImage}];
        }
        CVPixelBufferRef headset = nullptr;
        if (CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
            (__bridge CFDictionaryRef)@{(id)kCVPixelBufferIOSurfacePropertiesKey:@{},
                                       (id)kCVPixelBufferMetalCompatibilityKey:@YES}, &headset) == kCVReturnSuccess) {
            result.previewPixels = SharedPixel(headset, PixelRelease{});
            [run->context render:display toCVPixelBuffer:headset];

            display = [CIImage imageWithCVPixelBuffer:headset];
        }
        CGImageRef image = [run->context createCGImage:display fromRect:source.extent];
        if (image) {
            result.preview = [[NSImage alloc] initWithCGImage:image size:NSZeroSize];
            CGImageRelease(image);
        }
        result.previewMs = double(Now() - began) / 1e6;
    }
    result.totalMs = double(Now() - start) / 1e6;
    return result;
}

double CutPercent(const EyeResult (&results)[2]) {
    const size_t selected = results[0].selectedPixels + results[1].selectedPixels;
    return selected ? 100.0 * double(results[0].clippedPixels + results[1].clippedPixels) / selected : 0.0;
}



void Finish(std::shared_ptr<Run> run, const char* reason) {
    if (run->finished.exchange(true)) return;
    {
        std::lock_guard<std::mutex> lock(run->previewMutex);
        run->headsetPixels[0].reset(); run->headsetPixels[1].reset();
        run->headsetStatus = "Test ended. Saving timing results; no images recorded.";
        ++run->previewSequence;
    }
    const int64_t finishedAt = Now();
    const std::string why(reason);
    dispatch_async(run->queue, ^{
        @autoreleasepool {
            const int64_t first = run->firstFrameNs.load();
            const double elapsed = first ? std::max(0.0, double(finishedAt - first) / 1e9) : 0;
            NSMutableArray* phases = [NSMutableArray array];
            const double starts[3] = {0, 10, 15}, lengths[3] = {10, 5, 60};
            for (int i = 0; i < 3; ++i) {
                const double duration = std::clamp(elapsed - starts[i], 0.0, lengths[i]);
                [phases addObject:@{@"phase":@(PhaseName(i)), @"seconds":@(duration),
                    @"camera_pairs_offered":@(run->offered[i].load()),
                    @"pairs_skipped_busy":@(run->busyDropped[i].load()),
                    @"pairs_skipped_rate_limit":@(run->throttled[i].load()),
                    @"renderable_callbacks_per_second":duration > 0 ? @(run->renderFrames[i].load() / duration) : (id)[NSNull null]}];
            }
            NSDictionary* summary = @{@"schema":@4, @"reason":@(why.c_str()),
                @"preview_location":@"headset_and_mac",
                @"model":@"Apple Vision foreground instances + hand landmark selection",
                @"selection_filter":@"joint_agreement_and_hand_region_cut_v2",
                @"selection_min_joint_confidence":@(HandBenchmark::SelectionConfidence),
                @"selection_min_joint_votes":@(HandBenchmark::MinimumJointVotes),
                @"selection_min_joint_agreement":@(HandBenchmark::MinimumJointAgreement),
                @"region_palm_lengths":@{@"finger":@(HandBenchmark::FingerReach), @"palm":@(HandBenchmark::PalmReach),
                    @"forearm_radius":@(HandBenchmark::ForearmReach), @"forearm_length":@(HandBenchmark::ForearmLength),
                    @"feather":@(HandBenchmark::RegionFeather)},
                @"hands_rejected_weak_support":@(run->weakHands),
                @"selected_pixels_cut_fraction":run->selectedPixels ? @(double(run->clippedPixels) / run->selectedPixels) : (id)[NSNull null],
                @"input_width_limit":@(run->width), @"pair_rate_limit_hz":@(run->rate),
                @"preview_rate_limit_hz":@2, @"camera_images_saved":@NO,
                @"measures_depth":@NO, @"measures_motion_to_photon":@NO,
                @"os":NSProcessInfo.processInfo.operatingSystemVersionString,
                @"processor_count":@(NSProcessInfo.processInfo.processorCount),
                @"physical_memory_bytes":@(NSProcessInfo.processInfo.physicalMemory),
                @"hand_pose_revision":@1, @"foreground_mask_revision":@1,
                @"phases":phases, @"measured_pairs":@(run->measuredPairs),
                @"successful_pairs":@(run->pairTimes.size()),
                @"measured_eyes":@(run->measuredEyes), @"eyes_with_selected_instance":@(run->matchedEyes),
                @"eye_processing_errors":@(run->errors),
                @"pair_processing_ms_p50":run->pairTimes.empty() ? (id)[NSNull null] : @(HandBenchmark::Percentile(run->pairTimes, 0.5)),
                @"pair_processing_ms_p95":run->pairTimes.empty() ? (id)[NSNull null] : @(HandBenchmark::Percentile(run->pairTimes, 0.95)),
                @"valid_capture_age_samples":@(run->readyAges.size()),
                @"mask_ready_age_ms_p95":run->readyAges.empty() ? (id)[NSNull null] : @(HandBenchmark::Percentile(run->readyAges, 0.95))};
            NSError* error = nil;
            NSData* data = [NSJSONSerialization dataWithJSONObject:summary options:NSJSONWritingPrettyPrinted error:&error];
            BOOL saved = data && [data writeToFile:[run->directory stringByAppendingPathComponent:@"summary.json"]
                options:NSDataWritingAtomic error:&error];
            NSString* duration = run->pairTimes.empty() ? @"No successful measurement samples" :
                [NSString stringWithFormat:@"Stereo processing: median %.1f ms; 95th percentile %.1f ms",
                    HandBenchmark::Percentile(run->pairTimes, 0.5), HandBenchmark::Percentile(run->pairTimes, 0.95)];
            NSString* report = [NSString stringWithFormat:
                @"Pippin hand segmentation benchmark\nResult: %s\n%@\nMeasured pairs: %llu; processing errors: %llu eyes\nEyes with a hand-associated foreground region: %llu / %llu\n\n"
                 "The region count is not an accuracy score. Inspect finger gaps, missing highlights and any objects included in green.\n"
                 "Selected instances are cut to soft regions around each hand's landmarks (fingers, palm, short forearm); outlines near the hand come from the camera-derived mask. Held objects inside the region stay selected.\n"
                 "See summary.json for baseline/measurement render callback rates and mask readiness. These are not measured headset FPS or motion-to-photon latency.\n"
                 "No depth test was performed. No camera images were saved.\n",
                why.c_str(), duration, (unsigned long long)run->measuredPairs, (unsigned long long)run->errors,
                (unsigned long long)run->matchedEyes, (unsigned long long)run->measuredEyes];
            [report writeToFile:[run->directory stringByAppendingPathComponent:@"summary.txt"] atomically:YES
                encoding:NSUTF8StringEncoding error:nil];
            if (run->csv) { fflush(run->csv); fclose(run->csv); run->csv = nullptr; }
            NSLog(@"Hand benchmark finished (%s). Results: %@; summary saved=%d", why.c_str(), run->directory, saved);
            NSString* explanation = @"The headset session ended.";
            if (why == "completed") explanation = @"The 75-second test is complete.";
            else if (why == "stopped_by_user") explanation = @"You stopped the test.";
            else if (why == "no_camera_frames") explanation = @"No camera frames arrived. Check USB Link and camera access, then restart the test.";
            else if (why == "camera_frames_stalled") explanation = @"Camera frames stopped arriving. Keep the headset awake and restart the test.";
            else if (why.find("camera_access_disabled") == 0) explanation = @"Enable Headset camera access in Pippin settings, then restart the test.";
            {
                std::lock_guard<std::mutex> lock(run->previewMutex);
                run->headsetStatus = explanation.UTF8String;
                run->headsetStatus += " Results are on the Mac. You can quit Pippin now.";
                ++run->previewSequence;
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                run->window.leftImage.image = nil;
                run->window.rightImage.image = nil;
                run->window.status.stringValue = [NSString stringWithFormat:
                    @"Test ended. %@\n%@\n%@",
                    explanation, duration, saved ? [@"Results: " stringByAppendingString:run->directory] : @"Could not save the summary; check the launcher output."];
            });
        }
    });
}
}

bool HandBenchmarkEnabled() {
    const char* value = getenv("PIPPIN_HAND_BENCHMARK");
    return value && std::strcmp(value, "1") == 0;
}
void HandBenchmarkStart(bool cameraAllowed) {
    if (!HandBenchmarkEnabled()) return;
    HandBenchmarkStop();
    auto run = std::make_shared<Run>();
    const char* directory = getenv("PIPPIN_HAND_BENCHMARK_DIR");
    if (!directory || !*directory) {
        NSLog(@"Hand benchmark requires the benchmark launcher (missing results directory).");
        return;
    }
    run->directory = [NSString stringWithUTF8String:directory];
    const char* width = getenv("PIPPIN_HAND_BENCHMARK_WIDTH");
    if (width && std::strcmp(width, "1280") == 0) run->width = 1280;
    else if (width && std::strcmp(width, "960") == 0) run->width = 960;
    const char* rate = getenv("PIPPIN_HAND_BENCHMARK_HZ");
    if (rate && std::strcmp(rate, "15") == 0) run->rate = 15;
    else if (rate && std::strcmp(rate, "30") == 0) run->rate = 30;
    NSError* error = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtPath:run->directory withIntermediateDirectories:YES attributes:nil error:&error]) {
        NSLog(@"Hand benchmark cannot create results directory: %@", error); return;
    }

    run->csv = fopen([[run->directory stringByAppendingPathComponent:@"samples.csv"] fileSystemRepresentation], "wx");
    if (!run->csv) { NSLog(@"Hand benchmark cannot create samples.csv"); return; }
    fputs("phase,pair,eye,elapsed_s,capture_ns,status,hands,selected_instances,resize_ms,pose_ms,segmentation_ms,mask_ms,preview_ms,total_ms,mask_ready_age_ms,weak_hand_rejections,cut_fraction\n", run->csv);
    fflush(run->csv);
    { std::lock_guard<std::mutex> lock(runMutex); current = run; }
    dispatch_async(dispatch_get_main_queue(), ^{
        run->window = [PippinHandBenchmarkWindow new];
        std::weak_ptr<Run> weak = run;
        run->window.stopAction = ^{ if (auto active = weak.lock()) active->stopRequested = true; };
        [run->window showWindow:nil];
        [run->window.window makeKeyAndOrderFront:nil];
        run->window.status.stringValue = @"Waiting for headset cameras (up to 60 seconds).\nCamera-only baseline 10 s → warmup 5 s → hand test 60 s. No images are recorded.\nThe preview is also shown in the headset. Put down the controllers when the hand test begins.";
    });
    if (!cameraAllowed) Finish(run, "camera_access_disabled_enable_in_Pippin_settings_and_restart");
}
bool HandBenchmarkNeedsFrames() {
    auto run = Current();
    return run && !run->finished && !run->stopRequested;
}
void HandBenchmarkTick() {
    auto run = Current();
    if (!run || run->finished) return;
    const int64_t first = run->firstFrameNs.load();
    if (run->stopRequested) Finish(run, "stopped_by_user");
    else if (!first && Now() - run->launchedNs >= 60'000'000'000LL) Finish(run, "no_camera_frames");
    else if (first && Now() - first >= 75'000'000'000LL) Finish(run, "completed");
    else if (first && Now() - run->lastFrameNs >= 3'000'000'000LL) Finish(run, "camera_frames_stalled");
}
void HandBenchmarkRenderFrame(bool shouldRender) {
    auto run = Current();
    if (!run || run->finished || !shouldRender) return;
    const int phase = PhaseNow(run, Now());
    if (phase >= 0) ++run->renderFrames[phase];
}
void HandBenchmarkSubmit(CVPixelBufferRef left, CVPixelBufferRef right, int64_t captureNs) {
    auto run = Current();
    if (!run || run->finished || run->stopRequested || !left || !right) return;
    const int64_t now = Now();
    if (!run->firstFrameNs) run->firstFrameNs = now;
    run->lastFrameNs = now;
    const int phase = PhaseNow(run, now);
    if (phase < 0) return;
    ++run->offered[phase];
    if (now - run->lastOfferNs < int64_t(1'000'000'000 / run->rate)) { ++run->throttled[phase]; return; }
    if (run->busy.exchange(true)) { ++run->busyDropped[phase]; return; }
    run->lastOfferNs = now;

    const bool preview = now - run->lastPreviewNs >= 500'000'000LL;
    if (preview) run->lastPreviewNs = now;
    CVPixelBufferRetain(left); CVPixelBufferRetain(right);
    dispatch_async(run->queue, ^{
        @autoreleasepool {
            Pixel ownedLeft(left), ownedRight(right);
            EyeResult results[2];
            const int64_t begin = Now();
            @try {
                results[0] = Analyze(left, captureNs, phase != 0, preview, run);
                results[1] = Analyze(right, captureNs, phase != 0, preview, run);
            } @catch (NSException* exception) {
                results[0].status = results[1].status = "vision_exception";
                NSLog(@"Hand benchmark Vision exception: %@", exception.name);
            }
            const double pairMs = double(Now() - begin) / 1e6;
            const uint64_t pair = ++run->pairIndex;
            for (int eye = 0; eye < 2; ++eye) {
                const auto& r = results[eye];
                if (run->csv) {
                    fprintf(run->csv, "%s,%llu,%d,%.4f,%lld,%s,%d,%d,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,",
                        PhaseName(phase), (unsigned long long)pair, eye, double(now - run->firstFrameNs) / 1e9,
                        (long long)captureNs, r.status, r.hands, r.selected, r.resizeMs, r.poseMs, r.segmentMs,
                        r.maskMs, r.previewMs, r.totalMs);
                    if (r.readyAgeMs >= 0) fprintf(run->csv, "%.3f", r.readyAgeMs);
                    fprintf(run->csv, ",%u,", r.weakHands);
                    if (r.selectedPixels) fprintf(run->csv, "%.3f", double(r.clippedPixels) / r.selectedPixels);
                    fputc('\n', run->csv);
                }
                if (phase == 2) {
                    ++run->measuredEyes;
                    run->weakHands += r.weakHands;
                    run->selectedPixels += r.selectedPixels;
                    run->clippedPixels += r.clippedPixels;
                    if (r.selected && std::strcmp(r.status, "ok") == 0) ++run->matchedEyes;
                    if (std::strcmp(r.status, "ok") != 0) ++run->errors;
                    if (r.readyAgeMs >= 0 && r.selected) run->readyAges.push_back(r.readyAgeMs);
                }
            }
            if (phase == 2) {
                ++run->measuredPairs;
                if (std::strcmp(results[0].status, "ok") == 0 && std::strcmp(results[1].status, "ok") == 0)
                    run->pairTimes.push_back(pairMs);
            }
            if (run->csv) fflush(run->csv);
            if (preview) {
                NSImage* a = results[0].preview;
                NSImage* b = results[1].preview;
                const double elapsed = double(now - run->firstFrameNs) / 1e9;
                NSString* instruction = phase == 0 ? @"Camera-only baseline — keep the headset awake." : phase == 1 ? @"Warming up Vision — put down the controllers." :
                    elapsed < 30 ? @"Spread fingers, turn palms, then make a fist." : elapsed < 45 ? @"Overlap hands and separate them. Check finger gaps." : elapsed < 60 ? @"Move fingers quickly, then move your head gently." : @"Hold a mug or controller. Check whether its pixels get selected too.";
                NSString* text = [NSString stringWithFormat:
                    @"%s • %.0f / 75 seconds • %@\nLeft: %d hands, %d selected (%s). Right: %d hands, %d selected (%s). Pair work: %.1f ms.\nHand-region cut: %u weak hand matches rejected; %.0f%% of selected pixels cut away (arm, body, distant objects). Check for missing green as well as extra objects. Preview: 2 Hz.",
                    PhaseName(phase), elapsed, instruction, results[0].hands, results[0].selected, results[0].status,
                    results[1].hands, results[1].selected, results[1].status, pairMs,
                    results[0].weakHands + results[1].weakHands, CutPercent(results)];
                {
                    std::lock_guard<std::mutex> lock(run->previewMutex);
                    if (!run->finished) {
                        run->headsetPixels[0] = results[0].previewPixels;
                        run->headsetPixels[1] = results[1].previewPixels;
                        run->previewPublishedNs = Now();
                        NSString* status = [NSString stringWithFormat:@"%.0f / 75 s — %@ Green: %d left / %d right regions. %u weak matches rejected; %.0f%% cut outside the hands. %@",
                            elapsed, instruction, results[0].selected, results[1].selected,
                            results[0].weakHands + results[1].weakHands, CutPercent(results),
                            results[0].previewPixels && results[1].previewPixels ? @"" : @"Preview unavailable; check Mac diagnostics."];
                        run->headsetStatus = status.UTF8String;
                        ++run->previewSequence;
                    }
                }
                if (!run->previewPending.exchange(true)) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (!run->finished) {
                        run->window.leftImage.image = a;
                        run->window.rightImage.image = b;
                        run->window.status.stringValue = text;
                    }
                    run->previewPending = false;
                });
                }
            }
            run->busy = false;
        }
    });
}
void HandBenchmarkStop() {
    auto run = Current();
    if (!run) return;
    Finish(run, "session_ended");


    dispatch_sync(run->queue, ^{});
    { std::lock_guard<std::mutex> lock(runMutex); if (current == run) current.reset(); }
}

bool HandBenchmarkCopyPreview(uint64_t& sequence, CVPixelBufferRef& left, CVPixelBufferRef& right,
                              std::string& status) {
    left = right = nullptr;
    auto run = Current();
    if (!run) return false;
    std::lock_guard<std::mutex> lock(run->previewMutex);
    if ((run->headsetPixels[0] || run->headsetPixels[1]) && Now() - run->previewPublishedNs > 2'000'000'000LL) {
        run->headsetPixels[0].reset(); run->headsetPixels[1].reset();
        run->headsetStatus = "Waiting for a fresh camera preview. Old images hidden.";
        ++run->previewSequence;
    }
    if (sequence == run->previewSequence) return false;
    sequence = run->previewSequence;
    if (run->headsetPixels[0]) left = CVPixelBufferRetain(run->headsetPixels[0].get());
    if (run->headsetPixels[1]) right = CVPixelBufferRetain(run->headsetPixels[1].get());
    status = run->headsetStatus;
    return true;
}

#ifdef PIPPIN_HAND_BENCHMARK_TEST
#include <cassert>
int main() {
    @autoreleasepool {
        auto run = std::make_shared<Run>();
        CVPixelBufferRef raw = nullptr;
        if (CVPixelBufferCreate(kCFAllocatorDefault, 640, 480, kCVPixelFormatType_32BGRA, nullptr, &raw)) return 1;
        Pixel pixels(raw);
        CVPixelBufferLockBaseAddress(raw, 0);
        memset(CVPixelBufferGetBaseAddress(raw), 0, CVPixelBufferGetDataSize(raw));
        CVPixelBufferUnlockBaseAddress(raw, 0);
        EyeResult result = Analyze(raw, Now(), true, true, run);
        fprintf(stderr, "Vision blank-frame smoke: status=%s hands=%d selected=%d preview=%d\n",
                result.status, result.hands, result.selected, result.preview != nil);
        if (std::strcmp(result.status, "ok") != 0 || result.selected != 0 || !result.preview) return 1;
        NSString* directory = [NSTemporaryDirectory() stringByAppendingPathComponent:
            [@"pippin-hand-smoke-" stringByAppendingString:NSUUID.UUID.UUIDString]];
        setenv("PIPPIN_HAND_BENCHMARK", "1", 1);
        setenv("PIPPIN_HAND_BENCHMARK_DIR", directory.fileSystemRepresentation, 1);
        HandBenchmarkStart(true);
        auto active = Current();
        assert(active && HandBenchmarkNeedsFrames());
        active->firstFrameNs = Now() - 16'000'000'000LL;
        HandBenchmarkSubmit(raw, raw, Now());
        HandBenchmarkSubmit(raw, raw, Now());
        dispatch_sync(active->queue, ^{});
        uint64_t previewSequence = 0;
        CVPixelBufferRef previewLeft = nullptr, previewRight = nullptr;
        std::string previewStatus;
        assert(HandBenchmarkCopyPreview(previewSequence, previewLeft, previewRight, previewStatus));


        assert(previewLeft && previewRight && CVPixelBufferGetWidth(previewLeft) == 640);
        assert(previewStatus.find("Green: 0 left / 0 right") != std::string::npos);
        {
            std::lock_guard<std::mutex> lock(active->previewMutex);
            active->previewPublishedNs = Now() - 3'000'000'000LL;
        }
        CVPixelBufferRef staleLeft = nullptr, staleRight = nullptr;
        assert(HandBenchmarkCopyPreview(previewSequence, staleLeft, staleRight, previewStatus));
        assert(!staleLeft && !staleRight);
        HandBenchmarkStop();

        assert(CVPixelBufferGetWidth(previewLeft) == 640 && CVPixelBufferGetWidth(previewRight) == 640);
        CVPixelBufferRelease(previewLeft); CVPixelBufferRelease(previewRight);
        assert(!HandBenchmarkNeedsFrames());
        NSDictionary* summary = [NSJSONSerialization JSONObjectWithData:
            [NSData dataWithContentsOfFile:[directory stringByAppendingPathComponent:@"summary.json"]]
            options:0 error:nil];
        assert([summary[@"measured_pairs"] unsignedIntValue] == 1);
        assert([summary[@"successful_pairs"] unsignedIntValue] == 1);
        assert([summary[@"eyes_with_selected_instance"] unsignedIntValue] == 0);
        assert([summary[@"schema"] unsignedIntValue] == 4);
        assert([summary[@"hands_rejected_weak_support"] unsignedIntValue] == 0);
        assert(summary[@"selected_pixels_cut_fraction"] == [NSNull null]);
        assert([summary[@"selection_min_joint_votes"] unsignedIntValue] == HandBenchmark::MinimumJointVotes);
        NSString* csv = [NSString stringWithContentsOfFile:[directory stringByAppendingPathComponent:@"samples.csv"]
            encoding:NSUTF8StringEncoding error:nil];
        NSArray<NSString*>* rows = [csv componentsSeparatedByString:@"\n"];
        assert([rows[0] hasSuffix:@"weak_hand_rejections,cut_fraction"]);
        assert([rows[1] componentsSeparatedByString:@","].count == [rows[0] componentsSeparatedByString:@","].count);
        assert([summary[@"reason"] isEqualToString:@"session_ended"]);
        NSArray* files = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:directory error:nil];
        assert(files.count == 3);
        NSString* denied = [directory stringByAppendingPathComponent:@"permission-disabled"];
        setenv("PIPPIN_HAND_BENCHMARK_DIR", denied.fileSystemRepresentation, 1);
        HandBenchmarkStart(false);
        assert(!HandBenchmarkNeedsFrames());
        HandBenchmarkStop();
        fprintf(stderr, "PASS: worker ownership, bounded queue, independent headset preview, no-mask fallback, stale clearing, report, access gate. Results: %s\n",
                directory.fileSystemRepresentation);
        return 0;
    }
}
#endif
