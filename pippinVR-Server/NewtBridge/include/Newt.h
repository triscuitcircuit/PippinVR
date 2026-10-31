#ifndef NEWT_NEWT_H
#define NEWT_NEWT_H
#include <stdbool.h>
#include <stdint.h>

#include <CoreFoundation/CoreFoundation.h>

// SPDX-License-Identifier: MIT
// Public C / C++ API for embedding the Newt XR session.

#ifdef __cplusplus
extern "C" {
#endif

// Runs the Newt OpenXR + Vulkan dashboard, screen-sharing, and media session
// until the user selects Exit, the headset disconnects, or Newt_RequestStop() is called.
// Returns 0 on clean exit, non-zero on error.
int Newt_Run(void);

// Requests an active Newt_Run() loop on another thread/signal handler to exit cleanly.
void Newt_RequestStop(void);

// Queues a dashboard command; safe to call from the macOS UI thread.
// Sources: add-screen:N (index), add-display:N (display ID), add-camera:N,
// add-device:ID, add-media, add-media-file:PATH.
// Controls: remove, remove-last, reset, stop, stereo:0..4, notice:TEXT,
// fps:15|30|60, resolution:WIDTH (see supported values in the host settings).
void Newt_Command(const char* command);

// Host requests: 0 none, 1 create display, 2 remove last, 3 choose app, 4 choose media.
int Newt_PollHostRequest(void);

bool Newt_VRMirrorStart(void);
void Newt_VRMirrorStop(void);
CFDataRef Newt_VRMirrorCopy(uint64_t* sequence, uint32_t* width, uint32_t* height,
                            uint32_t* format) CF_RETURNS_RETAINED;

#ifdef __cplusplus
}
#endif

#endif  // NEWT_NEWT_H
