
#include "Log.h"
#include "Net.h"
#include "XrApp.h"

#include <android_native_app_glue.h>
#include <cstdlib>
#include <memory>
#include <string>
#include <sys/system_properties.h>

namespace {

constexpr const char* kDefaultHost = "127.0.0.1";
constexpr uint16_t kDefaultPort = 9943;

struct AppState {
    pippinvr::XrApp xr;
    std::unique_ptr<pippinvr::StreamClient> client;
    bool resumed = false;
    bool windowReady = false;
};

std::string systemProperty(const char* key, const char* fallback) {
    char value[PROP_VALUE_MAX] = {};
    const int length = __system_property_get(key, value);
    if (length > 0)
        return std::string(value, static_cast<size_t>(length));
    return std::string(fallback);
}

void onAppCmd(android_app* app, int32_t cmd) {
    auto* state = static_cast<AppState*>(app->userData);
    if (state == nullptr)
        return;

    switch (cmd) {
        case APP_CMD_INIT_WINDOW:
            state->windowReady = true;
            break;
        case APP_CMD_TERM_WINDOW:
            state->windowReady = false;
            break;
        case APP_CMD_RESUME:
            state->resumed = true;
            break;
        case APP_CMD_PAUSE:
            state->resumed = false;
            break;
        case APP_CMD_DESTROY:
            state->windowReady = false;
            break;
        default:
            break;
    }
}

}  // namespace

void android_main(android_app* app) {
    AppState state;
    app->userData = &state;
    app->onAppCmd = onAppCmd;

    if (!state.xr.createInstance(app)) {
        LOGE("OpenXR instance creation failed; nothing to do");
        return;
    }

    const std::string host = systemProperty("debug.pippinvr.host", kDefaultHost);
    const uint16_t port =
        static_cast<uint16_t>(std::atoi(systemProperty("debug.pippinvr.port", "9943").c_str()));
    LOGI("server target %s:%u (override with `adb shell setprop debug.pippinvr.host ...`)",
         host.c_str(), port == 0 ? kDefaultPort : port);

    state.client = std::make_unique<pippinvr::StreamClient>(host, port == 0 ? kDefaultPort : port);
    state.client->start(
        [&state](const std::vector<pippinvr::StreamInfo>& streams) { state.xr.onStreams(streams); },
        [&state](pippinvr::FramePacket&& packet) { state.xr.onFrame(std::move(packet)); },
        [&state](const std::vector<pippinvr::StreamInfo>& streams) { state.xr.onStreams(streams); },
        [&state](bool connected, const char* message) {
            state.xr.onConnectionStatus(connected, message);
        });

    bool exitRequested = false;

    while (app->destroyRequested == 0 && !exitRequested) {
        for (;;) {
            android_poll_source* source = nullptr;
            const int timeoutMillis = state.xr.sessionRunning() ? 0 : 250;
            const int result = ALooper_pollOnce(timeoutMillis, nullptr, nullptr,
                                                reinterpret_cast<void**>(&source));
            if (result < 0)
                break;
            if (source != nullptr)
                source->process(app, source);
            if (app->destroyRequested != 0)
                break;
        }
        if (app->destroyRequested != 0)
            break;

        if (state.resumed && state.windowReady && !state.xr.hasSession()) {
            if (!state.xr.createSession()) {
                LOGE("session creation failed");
                break;
            }
        }

        if (state.xr.hasSession()) {
            if (!state.xr.pollEvents(&exitRequested)) {
                if (exitRequested)
                    break;
            }
            state.xr.renderFrame();
        }
    }

    LOGI("shutting down");
    state.client->stop();
    state.client.reset();
    state.xr.destroySession();
}
