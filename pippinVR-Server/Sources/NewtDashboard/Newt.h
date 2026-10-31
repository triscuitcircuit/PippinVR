#ifndef NEWT_NEWT_H
#define NEWT_NEWT_H

// SPDX-License-Identifier: MIT


#ifdef __cplusplus
extern "C" {
#endif

int Newt_Run(void);

void Newt_RequestStop(void);

void Newt_Command(const char* command);

int Newt_PollHostRequest(void);

#ifdef __cplusplus
}
#endif

#endif
