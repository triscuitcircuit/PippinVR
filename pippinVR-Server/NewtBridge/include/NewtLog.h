#ifndef NEWT_NEWTLOG_H
#define NEWT_NEWTLOG_H

// SPDX-License-Identifier: MIT
// Public logging hook for embedding Newt.

#ifdef __cplusplus
extern "C" {
#endif

enum { NEWT_LOG_DEBUG = 0, NEWT_LOG_INFO = 1, NEWT_LOG_WARNING = 2, NEWT_LOG_ERROR = 3 };

typedef void (*NewtLogHandler)(void* user, int level, const char* message);

void Newt_SetLogHandler(NewtLogHandler handler, void* user);

void Newt_SetLogLevel(int minimumLevel);

void Newt_Logf(int level, const char* format, ...);

int Newt_IsEmbedded(void);

#ifdef __cplusplus
}
#endif

#endif  // NEWT_NEWTLOG_H
