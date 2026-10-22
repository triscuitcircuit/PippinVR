#ifndef NEWT_NEWTLOG_H
#define NEWT_NEWTLOG_H

// SPDX-License-Identifier: MIT
// Public logging hook for embedding Newt.
//
// By default Newt writes log lines to stdout (errors to stderr) with a
// "NewtXR: " prefix. An embedding host (for example Pippin's Logger) can
// install a handler to receive the same messages, unprefixed, on whatever
// thread produced them; messages are serialized and the message pointer is
// only valid for the duration of the call. Installing a handler also marks
// the session as embedded: fatal startup refusals then return from
// Newt_Run() instead of exiting the process.
//
// This hook covers Newt's own log lines only. NEWT_REQUEST host-event
// lines (NEWT_HOST_EVENTS) are a stdout protocol, not logs, and are not
// routed through the handler.

#ifdef __cplusplus
extern "C" {
#endif

enum { NEWT_LOG_DEBUG = 0, NEWT_LOG_INFO = 1, NEWT_LOG_WARNING = 2, NEWT_LOG_ERROR = 3 };

typedef void (*NewtLogHandler)(void* user, int level, const char* message);

// Install a log handler (NULL restores default stdio output). Thread-safe.
void Newt_SetLogHandler(NewtLogHandler handler, void* user);

// Minimum level to emit (default NEWT_LOG_DEBUG). Thread-safe.
void Newt_SetLogLevel(int minimumLevel);

// Emit one formatted log line through the current sink. Hosts may call this
// to keep their own messages in the same stream as Newt's.
void Newt_Logf(int level, const char* format, ...);

#ifdef __cplusplus
}
#endif

#endif  // NEWT_NEWTLOG_H
