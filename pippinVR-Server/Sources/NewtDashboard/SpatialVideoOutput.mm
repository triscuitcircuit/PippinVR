#include "SpatialVideoOutput.h"
#include "include/NewtLog.h"
#import <AVFoundation/AVPlayerOutput.h>
#import <CoreMedia/CMTag.h>
#import <CoreMedia/CMTagCollection.h>
#import <CoreMedia/CMTaggedBufferGroup.h>
#import <VideoToolbox/VideoToolbox.h>
#include <cstring>
#include <memory>
#include <mutex>
#include <unordered_map>

using namespace NewtCaptureInternal;

namespace {

struct MediaStereoState {
    std::mutex mutex;
    uint64_t seq = 0;
    RetainedObject leftBuffer;
    RetainedObject rightBuffer;
    std::string label;
    int autoStereoMode = 0;
};

std::mutex gMediaStateRegistryMutex;
std::unordered_map<const MediaCaptureManager*, std::shared_ptr<MediaStereoState>> gMediaStates;

std::shared_ptr<MediaStereoState> GetOrCreateMediaState(const MediaCaptureManager* mgr) {
    std::lock_guard<std::mutex> lock(gMediaStateRegistryMutex);
    auto& st = gMediaStates[mgr];
    if (!st) st = std::make_shared<MediaStereoState>();
    return st;
}

}

void RemoveMediaState(const MediaCaptureManager* mgr) {
    std::lock_guard<std::mutex> lock(gMediaStateRegistryMutex);
    gMediaStates.erase(mgr);
}

void PublishMediaPixelBuffers(MediaCaptureManager* mgr,
                              void* leftPixelBuffer,
                              void* rightPixelBuffer,
                              const std::string& label,
                              int autoStereoMode) {
    auto leftPB = static_cast<CVPixelBufferRef>(leftPixelBuffer);
    auto rightPB = static_cast<CVPixelBufferRef>(rightPixelBuffer);
    if (!mgr || !leftPB) return;
    const char* option = std::getenv("NEWT_GPU_CAPTURE");
    const bool gpu = !option || std::strcmp(option, "0") != 0;
    const bool leftOK = (CVPixelBufferGetPixelFormatType(leftPB) == kCVPixelFormatType_32BGRA &&
                         CVPixelBufferGetIOSurface(leftPB) != nullptr);
    const bool rightOK = (!rightPB ||
                          (CVPixelBufferGetPixelFormatType(rightPB) == kCVPixelFormatType_32BGRA &&
                           CVPixelBufferGetIOSurface(rightPB) != nullptr));
    if (gpu && leftOK && rightOK) {
        auto st = GetOrCreateMediaState(mgr);
        std::lock_guard<std::mutex> lock(st->mutex);
        st->leftBuffer.reset(CVPixelBufferRetain(leftPB));
        if (rightPB) {
            st->rightBuffer.reset(CVPixelBufferRetain(rightPB));
        } else {
            st->rightBuffer.reset();
        }
        st->label = label;
        st->autoStereoMode = autoStereoMode;
        st->seq++;
    } else {
        mgr->PublishCVPixelBuffer(leftPB, label);
    }
}

bool GetLatestMediaPixelBuffers(const MediaCaptureManager* mgr,
                                uint64_t& lastSeq,
                                RetainedObject& outLeft,
                                RetainedObject& outRight,
                                std::string& outLabel,
                                int& outAutoStereoMode) {
    if (!mgr) return false;
    std::shared_ptr<MediaStereoState> st;
    {
        std::lock_guard<std::mutex> lock(gMediaStateRegistryMutex);
        auto it = gMediaStates.find(mgr);
        if (it == gMediaStates.end()) return false;
        st = it->second;
    }
    std::lock_guard<std::mutex> lock(st->mutex);
    if (st->seq == 0 || st->seq == lastSeq || !st->leftBuffer) return false;
    outLeft.reset(CVPixelBufferRetain(static_cast<CVPixelBufferRef>(st->leftBuffer.get())));
    if (st->rightBuffer) {
        outRight.reset(CVPixelBufferRetain(static_cast<CVPixelBufferRef>(st->rightBuffer.get())));
    } else {
        outRight.reset();
    }
    outLabel = st->label;
    outAutoStereoMode = st->autoStereoMode;
    lastSeq = st->seq;
    return true;
}

id AttachSpatialVideoOutputToPlayer(AVPlayer* player, NSDictionary* pixelBufferAttributes) {
    if (!player) return nil;
    if (@available(macOS 14.2, *)) {
        CMTagCollectionRef stereoTags = nullptr;
        CMTagCollectionRef monoTags = nullptr;
        CMTagCollectionCreateWithVideoOutputPreset(kCFAllocatorDefault,
                                                   kCMTagCollectionVideoOutputPreset_Stereoscopic,
                                                   &stereoTags);
        CMTagCollectionCreateWithVideoOutputPreset(kCFAllocatorDefault,
                                                   kCMTagCollectionVideoOutputPreset_Monoscopic,
                                                   &monoTags);
        NSMutableArray* tagCollections = [NSMutableArray array];
        if (stereoTags) [tagCollections addObject:(__bridge id)stereoTags];
        if (monoTags) [tagCollections addObject:(__bridge id)monoTags];
        AVPlayerVideoOutput* playerOut = nil;
        if (tagCollections.count > 0) {
            AVVideoOutputSpecification* spec =
                [[AVVideoOutputSpecification alloc] initWithTagCollections:tagCollections];
            #pragma clang diagnostic push
            #pragma clang diagnostic ignored "-Wdeprecated-declarations"
            spec.defaultPixelBufferAttributes = pixelBufferAttributes;
            #pragma clang diagnostic pop
            playerOut = [[AVPlayerVideoOutput alloc] initWithSpecification:spec];
            player.videoOutput = playerOut;
        }
        if (stereoTags) CFRelease(stereoTags);
        if (monoTags) CFRelease(monoTags);
        return playerOut;
    }
    return nil;
}

bool PollSpatialVideoOutput(id stereoVideoOutput,
                            MediaCaptureManager* mgr,
                            NSString* activeSourceName,
                            BOOL* ioLoggedMVHEVC) {
    if (!stereoVideoOutput || !mgr) return false;
    if (@available(macOS 14.2, *)) {
        AVPlayerVideoOutput* playerOut = (AVPlayerVideoOutput*)stereoVideoOutput;
        CMTime hostTime = CMClockGetTime(CMClockGetHostTimeClock());
        CMTaggedBufferGroupRef group =
            [playerOut copyTaggedBufferGroupForHostTime:hostTime
                                  presentationTimeStamp:nullptr
                                    activeConfiguration:nullptr];
        if (!group) return false;

        const CFIndex count = CMTaggedBufferGroupGetCount(group);
        if (count >= 2) {
            CVPixelBufferRef leftPB =
                CMTaggedBufferGroupGetCVPixelBufferForTag(group, kCMTagStereoLeftEye, nullptr);
            CVPixelBufferRef rightPB =
                CMTaggedBufferGroupGetCVPixelBufferForTag(group, kCMTagStereoRightEye, nullptr);
            if (!leftPB) leftPB = CMTaggedBufferGroupGetCVPixelBufferAtIndex(group, 0);
            if (!rightPB) rightPB = CMTaggedBufferGroupGetCVPixelBufferAtIndex(group, 1);
            if (leftPB && rightPB) {
                if (ioLoggedMVHEVC && !*ioLoggedMVHEVC) {
                    *ioLoggedMVHEVC = YES;
                    Newt_Logf(NEWT_LOG_INFO,
                              "MV-HEVC Spatial Video active (%zux%zu per eye)",
                              CVPixelBufferGetWidth(leftPB),
                              CVPixelBufferGetHeight(leftPB));
                }
                NSString* mvLabel = [(activeSourceName ?: @"VIDEO")
                    stringByReplacingOccurrencesOfString:@"VIDEO  •  "
                                              withString:@"MV-HEVC 3D  •  "];
                PublishMediaPixelBuffers(mgr, leftPB, rightPB, mvLabel.UTF8String, 0);
                CFRelease(group);
                return true;
            }
        } else if (count == 1) {
            CVPixelBufferRef pb = CMTaggedBufferGroupGetCVPixelBufferAtIndex(group, 0);
            if (pb) {
                int autoStereo = 0;
                CMTagCollectionRef tags = CMTaggedBufferGroupGetTagCollectionAtIndex(group, 0);
                if (tags) {
                    if (CMTagCollectionContainsTag(tags, kCMTagPackingTypeSideBySide)) {
                        autoStereo = 1;
                    } else if (CMTagCollectionContainsTag(tags, kCMTagPackingTypeOverUnder)) {
                        autoStereo = 3;
                    }
                }
                PublishMediaPixelBuffers(mgr,
                                         pb,
                                         nullptr,
                                         activeSourceName ? activeSourceName.UTF8String : "VIDEO",
                                         autoStereo);
                CFRelease(group);
                return true;
            }
        }
        CFRelease(group);
    }
    return false;
}
