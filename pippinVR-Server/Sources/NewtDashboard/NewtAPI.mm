#include "include/NewtLog.h"
#include "NewtInternal.h"
#include "Newt.h"
#import <CoreMediaIO/CMIOHardware.h>
#include <mutex>
#include <iostream>
std::atomic_bool gQuitRequested{false};
namespace NewtInternal {
std::atomic_bool gFadeRequested{false};
namespace {
std::mutex commandMutex;
std::deque<std::string> commands;
std::deque<int> hostRequests;
}
void RequestHost(int request) {
    if (getenv("NEWT_HOST_EVENTS")) {
        std::cout << "NEWT_REQUEST:" << request << "\n" << std::flush;
    } else {
        std::lock_guard<std::mutex> guard(commandMutex);
        if (hostRequests.size() < 16) hostRequests.push_back(request);
    }
}

std::deque<std::string> TakeCommands() {
    std::lock_guard<std::mutex> guard(commandMutex);
    std::deque<std::string> pending;
    pending.swap(commands);
    return pending;
}
}
using namespace NewtInternal;
void HandleSignal(int) { gFadeRequested.store(true); }

extern "C" int Newt_Run(void) {
    @autoreleasepool {
        SetMediaVolume(0.7f);
        CMIOObjectPropertyAddress address = {kCMIOHardwarePropertyAllowScreenCaptureDevices,
            kCMIOObjectPropertyScopeGlobal, kCMIOObjectPropertyElementMain};
        UInt32 enabled = 1;
        CMIOObjectSetPropertyData(kCMIOObjectSystemObject, &address, 0, nullptr, sizeof(enabled), &enabled);
        [NSApplication sharedApplication];
        try {
            { std::lock_guard<std::mutex> guard(commandMutex); hostRequests.clear(); }
            gQuitRequested.store(false);
            gFadeRequested.store(false);
            NewtXR app;
            app.Run();
        } catch (const SimulatedRefused&) {
            return 2;
        } catch (const std::exception& e) {
            Newt_Logf(NEWT_LOG_ERROR, "fatal: %s", e.what());
            return 1;
        }
    }
    return 0;
}

extern "C" void Newt_RequestStop(void) {
    gFadeRequested.store(true);
}

extern "C" void Newt_Command(const char* command) {
    if (!command) return;
    std::lock_guard<std::mutex> guard(commandMutex);
    if (commands.size() < 64) commands.emplace_back(command);
}

extern "C" int Newt_PollHostRequest(void) {
    std::lock_guard<std::mutex> guard(commandMutex);
    if (hostRequests.empty()) return 0;
    int request = hostRequests.front(); hostRequests.pop_front(); return request;
}
