#ifndef NEWT_INTERNAL_H
#define NEWT_INTERNAL_H
#include "NewtXRApp.h"
#include <deque>
namespace NewtInternal {

struct SimulatedRefused : std::exception {};
bool HasLogHandler();

extern std::atomic_bool gFadeRequested;
void RequestHost(int request);
std::deque<std::string> TakeCommands();
}
#endif
