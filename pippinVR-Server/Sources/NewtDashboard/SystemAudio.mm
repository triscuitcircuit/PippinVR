// SPDX-License-Identifier: MIT


#include "SystemAudio.h"
#include "AudioSamples.h"
#include "NewtXRApp.h"
#include "NewtInternal.h"
#include "include/NewtLog.h"
#import <AVFoundation/AVFoundation.h>
#import <AudioToolbox/AudioServices.h>
#import <CoreAudio/AudioHardware.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#import <CoreGraphics/CoreGraphics.h>
#import <CoreMedia/CoreMedia.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdarg>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>
#include <libproc.h>
#include <unistd.h>
#include <mach-o/dyld.h>
#include <mutex>
#include <unordered_map>
#include <vector>

namespace {
constexpr double kRate = 48000;
constexpr AVAudioFrameCount kBlock = 480;
constexpr size_t kMaxQueued = size_t(kRate) / 5;


constexpr auto kHeadsetGone = std::chrono::seconds(3);
constexpr int kTapRetries = 3;
constexpr int kSlots = 8;
constexpr auto kAppQuiet = std::chrono::seconds(5);
constexpr int64_t kPollNs = NSEC_PER_SEC / 2;

NSURL* SettingsURL() {
    NSString* root = nil;
    if (const char* value = std::getenv("NEWT_STATE_DIR")) root = [NSString stringWithUTF8String:value];
    if (!root.length) root = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Newt"];
    return [[NSURL fileURLWithPath:root isDirectory:YES] URLByAppendingPathComponent:@"audio.json"];
}

NSDictionary* ReadSettingsJSON() {
    NSData* data = [NSData dataWithContentsOfURL:SettingsURL()];
    id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [json isKindOfClass:[NSDictionary class]] ? json : @{};
}



void Log(int level, const char* format, ...) __attribute__((format(printf, 2, 3)));
void Log(int level, const char* format, ...) {
    char text[1024];
    va_list args;
    va_start(args, format);
    std::vsnprintf(text, sizeof(text), format, args);
    va_end(args);
    Newt_Logf(level, "%s", text);
    static FILE* file = [] {
        NSURL* url = [SettingsURL().URLByDeletingLastPathComponent URLByAppendingPathComponent:@"audio.log"];
        return std::fopen(url.fileSystemRepresentation, "w");
    }();
    if (!file) return;
    NSString* stamp = [NSISO8601DateFormatter stringFromDate:[NSDate date] timeZone:[NSTimeZone localTimeZone]
                                               formatOptions:NSISO8601DateFormatWithInternetDateTime];
    std::fprintf(file, "%s %s\n", stamp.UTF8String, text);
    std::fflush(file);
}

const char* ModeName(int mode) {
    return mode == systemaudio::Stereo ? "stereo" : mode == systemaudio::Hrtf ? "HRTF"
         : mode == systemaudio::HrtfHQ ? "HRTF HQ" : "off";
}

bool PerApp(int mode) { return mode == systemaudio::Hrtf || mode == systemaudio::HrtfHQ; }



void WriteStatus(NSString* capture, bool macMuted, NSString* reason) {
    NSMutableDictionary* json = [@{@"capture": capture, @"macMuted": @(macMuted), @"pid": @(getpid()),

                                   @"fromTerminal": @(getppid() != 1)} mutableCopy];
    if (reason) json[@"reason"] = reason;
    NSURL* url = [SettingsURL().URLByDeletingLastPathComponent URLByAppendingPathComponent:@"audio-status.json"];
    [[NSJSONSerialization dataWithJSONObject:json options:NSJSONWritingSortedKeys error:nil] writeToURL:url atomically:YES];
}





int AudioCapturePermission() {
    static auto preflight = [] {
        void* tcc = dlopen("/System/Library/PrivateFrameworks/TCC.framework/Versions/A/TCC", RTLD_LAZY);
        return tcc ? reinterpret_cast<int (*)(CFStringRef, CFDictionaryRef)>(dlsym(tcc, "TCCAccessPreflight")) : nullptr;
    }();
    return preflight ? preflight(CFSTR("kTCCServiceAudioCapture"), nullptr) : -1;
}

AVAudio3DPoint AudioPoint(const Vec3& v) { return AVAudioMake3DPoint(v.x, v.y, v.z); }




float MacVolume() {
    AudioObjectPropertyAddress address = {kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal,
                                          kAudioObjectPropertyElementMain};
    AudioObjectID device = kAudioObjectUnknown;
    UInt32 size = sizeof(device);
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, nullptr, &size, &device) != noErr ||
        device == kAudioObjectUnknown) return 1.0f;
    address = {kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMain};
    UInt32 muted = 0;
    size = sizeof(muted);
    if (AudioObjectGetPropertyData(device, &address, 0, nullptr, &size, &muted) == noErr && muted) return 0.0f;
    address = {kAudioHardwareServiceDeviceProperty_VirtualMainVolume, kAudioDevicePropertyScopeOutput,
               kAudioObjectPropertyElementMain};
    Float32 volume = 1.0f;
    size = sizeof(volume);
    if (AudioObjectGetPropertyData(device, &address, 0, nullptr, &size, &volume) != noErr) return 1.0f;
    return std::sqrt(std::clamp(volume, 0.0f, 1.0f));
}

template <typename T>
T AudioProperty(AudioObjectID object, AudioObjectPropertySelector selector, T fallback) {
    AudioObjectPropertyAddress address = {selector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    T value = fallback;
    UInt32 size = sizeof(value);
    return AudioObjectGetPropertyData(object, &address, 0, nullptr, &size, &value) == noErr ? value : fallback;
}

struct Playing {
    AudioObjectID process;
    pid_t pid;
};


std::vector<Playing> PlayingProcesses() {
    AudioObjectPropertyAddress address = {kAudioHardwarePropertyProcessObjectList, kAudioObjectPropertyScopeGlobal,
                                          kAudioObjectPropertyElementMain};
    UInt32 size = 0;
    if (AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &address, 0, nullptr, &size) != noErr) return {};
    std::vector<AudioObjectID> objects(size / sizeof(AudioObjectID));
    if (AudioObjectGetPropertyData(kAudioObjectSystemObject, &address, 0, nullptr, &size, objects.data()) != noErr) return {};
    objects.resize(size / sizeof(AudioObjectID));
    std::vector<Playing> playing;
    for (AudioObjectID object : objects) {
        if (!AudioProperty<UInt32>(object, kAudioProcessPropertyIsRunningOutput, 0)) continue;
        const pid_t pid = AudioProperty<pid_t>(object, kAudioProcessPropertyPID, -1);
        if (pid > 0) playing.push_back({object, pid});
    }
    return playing;
}


pid_t ResponsibleFor(pid_t pid) {
    static auto responsible =
        reinterpret_cast<pid_t (*)(pid_t)>(dlsym(RTLD_DEFAULT, "responsibility_get_pid_responsible_for_pid"));
    const pid_t owner = responsible ? responsible(pid) : -1;
    return owner > 0 ? owner : pid;
}

std::string ProcessName(pid_t pid) {
    char name[256] = "";
    proc_name(pid, name, sizeof(name));
    return name[0] ? name : std::to_string(pid);
}



std::unordered_map<pid_t, CGRect> FrontWindows() {
    std::unordered_map<pid_t, CGRect> windows;
    CFArrayRef list = CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly | kCGWindowListExcludeDesktopElements,
                                                 kCGNullWindowID);
    for (NSDictionary* info in (__bridge NSArray*)list) {
        if ([info[(__bridge id)kCGWindowLayer] intValue] != 0) continue;
        CGRect bounds;
        id bounds_json = info[(__bridge id)kCGWindowBounds];
        if (!bounds_json || !CGRectMakeWithDictionaryRepresentation((__bridge CFDictionaryRef)bounds_json, &bounds) ||
            bounds.size.width < 100 || bounds.size.height < 100) continue;
        windows.emplace([info[(__bridge id)kCGWindowOwnerPID] intValue], bounds);
    }
    if (list) CFRelease(list);
    return windows;
}



struct Placement {
    uint32_t display = 0;
    CGRect window{}, bounds{};
    bool own = false;
};


void PlaceSlot(const Placement& placement, const std::vector<systemaudio::Screen>& screens, const Vec3& otherLeft,
               const Vec3& otherRight, Vec3& left, Vec3& right) {
    for (const systemaudio::Screen& screen : screens) {
        if (placement.own ? screen.display != 0 : (!placement.display || screen.display != placement.display)) continue;
        const Vec3 across = Rotate(screen.pose.orientation, {1, 0, 0}), up = Rotate(screen.pose.orientation, {0, 1, 0});
        Vec3 center = {screen.pose.position.x, screen.pose.position.y, screen.pose.position.z};
        float half = std::clamp(screen.width * 0.5f, 0.2f, 3.0f);
        const CGRect& window = placement.window;
        const CGRect& bounds = placement.bounds;
        if (!placement.own && bounds.size.width > 0 && bounds.size.height > 0) {
            const float x = float((CGRectGetMidX(window) - bounds.origin.x) / bounds.size.width) - 0.5f;
            const float y = 0.5f - float((CGRectGetMidY(window) - bounds.origin.y) / bounds.size.height);
            center = center + across * (std::clamp(x, -0.5f, 0.5f) * screen.width) +
                     up * (std::clamp(y, -0.5f, 0.5f) * screen.height);
            half = std::clamp(float(window.size.width / bounds.size.width) * screen.width * 0.5f, 0.15f, half);
        }
        left = center - across * half;
        right = center + across * half;
        return;
    }
    left = otherLeft;
    right = otherRight;
}


struct AppTap {
    AudioObjectID process = kAudioObjectUnknown;
    pid_t pid = 0;
    int slot = 0;
    AudioObjectID tap = kAudioObjectUnknown;
    id description = nil;
    std::chrono::steady_clock::time_point heard;
    Placement placement;
};


struct Block {
    uint64_t generation = 0;
    size_t frames = 0;
    std::array<std::vector<float>, kSlots * 2> channel;
};
}

systemaudio::Settings systemaudio::Load() {
    NSDictionary* json = ReadSettingsJSON();
    Settings settings;
    id mode = json[@"mode"];
    if ([mode isKindOfClass:[NSNumber class]] && [mode intValue] >= Off && [mode intValue] <= HrtfHQ)
        settings.mode = [mode intValue];
    id speakers = json[@"macSpeakers"];
    if ([speakers isKindOfClass:[NSNumber class]]) settings.macSpeakers = [speakers boolValue];
    return settings;
}

void systemaudio::Save(const Settings& settings) {
    NSURL* url = SettingsURL();
    [[NSFileManager defaultManager] createDirectoryAtURL:url.URLByDeletingLastPathComponent
                             withIntermediateDirectories:YES attributes:nil error:nil];
    NSMutableDictionary* json = [ReadSettingsJSON() mutableCopy];
    json[@"mode"] = @(settings.mode);
    json[@"macSpeakers"] = @(settings.macSpeakers);
    NSData* data = [NSJSONSerialization dataWithJSONObject:json options:NSJSONWritingSortedKeys error:nil];
    [data writeToURL:url atomically:YES];
}



struct HrtfQueue {
    std::vector<float> channel[kSlots * 2];
    size_t read = 0;
    size_t Available() const { return channel[0].size() - read; }
    void Compact() {
        if (read < kMaxQueued) return;
        for (auto& c : channel) c.erase(c.begin(), c.begin() + read);
        read = 0;
    }
};

@interface NewtSystemAudio : NSObject <SCStreamOutput, SCStreamDelegate>
- (instancetype)initWithSubmit:(SystemAudio::Submit)submit;
- (void)applyMode:(int)mode macSpeakers:(bool)macSpeakers;
- (void)setHead:(XrPosef)head screens:(std::vector<systemaudio::Screen>)screens left:(Vec3)left right:(Vec3)right;
- (void)shutdown;
@end

@implementation NewtSystemAudio {
    SystemAudio::Submit _submit;
    dispatch_queue_t _queue;
    dispatch_queue_t _ioQueue;
    std::atomic<unsigned> _pendingTapBlocks;
    int _mode;
    bool _macSpeakers;
    bool _wanted;
    bool _formatWarned;
    std::vector<float> _interleaved;
    std::chrono::steady_clock::time_point _lastPaired;
    float _gain;
    dispatch_source_t _poll;

    AudioObjectID _otherTap, _aggregate;
    id _otherDescription;
    AudioDeviceIOProcID _ioProc;
    std::vector<AppTap> _apps;
    Placement _placement[kSlots];

    std::atomic<int> _streamCount;
    std::atomic<int> _streamSlot[kSlots];
    bool _tapMuted, _tapFailed;
    NSString* _fallbackReason;
    uint64_t _tapGeneration, _tapCallbacks;
    int _tapRetries;
    AudioObjectPropertyListenerBlock _outputChanged;

    SCStream* _stream;
    bool _starting;

    AVAudioEngine* _engine;
    AVAudioEnvironmentNode* _environment;
    AVAudioSourceNode* _sources[kSlots * 2];
    AVAudioPCMBuffer* _rendered;
    HrtfQueue _hrtf;
    bool _engineFailed;

    std::mutex _sceneMutex;
    XrPosef _head;
    std::vector<systemaudio::Screen> _screens;
    Vec3 _left, _right;
}

- (instancetype)initWithSubmit:(SystemAudio::Submit)submit {
    if ((self = [super init])) {
        _submit = submit;
        _pendingTapBlocks = 0;
        _queue = dispatch_queue_create("newt.system-audio", DISPATCH_QUEUE_SERIAL);
        _ioQueue = dispatch_queue_create("newt.system-audio.io", DISPATCH_QUEUE_SERIAL);
        _otherTap = _aggregate = kAudioObjectUnknown;
        _gain = 1.0f;
        _head = IdentityPose();
        _left = {-0.6f, 0, -1.5f};
        _right = {0.6f, 0, -1.5f};
    }
    return self;
}

- (void)applyMode:(int)mode macSpeakers:(bool)macSpeakers {
    dispatch_async(_queue, ^{
        if (mode != self->_mode) {
            Log(NEWT_LOG_INFO, "Mac audio in the headset: %s", ModeName(mode));
            self->_hrtf = {};
        }
        const bool speakersChanged = macSpeakers != self->_macSpeakers;
        self->_mode = mode;
        self->_macSpeakers = macSpeakers;
        if (PerApp(mode)) [self applyAlgorithm];
        self->_wanted = mode != systemaudio::Off;
        if (!self->_wanted) {
            [self stopCapture];
            return;
        }

        if (speakersChanged && self->_aggregate != kAudioObjectUnknown) [self stopTap];
        [self startCapture];
    });
}

- (void)setHead:(XrPosef)head screens:(std::vector<systemaudio::Screen>)screens left:(Vec3)left right:(Vec3)right {
    std::lock_guard<std::mutex> lock(_sceneMutex);
    _head = head;
    _screens = std::move(screens);
    _left = left;
    _right = right;
}

- (void)shutdown {
    dispatch_sync(_queue, ^{
        self->_wanted = false;
        [self stopCapture];
        WriteStatus(@"off", false, nil);
        if (self->_outputChanged) {
            AudioObjectPropertyAddress address = {kAudioHardwarePropertyDefaultOutputDevice,
                                                  kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
            AudioObjectRemovePropertyListenerBlock(kAudioObjectSystemObject, &address, self->_queue, self->_outputChanged);
            self->_outputChanged = nil;
        }
        [self->_engine stop];
        self->_engine = nil;
    });
}





- (void)startCapture {
    if (!_poll) {
        _poll = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
        dispatch_source_set_timer(_poll, DISPATCH_TIME_NOW, kPollNs, kPollNs / 10);
        __weak NewtSystemAudio* weakSelf = self;
        dispatch_source_set_event_handler(_poll, ^{ [weakSelf poll]; });
        dispatch_resume(_poll);
    }
    if (@available(macOS 14.2, *)) {
        if (!_tapFailed) return;
    }
    if (!_stream && !_starting) [self startStream];
}

- (void)stopCapture {
    if (_poll) {
        dispatch_source_cancel(_poll);
        _poll = nil;
    }
    const bool wasCapturing = _aggregate != kAudioObjectUnknown || _stream;
    [self stopTap];
    if (_stream) {
        [_stream stopCaptureWithCompletionHandler:nil];
        _stream = nil;
    }
    if (wasCapturing && !_wanted) WriteStatus(@"off", false, nil);
}

- (void)poll {
    if (!_wanted) return;
    const auto now = std::chrono::steady_clock::now();
    if (_submit(nullptr, 0)) _lastPaired = now;
    const bool headset = now - _lastPaired < kHeadsetGone;
    _gain = MacVolume();
    if (@available(macOS 14.2, *)) {
        if (_tapFailed || !_wanted) return;
        if (headset && _aggregate == kAudioObjectUnknown) {
            if (![self startTap]) [self startCapture];
        } else if (!headset && _aggregate != kAudioObjectUnknown) {
            Log(NEWT_LOG_INFO, "Mac audio: headset gone; the Mac plays its own sound");
            [self stopTap];
            WriteStatus(@"waiting", false, nil);
        }
        if (_aggregate != kAudioObjectUnknown) [self pollApps];
    }
}




- (bool)startTap API_AVAILABLE(macos(14.2)) {
    const int permission = AudioCapturePermission();
    if (permission == 1 || (permission == 2 && getppid() != 1)) {
        _tapFailed = true;
        _fallbackReason = @"no-permission";
        Log(NEWT_LOG_WARNING, "Mac audio: no System Audio Recording permission%s; using ScreenCaptureKit, the Mac keeps "
            "playing. Add %s under Privacy & Security › Screen & System Audio Recording › System Audio Recording Only.",
            getppid() != 1 ? " for the terminal PippinVR was started from" : "",
            getppid() != 1 ? "the terminal app" : "PippinVR");
        return false;
    }
    _tapMuted = !_macSpeakers;
    _apps.clear();
    [self updatePlacements];
    CATapDescription* other = [[CATapDescription alloc] initStereoGlobalTapButExcludeProcesses:@[]];
    other.name = @"PippinVR headset sound";
    other.privateTap = YES;
    other.muteBehavior = _tapMuted ? CATapMutedWhenTapped : CATapUnmuted;
    AudioObjectID otherTap = kAudioObjectUnknown;
    OSStatus status = AudioHardwareCreateProcessTap(other, &otherTap);
    AudioObjectID device = kAudioObjectUnknown;
    if (status == noErr) {
        NSDictionary* aggregate = @{
            @kAudioAggregateDeviceNameKey: @"PippinVR headset sound",
            @kAudioAggregateDeviceUIDKey: [NSUUID UUID].UUIDString,
            @kAudioAggregateDeviceIsPrivateKey: @YES,
            @kAudioAggregateDeviceIsStackedKey: @NO,



            @kAudioAggregateDeviceTapAutoStartKey: @NO,
            @kAudioAggregateDeviceTapListKey: @[@{@kAudioSubTapUIDKey: other.UUID.UUIDString,
                                                  @kAudioSubTapDriftCompensationKey: @YES}],
        };
        status = AudioHardwareCreateAggregateDevice((__bridge CFDictionaryRef)aggregate, &device);
    }
    if (status == noErr) {
        AudioObjectPropertyAddress rate = {kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal,
                                           kAudioObjectPropertyElementMain};
        const Float64 value = kRate;
        status = AudioObjectSetPropertyData(device, &rate, 0, nullptr, sizeof(value), &value);
    }
    _streamCount = 1;
    _streamSlot[0] = 0;
    const uint64_t generation = ++_tapGeneration;
    AudioDeviceIOProcID proc = nullptr;
    if (status == noErr) {
        __weak NewtSystemAudio* weakSelf = self;
        status = AudioDeviceCreateIOProcIDWithBlock(&proc, device, _ioQueue,
            ^(const AudioTimeStamp*, const AudioBufferList* input, const AudioTimeStamp*, AudioBufferList*, const AudioTimeStamp*) {
                [weakSelf tapInput:input generation:generation];
            });
    }
    if (status == noErr) status = AudioDeviceStart(device, proc);
    if (status != noErr) {
        if (proc) AudioDeviceDestroyIOProcID(device, proc);
        if (device != kAudioObjectUnknown) AudioHardwareDestroyAggregateDevice(device);
        if (otherTap != kAudioObjectUnknown) AudioHardwareDestroyProcessTap(otherTap);
        _tapFailed = true;
        _fallbackReason = @"tap-unavailable";
        Log(NEWT_LOG_WARNING, "Mac audio: system audio tap failed (%d); using ScreenCaptureKit, the Mac keeps playing",
            int(status));
        return false;
    }
    _aggregate = device;
    _ioProc = proc;
    _otherTap = otherTap;
    _otherDescription = other;
    _tapCallbacks = 0;
    if (!_outputChanged) {

        __weak NewtSystemAudio* weakSelf = self;
        _outputChanged = ^(UInt32, const AudioObjectPropertyAddress*) {
            NewtSystemAudio* strongSelf = weakSelf;
            if (!strongSelf || strongSelf->_aggregate == kAudioObjectUnknown) return;
            [strongSelf stopTap];
            if (![strongSelf startTap]) [strongSelf startCapture];
        };
        AudioObjectPropertyAddress address = {kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal,
                                              kAudioObjectPropertyElementMain};
        AudioObjectAddPropertyListenerBlock(kAudioObjectSystemObject, &address, _queue, _outputChanged);
    }
    Log(NEWT_LOG_INFO, "Mac audio: headset there; capturing with system audio taps (48 kHz), Mac output %s",
        _tapMuted ? "muted" : "playing");
    WriteStatus(@"tap", _tapMuted, nil);




    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC), _queue, ^{
        if (generation != self->_tapGeneration || self->_aggregate == kAudioObjectUnknown) return;
        if (self->_tapCallbacks) {
            self->_tapRetries = 0;
            return;
        }
        [self stopTap];
        const bool granted = AudioCapturePermission() == 0;
        if (granted && self->_tapRetries < kTapRetries) {
            Log(NEWT_LOG_INFO, "Mac audio: the system audio tap hasn't started yet; recreating it (%d of %d)",
                ++self->_tapRetries, kTapRetries);
            return;
        }
        if (granted)
            Log(NEWT_LOG_WARNING, "Mac audio: the system audio tap delivered nothing although System Audio Recording "
                "is allowed; using ScreenCaptureKit, the Mac keeps playing. Reconnect to try the tap again.");
        else
            Log(NEWT_LOG_WARNING, "Mac audio: the system audio tap delivered nothing (no System Audio Recording "
                "permission%s); using ScreenCaptureKit, the Mac keeps playing. Allow it under Privacy & Security › "
                "Screen & System Audio Recording › System Audio Recording Only, then reconnect.",
                getppid() != 1 ? " for the terminal PippinVR was started from" : "");
        self->_tapRetries = 0;
        self->_tapFailed = true;
        self->_fallbackReason = granted ? @"tap-silent" : @"no-permission";
        if (self->_wanted) [self startCapture];
    });
    return true;
}

- (void)stopTap {
    if (_aggregate == kAudioObjectUnknown) return;
    if (@available(macOS 14.2, *)) {
        AudioDeviceStop(_aggregate, _ioProc);
        AudioDeviceDestroyIOProcID(_aggregate, _ioProc);
        AudioHardwareDestroyAggregateDevice(_aggregate);
        AudioHardwareDestroyProcessTap(_otherTap);
        for (const AppTap& app : _apps) AudioHardwareDestroyProcessTap(app.tap);
    }
    _apps.clear();
    _otherTap = _aggregate = kAudioObjectUnknown;
    _ioProc = nullptr;
    _otherDescription = nil;
    _streamCount = 0;
    [self updatePlacements];
}




- (bool)updateAppTaps:(const std::vector<AudioObjectID>&)retired API_AVAILABLE(macos(14.2)) {
    const CATapMuteBehavior mute = _tapMuted ? CATapMutedWhenTapped : CATapUnmuted;
    for (auto app = _apps.begin(); app != _apps.end();) {
        if (app->tap == kAudioObjectUnknown) {
            CATapDescription* description = [[CATapDescription alloc] initStereoMixdownOfProcesses:@[@(app->process)]];
            description.name = @"PippinVR headset sound (app)";
            description.privateTap = YES;
            description.muteBehavior = mute;
            AudioObjectID tap = kAudioObjectUnknown;
            if (AudioHardwareCreateProcessTap(description, &tap) != noErr) {
                app = _apps.erase(app);
                continue;
            }
            app->tap = tap;
            app->description = description;
        }
        ++app;
    }
    CATapDescription* other = _otherDescription;
    NSMutableArray* tapList = [NSMutableArray arrayWithObject:other.UUID.UUIDString];
    NSMutableArray* tapped = [NSMutableArray array];
    for (const AppTap& app : _apps) {
        [tapList addObject:((CATapDescription*)app.description).UUID.UUIDString];
        [tapped addObject:@(app.process)];
    }

    _streamCount = int(1 + _apps.size());
    for (size_t i = 0; i < _apps.size(); ++i) _streamSlot[i + 1] = _apps[i].slot;
    AudioObjectPropertyAddress listAddress = {kAudioAggregateDevicePropertyTapList, kAudioObjectPropertyScopeGlobal,
                                              kAudioObjectPropertyElementMain};
    CFArrayRef list = (__bridge CFArrayRef)tapList;
    OSStatus status = AudioObjectSetPropertyData(_aggregate, &listAddress, 0, nullptr, sizeof(list), &list);
    if (status == noErr) {
        other.processes = tapped;
        AudioObjectPropertyAddress descriptionAddress = {kAudioTapPropertyDescription, kAudioObjectPropertyScopeGlobal,
                                                         kAudioObjectPropertyElementMain};
        CFTypeRef value = (__bridge CFTypeRef)other;
        status = AudioObjectSetPropertyData(_otherTap, &descriptionAddress, 0, nullptr, sizeof(value), &value);
    }
    for (AudioObjectID tap : retired)
        if (tap != kAudioObjectUnknown) AudioHardwareDestroyProcessTap(tap);
    [self updatePlacements];
    if (status != noErr) Log(NEWT_LOG_WARNING, "Mac audio: couldn't change the app taps (%d); starting over", int(status));
    return status == noErr;
}



- (void)pollApps API_AVAILABLE(macos(14.2)) {
    const auto now = std::chrono::steady_clock::now();
    const bool perApp = PerApp(_mode);
    std::vector<systemaudio::Screen> screens;
    {
        std::lock_guard<std::mutex> lock(_sceneMutex);
        screens = _screens;
    }
    bool changed = false;
    std::vector<AudioObjectID> retired;
    if (perApp) {
        const auto windows = FrontWindows();
        for (const Playing& playing : PlayingProcesses()) {
            Placement placement;
            if (playing.pid == getpid()) {
                placement.own = true;
            } else {
                auto window = windows.find(ResponsibleFor(playing.pid));
                if (window == windows.end()) window = windows.find(playing.pid);
                if (window != windows.end()) {
                    placement.window = window->second;
                    const CGPoint center = {CGRectGetMidX(window->second), CGRectGetMidY(window->second)};
                    CGDirectDisplayID display = 0;
                    uint32_t count = 0;
                    if (CGGetDisplaysWithPoint(center, 1, &display, &count) == kCGErrorSuccess && count) {
                        placement.display = display;
                        placement.bounds = CGDisplayBounds(display);
                    }
                }
            }
            auto app = std::find_if(_apps.begin(), _apps.end(), [&](const AppTap& a) { return a.process == playing.process; });
            if (app != _apps.end()) {
                app->heard = now;
                if (placement.own || placement.display) app->placement = placement;
                continue;
            }
            const bool shown = std::any_of(screens.begin(), screens.end(), [&](const systemaudio::Screen& screen) {
                return placement.own ? screen.display == 0 : placement.display && screen.display == placement.display;
            });
            if (!shown) continue;
            int slot = 1;
            while (slot < kSlots && std::any_of(_apps.begin(), _apps.end(), [&](const AppTap& a) { return a.slot == slot; }))
                ++slot;
            if (slot == kSlots) continue;
            AppTap added;
            added.process = playing.process;
            added.pid = playing.pid;
            added.slot = slot;
            added.heard = now;
            added.placement = placement;
            _apps.push_back(added);
            changed = true;
            Log(NEWT_LOG_INFO, "Mac audio: %s plays from its window (slot %d)",
                ProcessName(placement.own ? playing.pid : ResponsibleFor(playing.pid)).c_str(), slot);
        }
    }
    for (auto app = _apps.begin(); app != _apps.end();) {
        if (perApp && now - app->heard < kAppQuiet) {
            ++app;
            continue;
        }
        Log(NEWT_LOG_INFO, "Mac audio: %s gave back slot %d", ProcessName(ResponsibleFor(app->pid)).c_str(), app->slot);
        retired.push_back(app->tap);
        app = _apps.erase(app);
        changed = true;
    }
    if (!changed) {
        [self updatePlacements];
    } else if (![self updateAppTaps:retired]) {
        [self stopTap];
    }
}

- (void)updatePlacements {
    for (Placement& placement : _placement) placement = {};
    for (const AppTap& app : _apps) _placement[app.slot] = app.placement;
}


- (void)tapInput:(const AudioBufferList*)input generation:(uint64_t)generation {
    if (!input || int(input->mNumberBuffers) != _streamCount.load()) return;


    if (_pendingTapBlocks.load(std::memory_order_relaxed) >= 8) return;
    auto block = std::make_shared<Block>();
    block->generation = generation;
    for (UInt32 b = 0; b < input->mNumberBuffers && b < UInt32(kSlots); ++b) {
        const AudioBuffer& buffer = input->mBuffers[b];
        const UInt32 channels = std::max<UInt32>(1, buffer.mNumberChannels);
        const float* data = static_cast<const float*>(buffer.mData);
        const size_t frames = buffer.mDataByteSize / (sizeof(float) * channels);
        if (!data || !frames || frames > kMaxQueued || (block->frames && frames != block->frames)) continue;
        block->frames = frames;
        const int slot = _streamSlot[b].load();
        if (slot < 0 || slot >= kSlots) continue;
        std::vector<float>& left = block->channel[slot * 2];
        std::vector<float>& right = block->channel[slot * 2 + 1];
        left.resize(frames);
        right.resize(frames);
        for (size_t i = 0; i < frames; ++i) {
            left[i] = data[i * channels];
            right[i] = data[i * channels + (channels >= 2 ? 1 : 0)];
        }
    }
    if (!block->frames) return;
    _pendingTapBlocks.fetch_add(1, std::memory_order_relaxed);
    dispatch_async(_queue, ^{
        struct PendingDelivery {
            std::atomic<unsigned>& count;
            ~PendingDelivery() { count.fetch_sub(1, std::memory_order_relaxed); }
        } delivery{self->_pendingTapBlocks};
        if (block->generation != self->_tapGeneration || self->_aggregate == kAudioObjectUnknown) return;
        self->_tapCallbacks++;
        [self deliver:*block];
    });
}


- (void)startStream {
    _starting = true;
    [SCShareableContent getShareableContentExcludingDesktopWindows:NO onScreenWindowsOnly:YES
                                                 completionHandler:^(SCShareableContent* content, NSError* error) {
        dispatch_async(self->_queue, ^{
            self->_starting = false;
            if (!self->_wanted || self->_stream || self->_aggregate != kAudioObjectUnknown) return;
            if (!content.displays.count) {
                Log(NEWT_LOG_WARNING, "Mac audio: no display to capture from (%s)",
                    error ? error.localizedDescription.UTF8String : "none listed");
                return;
            }


            SCContentFilter* filter = [[SCContentFilter alloc] initWithDisplay:content.displays.firstObject
                                                              excludingWindows:@[]];
            SCStreamConfiguration* config = [[SCStreamConfiguration alloc] init];
            config.capturesAudio = YES;
            config.sampleRate = NSInteger(kRate);
            config.channelCount = 2;
            config.excludesCurrentProcessAudio = NO;
            config.width = 2;
            config.height = 2;
            config.minimumFrameInterval = CMTimeMake(1, 1);
            config.queueDepth = 3;
            SCStream* stream = [[SCStream alloc] initWithFilter:filter configuration:config delegate:self];
            NSError* addError = nil;
            if (![stream addStreamOutput:self type:SCStreamOutputTypeAudio sampleHandlerQueue:self->_queue error:&addError] ||
                ![stream addStreamOutput:self type:SCStreamOutputTypeScreen sampleHandlerQueue:self->_queue error:&addError]) {
                Log(NEWT_LOG_WARNING, "Mac audio: capture unavailable (%s)", addError.localizedDescription.UTF8String);
                return;
            }
            self->_stream = stream;
            [stream startCaptureWithCompletionHandler:^(NSError* startError) {
                if (startError) {
                    Log(NEWT_LOG_WARNING, "Mac audio: capture failed to start (%s)",
                        startError.localizedDescription.UTF8String);
                    dispatch_async(self->_queue, ^{ if (self->_stream == stream) self->_stream = nil; });
                } else {
                    Log(NEWT_LOG_INFO, "Mac audio: capturing with ScreenCaptureKit (48 kHz stereo)");
                    dispatch_async(self->_queue, ^{
                        if (self->_stream == stream) WriteStatus(@"screencapturekit", false, self->_fallbackReason);
                    });
                }
            }];
        });
    }];
}

- (void)stream:(SCStream*)stream didStopWithError:(NSError*)error {
    dispatch_async(_queue, ^{
        if (self->_stream != stream) return;
        Log(NEWT_LOG_WARNING, "Mac audio: capture stopped (%s); retrying", error.localizedDescription.UTF8String);
        self->_stream = nil;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), self->_queue, ^{
            if (self->_wanted) [self startCapture];
        });
    });
}

- (void)stream:(SCStream*)stream didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(SCStreamOutputType)type {
    if (type != SCStreamOutputTypeAudio || stream != _stream || !CMSampleBufferIsValid(sampleBuffer)) return;
    const AudioStreamBasicDescription* format =
        CMAudioFormatDescriptionGetStreamBasicDescription(CMSampleBufferGetFormatDescription(sampleBuffer));
    if (!format || format->mFormatID != kAudioFormatLinearPCM || !(format->mFormatFlags & kAudioFormatFlagIsFloat) ||
        format->mBitsPerChannel != 32 || format->mSampleRate != kRate || format->mChannelsPerFrame < 1) {
        if (!_formatWarned) {
            _formatWarned = true;
            Log(NEWT_LOG_WARNING, "Mac audio: unexpected capture format (%.0f Hz, %u channels); not sent",
                format ? format->mSampleRate : 0.0, format ? unsigned(format->mChannelsPerFrame) : 0u);
        }
        return;
    }
    size_t listSize = 0;
    CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, &listSize, nullptr, 0, nullptr, nullptr, 0, nullptr);
    if (!listSize) return;
    std::vector<uint8_t> storage(listSize);
    auto* list = reinterpret_cast<AudioBufferList*>(storage.data());
    CMBlockBufferRef blockBuffer = nullptr;
    if (CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(sampleBuffer, nullptr, list, listSize, nullptr, nullptr,
            kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment, &blockBuffer) != noErr) return;
    const size_t frames = size_t(CMSampleBufferGetNumSamples(sampleBuffer));
    const bool planar = format->mFormatFlags & kAudioFormatFlagIsNonInterleaved;
    const UInt32 channels = format->mChannelsPerFrame;

    const float* left = nullptr;
    const float* right = nullptr;
    size_t leftBytes = 0, rightBytes = 0;
    size_t stride = 1;
    if (planar) {
        if (list->mNumberBuffers >= channels) {
            left = static_cast<const float*>(list->mBuffers[0].mData);
            const auto& rightBuffer = list->mBuffers[channels >= 2 ? 1 : 0];
            right = static_cast<const float*>(rightBuffer.mData);
            leftBytes = list->mBuffers[0].mDataByteSize;
            rightBytes = rightBuffer.mDataByteSize;
        }
    } else if (list->mNumberBuffers >= 1 && list->mBuffers[0].mData &&
               list->mBuffers[0].mDataByteSize / sizeof(float) >= channels) {
        left = static_cast<const float*>(list->mBuffers[0].mData);
        right = channels >= 2 ? left + 1 : left;
        leftBytes = list->mBuffers[0].mDataByteSize;
        rightBytes = leftBytes - (channels >= 2 ? sizeof(float) : 0);
        stride = channels;
    }
    if (frames <= kMaxQueued) {
        Block block;
        block.frames = frames;
        if (systemaudio::CopyStereo(left, leftBytes, right, rightBytes, frames, stride,
                                    block.channel[0], block.channel[1])) [self deliver:block];
    }
    if (blockBuffer) CFRelease(blockBuffer);
}



- (void)deliver:(const Block&)block {
    if (!_wanted || _mode == systemaudio::Off) return;
    if (_mode == systemaudio::Stereo || ![self ensureEngine]) [self sendStereo:block];
    else [self sendHrtf:block];
}



- (void)submit:(float*)interleaved frames:(size_t)frames {
    if (_gain != 1.0f)
        for (size_t i = 0; i < frames * 2; ++i) interleaved[i] *= _gain;
    if (_submit(interleaved, uint32_t(frames))) _lastPaired = std::chrono::steady_clock::now();
}


- (void)sendStereo:(const Block&)block {
    _interleaved.assign(block.frames * 2, 0.0f);
    for (int c = 0; c < kSlots * 2; ++c) {
        const std::vector<float>& channel = block.channel[c];
        for (size_t i = 0; i < channel.size(); ++i) _interleaved[i * 2 + (c & 1)] += channel[i];
    }
    [self submit:_interleaved.data() frames:block.frames];
}



- (bool)ensureEngine {
    if (_engine) return true;
    if (_engineFailed) return false;
    AVAudioFormat* stereo = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:kRate channels:2];
    AVAudioFormat* mono = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:kRate channels:1];
    AVAudioEngine* engine = [[AVAudioEngine alloc] init];
    NSError* error = nil;
    if (![engine enableManualRenderingMode:AVAudioEngineManualRenderingModeOffline format:stereo
                         maximumFrameCount:kBlock error:&error]) {
        _engineFailed = true;
        Log(NEWT_LOG_WARNING, "Mac audio: HRTF unavailable (%s); sending stereo", error.localizedDescription.UTF8String);
        return false;
    }
    AVAudioEnvironmentNode* environment = [[AVAudioEnvironmentNode alloc] init];
    [engine attachNode:environment];

    environment.distanceAttenuationParameters.rolloffFactor = 0;
    environment.reverbParameters.enable = NO;
    if (@available(macOS 13.0, *)) environment.outputType = AVAudioEnvironmentOutputTypeHeadphones;
    HrtfQueue* queue = &_hrtf;
    for (int c = 0; c < kSlots * 2; ++c) {
        AVAudioSourceNode* source = [[AVAudioSourceNode alloc] initWithFormat:mono
            renderBlock:^OSStatus(BOOL* silence, const AudioTimeStamp*, AVAudioFrameCount count, AudioBufferList* out) {
                float* dst = static_cast<float*>(out->mBuffers[0].mData);
                const std::vector<float>& src = queue->channel[c];
                const size_t have = std::min<size_t>(count, src.size() - std::min(src.size(), queue->read));
                if (have) std::memcpy(dst, src.data() + queue->read, have * sizeof(float));
                std::fill(dst + have, dst + count, 0.0f);
                *silence = have == 0;
                return noErr;
            }];
        [engine attachNode:source];
        [engine connect:source to:environment format:mono];
        _sources[c] = source;
    }
    [engine connect:environment to:engine.mainMixerNode format:stereo];
    if (![engine startAndReturnError:&error]) {
        _engineFailed = true;
        Log(NEWT_LOG_WARNING, "Mac audio: HRTF engine failed to start (%s); sending stereo",
            error.localizedDescription.UTF8String);
        return false;
    }
    _engine = engine;
    _environment = environment;
    _rendered = [[AVAudioPCMBuffer alloc] initWithPCMFormat:engine.manualRenderingFormat frameCapacity:kBlock];
    [self applyAlgorithm];
    return true;
}

- (void)applyAlgorithm {
    if (!_engine) return;
    const AVAudio3DMixingRenderingAlgorithm algorithm =
        _mode == systemaudio::HrtfHQ ? AVAudio3DMixingRenderingAlgorithmHRTFHQ : AVAudio3DMixingRenderingAlgorithmHRTF;
    for (AVAudioSourceNode* source : _sources) {
        source.renderingAlgorithm = algorithm;
        if (@available(macOS 13.0, *)) source.sourceMode = AVAudio3DMixingSourceModePointSource;
    }
}

- (void)sendHrtf:(const Block&)block {
    for (int c = 0; c < kSlots * 2; ++c) {
        const std::vector<float>& src = block.channel[c];
        std::vector<float>& dst = _hrtf.channel[c];
        if (src.empty()) dst.insert(dst.end(), block.frames, 0.0f);
        else dst.insert(dst.end(), src.begin(), src.end());
    }

    if (_hrtf.Available() > kMaxQueued) _hrtf.read = _hrtf.channel[0].size() - kMaxQueued;
    XrPosef head;
    std::vector<systemaudio::Screen> screens;
    Vec3 otherLeft, otherRight;
    {
        std::lock_guard<std::mutex> lock(_sceneMutex);
        head = _head;
        screens = _screens;
        otherLeft = _left;
        otherRight = _right;
    }
    const Vec3 forward = Rotate(head.orientation, {0, 0, -1}), up = Rotate(head.orientation, {0, 1, 0});
    _environment.listenerPosition = AVAudioMake3DPoint(head.position.x, head.position.y, head.position.z);
    _environment.listenerVectorOrientation = AVAudioMake3DVectorOrientation(
        AVAudioMake3DVector(forward.x, forward.y, forward.z), AVAudioMake3DVector(up.x, up.y, up.z));
    for (int slot = 0; slot < kSlots; ++slot) {
        Vec3 left, right;
        PlaceSlot(_placement[slot], screens, otherLeft, otherRight, left, right);
        _sources[slot * 2].position = AudioPoint(left);
        _sources[slot * 2 + 1].position = AudioPoint(right);
    }
    while (_hrtf.Available() >= kBlock) {
        NSError* error = nil;
        const AVAudioEngineManualRenderingStatus status = [_engine renderOffline:kBlock toBuffer:_rendered error:&error];
        _hrtf.read += kBlock;
        if (status != AVAudioEngineManualRenderingStatusSuccess || _rendered.frameLength == 0) continue;
        const float* const* out = _rendered.floatChannelData;
        const size_t n = _rendered.frameLength;
        _interleaved.resize(n * 2);
        for (size_t i = 0; i < n; ++i) {
            _interleaved[i * 2] = out[0][i];
            _interleaved[i * 2 + 1] = out[1][i];
        }
        [self submit:_interleaved.data() frames:n];
    }
    _hrtf.Compact();
}

@end

struct SystemAudio::Impl {
    NewtSystemAudio* object;
};

SystemAudio::SystemAudio(Submit submit) : mImpl(new Impl{[[NewtSystemAudio alloc] initWithSubmit:submit]}) {}
SystemAudio::~SystemAudio() { [mImpl->object shutdown]; }
void SystemAudio::Apply(const systemaudio::Settings& settings) {
    [mImpl->object applyMode:settings.mode macSpeakers:settings.macSpeakers];
}
void SystemAudio::SetScene(const XrPosef& head, std::vector<systemaudio::Screen> screens, const Vec3& left,
                           const Vec3& right) {
    [mImpl->object setHead:head screens:std::move(screens) left:left right:right];
}





void NewtXR::PollSystemAudio() {
    if (!mSystemAudio) {
        const auto now = std::chrono::steady_clock::now();
        if (now - mSystemAudioLookup < std::chrono::seconds(2)) return;
        mSystemAudioLookup = now;
        for (uint32_t i = 0; i < _dyld_image_count() && !mSystemAudio; ++i) {
            const char* name = _dyld_get_image_name(i);
            if (!name || !std::strstr(name, "libopenxr_monado")) continue;
            void* handle = dlopen(name, RTLD_LAZY | RTLD_LOCAL | RTLD_NOLOAD);
            if (!handle) continue;
            if (auto submit = reinterpret_cast<SystemAudio::Submit>(dlsym(handle, "ql_audio_submit"))) {
                mSystemAudioRuntime = handle;
                mSystemAudio = std::make_unique<SystemAudio>(submit);
                mSystemAudio->Apply(mAudio);
            } else {
                dlclose(handle);
            }
        }
        if (!mSystemAudio) return;
    }


    std::vector<systemaudio::Screen> screens;
    for (const auto& panel : mPanels) {
        if (panel->screen && panel->screen->DisplayID())
            screens.push_back({panel->screen->DisplayID(), panel->pose, panel->width, panel->height});
        else if (panel->camera && !panel->passthrough)
            screens.push_back({0, panel->pose, panel->width, panel->height});
    }


    const Panel* screen = nullptr;
    if (mActivePanel >= 0 && mActivePanel < int(mPanels.size()) && mPanels[mActivePanel]->screen)
        screen = mPanels[mActivePanel].get();
    for (size_t i = 0; i < mPanels.size() && !screen; ++i)
        if (mPanels[i]->screen) screen = mPanels[i].get();
    Vec3 center, right;
    float half;
    if (screen) {
        center = {screen->pose.position.x, screen->pose.position.y, screen->pose.position.z};
        right = Rotate(screen->pose.orientation, {1, 0, 0});
        half = std::clamp(screen->width * 0.5f, 0.2f, 3.0f);
    } else {
        const Vec3 ahead = Rotate(mDashboardPose.orientation, {0, 0, -1.5f});
        center = {mDashboardPose.position.x + ahead.x, mDashboardPose.position.y + ahead.y,
                  mDashboardPose.position.z + ahead.z};
        right = Rotate(mDashboardPose.orientation, {1, 0, 0});
        half = 0.6f;
    }
    mSystemAudio->SetScene(mViewerPose, std::move(screens), center - right * half, center + right * half);
}


void NewtXR::SetAudioMode(int mode) {
    mAudio.mode = mode;
    systemaudio::Save(mAudio);
    if (mSystemAudio) mSystemAudio->Apply(mAudio);
    mContentDirty = true;
}


void NewtXR::ReloadAudioSettings() {
    mAudio = systemaudio::Load();
    if (mSystemAudio) mSystemAudio->Apply(mAudio);
    mContentDirty = true;
}

void NewtXR::ReleaseSystemAudio() {
    mSystemAudio.reset();
    if (mSystemAudioRuntime) dlclose(mSystemAudioRuntime);
    mSystemAudioRuntime = nullptr;
}
