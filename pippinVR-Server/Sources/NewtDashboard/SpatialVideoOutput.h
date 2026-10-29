#ifndef NEWT_SPATIAL_VIDEO_OUTPUT_H
#define NEWT_SPATIAL_VIDEO_OUTPUT_H

#include "Newt/CaptureInternal.h"
#include <cstdint>
#include <string>

#ifdef __OBJC__
#import <AVFoundation/AVFoundation.h>
#endif



void PublishMediaPixelBuffers(MediaCaptureManager* mgr,
                              void* leftPixelBuffer,
                              void* rightPixelBuffer,
                              const std::string& label,
                              int autoStereoMode);

void RemoveMediaState(const MediaCaptureManager* mgr);

bool GetLatestMediaPixelBuffers(const MediaCaptureManager* mgr,
                                uint64_t& lastSeq,
                                RetainedObject& outLeft,
                                RetainedObject& outRight,
                                std::string& outLabel,
                                int& outAutoStereoMode);

#ifdef __OBJC__



id AttachSpatialVideoOutputToPlayer(AVPlayer* player, NSDictionary* pixelBufferAttributes);




bool PollSpatialVideoOutput(id stereoVideoOutput,
                            MediaCaptureManager* mgr,
                            NSString* activeSourceName,
                            BOOL* ioLoggedMVHEVC);
#endif

#endif
