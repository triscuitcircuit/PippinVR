#include "AddonAudioBridge.h"
#include "AddonSpatialAudio.h"
#import <Foundation/Foundation.h>
#include <algorithm>
#include <cmath>
#include <chrono>
#include <memory>
#include <cstring>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <vector>

namespace {
dispatch_queue_t queue;
dispatch_source_t timer;
void* runtime;
bool (*submit)(const float*, uint32_t);
NSString* directory;
std::unique_ptr<AddonSpatialAudio> spatial;
NSString* lastOwner;
uint64_t lastSequence;
NSString* lastMode;
std::chrono::steady_clock::time_point lastChunk;

bool RenderSpatial(NSData* file, NSString* owner, uint64_t sequence, std::vector<float>& samples) {
    NSDictionary* object = [NSJSONSerialization JSONObjectWithData:file options:0 error:nil];
    if (![object isKindOfClass:[NSDictionary class]]) return false;
    NSString* mode = object[@"mode"];
    NSString* encoded = object[@"data"];
    if (![mode isKindOfClass:[NSString class]] || ![encoded isKindOfClass:[NSString class]]) return false;
    NSData* data = [[NSData alloc] initWithBase64EncodedString:encoded options:0];
    if (!data.length || data.length > 15360 || data.length % 1920) return false;
    AddonSpatialConfig config;
    if ([mode isEqualToString:@"cues"]) config.mode = AddonSpatialConfig::Cues;
    else if ([mode isEqualToString:@"hrtf"]) config.mode = AddonSpatialConfig::Hrtf;
    else if ([mode isEqualToString:@"hrtfHQ"]) config.mode = AddonSpatialConfig::HrtfHQ;
    else return false;
    for (NSString* key in @[@"x", @"y", @"z", @"itdUs", @"ildDb", @"gain"]) if (![object[key] isKindOfClass:[NSNumber class]]) return false;
    config.x = [object[@"x"] floatValue]; config.y = [object[@"y"] floatValue]; config.z = [object[@"z"] floatValue];
    config.itdUs = [object[@"itdUs"] floatValue]; config.ildDb = [object[@"ildDb"] floatValue]; config.gain = [object[@"gain"] floatValue];
    if (object[@"referenceDistance"]) {
        if (![object[@"referenceDistance"] isKindOfClass:[NSNumber class]]) return false;
        config.referenceDistance = [object[@"referenceDistance"] floatValue];
    }
    if (object[@"rolloff"]) {
        if (![object[@"rolloff"] isKindOfClass:[NSNumber class]]) return false;
        config.rolloff = [object[@"rolloff"] floatValue];
    }
    if (!std::isfinite(config.x) || !std::isfinite(config.y) || !std::isfinite(config.z) ||
        std::abs(config.x) > 100 || std::abs(config.y) > 100 || std::abs(config.z) > 100 ||
        !std::isfinite(config.itdUs) || std::abs(config.itdUs) > 2000 || !std::isfinite(config.ildDb) ||
        std::abs(config.ildDb) > 24 || !std::isfinite(config.gain) || config.gain < 0 || config.gain > 1 ||
        !std::isfinite(config.referenceDistance) || config.referenceDistance < 0.01f || config.referenceDistance > 100 ||
        !std::isfinite(config.rolloff) || config.rolloff < 0 || config.rolloff > 10) return false;
    std::vector<float> mono(data.length / sizeof(float));
    std::memcpy(mono.data(), data.bytes, data.length);
    if (!std::all_of(mono.begin(), mono.end(), [](float v) { return std::isfinite(v) && std::abs(v) <= 1.0f; })) return false;
    auto now = std::chrono::steady_clock::now();
    if (!spatial) spatial = std::make_unique<AddonSpatialAudio>();
    if (![lastOwner isEqualToString:owner] || sequence != lastSequence + 1 || ![lastMode isEqualToString:mode] || now - lastChunk > std::chrono::milliseconds(300)) spatial->reset();
    lastOwner = owner; lastSequence = sequence; lastMode = mode; lastChunk = now;
    return spatial->render(mono.data(), mono.size(), config, samples);
}

void Poll() {
    @autoreleasepool {
        NSArray<NSString*>* names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:directory error:nil];
        if (!names.count) return;
        if (!submit) {
            for (uint32_t i = 0; i < _dyld_image_count(); ++i) {
                const char* name = _dyld_get_image_name(i);
                if (!name || !std::strstr(name, "libopenxr_monado")) continue;
                void* handle = dlopen(name, RTLD_LAZY | RTLD_LOCAL | RTLD_NOLOAD);
                if (!handle) continue;
                auto fn = reinterpret_cast<bool (*)(const float*, uint32_t)>(dlsym(handle, "ql_audio_addon_submit"));
                if (fn) { runtime = handle; submit = fn; break; }
                dlclose(handle);
            }
        }
        NSArray<NSString*>* sorted = [names sortedArrayUsingSelector:@selector(compare:)];
        int processed = 0;
        for (NSString* name in sorted) {
            if (processed >= 4 || (![name.pathExtension isEqualToString:@"pcm"] && ![name.pathExtension isEqualToString:@"spatial"])) continue;
            NSArray<NSString*>* parts = [name.stringByDeletingPathExtension componentsSeparatedByString:@"--"];
            if (parts.count != 2 || ![[NSUUID alloc] initWithUUIDString:parts[0]] || parts[1].length != 20 ||
                [parts[1] rangeOfCharacterFromSet:[NSCharacterSet.decimalDigitCharacterSet invertedSet]].location != NSNotFound) continue;
            NSString* path = [directory stringByAppendingPathComponent:name];
            NSDictionary* attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
            if (!attributes) continue;
            double age = -[attributes.fileModificationDate timeIntervalSinceNow];
            if (age > 0.5) { [[NSFileManager defaultManager] removeItemAtPath:path error:nil]; continue; }
            if (!submit) continue;
            const NSUInteger size = attributes.fileSize;
            const bool isSpatial = [name.pathExtension isEqualToString:@"spatial"];
            if (size == 0 || size > 30720 || (!isSpatial && size % (480 * 2 * sizeof(float)) != 0)) {
                [[NSFileManager defaultManager] removeItemAtPath:path error:nil]; continue;
            }
            NSData* data = [NSData dataWithContentsOfFile:path];
            if (data.length == size) {
                std::vector<float> samples;
                bool valid = false;
                if (isSpatial) valid = RenderSpatial(data, parts[0], parts[1].longLongValue, samples);
                else {
                    lastOwner = nil;
                    samples.resize(size / sizeof(float));
                    std::memcpy(samples.data(), data.bytes, size);
                    valid = std::all_of(samples.begin(), samples.end(), [](float v) { return std::isfinite(v) && std::abs(v) <= 1.0f; });
                }
                if (valid) submit(samples.data(), uint32_t(samples.size() / 2));
            }
            [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
            ++processed;
        }
    }
}
}

void StartAddonAudioBridge() {
    if (timer) return;
    NSString* root = nil;
    if (const char* value = std::getenv("NEWT_STATE_DIR")) root = [NSString stringWithUTF8String:value];
    if (!root.length) root = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Newt"];
    directory = [root stringByAppendingPathComponent:@"ui/addon-audio"];
    queue = dispatch_queue_create("com.pippinvr.addon-audio", DISPATCH_QUEUE_SERIAL);
    timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, queue);
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, NSEC_PER_MSEC * 20, NSEC_PER_MSEC * 3);
    dispatch_source_set_event_handler(timer, ^{ Poll(); });
    dispatch_resume(timer);
}

void StopAddonAudioBridge() {
    if (!timer) return;
    dispatch_source_cancel(timer);
    dispatch_sync(queue, ^{
        submit = nullptr;
        spatial.reset(); lastOwner = nil; lastMode = nil; lastSequence = 0;
        if (runtime) dlclose(runtime);
        runtime = nullptr;
    });
    timer = nil;
    queue = nil;
    directory = nil;
}
