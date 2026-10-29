#include "PassthroughSettings.h"
#import <Foundation/Foundation.h>
#include <algorithm>
#include <cmath>
#include <cstdlib>

namespace {
NSURL* PreferencesURL() {
    NSString* root = nil;
    if (const char* value = std::getenv("NEWT_STATE_DIR")) root = [NSString stringWithUTF8String:value];
    if (!root.length) root = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Newt"];
    return [[NSURL fileURLWithPath:root isDirectory:YES] URLByAppendingPathComponent:@"passthrough.json"];
}

NSDictionary* ReadJSON() {
    NSData* data = [NSData dataWithContentsOfURL:PreferencesURL()];
    id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [json isKindOfClass:[NSDictionary class]] ? json : @{};
}
}

PassthroughSettings LoadPassthroughSettings() {
    PassthroughSettings settings;
    NSDictionary* json = ReadJSON();
    auto number = [&](NSString* key, double fallback) {
        id value = json[key];
        return [value isKindOfClass:[NSNumber class]] ? [value doubleValue] : fallback;
    };
    settings.allowed = number(@"allowed", 0) != 0;
    settings.enabled = number(@"enabled", 0) != 0;
    settings.stereo = number(@"stereo", 1) != 0;
    settings.width = static_cast<float>(number(@"width", settings.width));
    settings.height = static_cast<float>(number(@"height", settings.height));

    settings.lensMode = static_cast<int>(number(@"lensMode", number(@"lensCorrection", 1) != 0 ? 1 : 0));
    settings.fov = static_cast<int>(number(@"fov", 1));
    settings.anchor = static_cast<int>(number(@"anchor", 0));
    settings.frame = number(@"frame", 1) != 0;
    settings.direction = static_cast<int>(number(@"direction", 0));
    settings.locked = number(@"locked", 0) != 0;
    settings.hands = static_cast<int>(number(@"hands", 0));
    auto quad = [&](NSString* key, float* out) {
        id value = json[key];
        if (![value isKindOfClass:[NSArray class]] || [value count] != 8) return;
        float parsed[8];
        for (int i = 0; i < 8; ++i) {
            id item = value[i];
            if (![item isKindOfClass:[NSNumber class]] || !std::isfinite([item floatValue])) return;
            parsed[i] = [item floatValue];
        }
        std::copy(parsed, parsed + 8, out);
    };
    quad(@"shape", settings.shape);
    id pose = json[@"pose"];
    if ([pose isKindOfClass:[NSArray class]] && [pose count] == 7) {
        bool valid = true;
        float values[7];
        for (int i = 0; i < 7; ++i) {
            id value = pose[i];
            valid = valid && [value isKindOfClass:[NSNumber class]] && std::isfinite([value floatValue]);
            values[i] = valid ? [value floatValue] : 0;
        }
        if (valid) {
            settings.hasPose = true;
            std::copy(values, values + 3, settings.position);
            std::copy(values + 3, values + 7, settings.orientation);
        }
    }
    settings.Normalize();
    return settings;
}


bool SavePassthroughSettings(const PassthroughSettings& settings) {
    NSURL* url = PreferencesURL();
    if (![[NSFileManager defaultManager] createDirectoryAtURL:url.URLByDeletingLastPathComponent
                                 withIntermediateDirectories:YES attributes:nil error:nil]) return false;
    NSMutableDictionary* json = [ReadJSON() mutableCopy];
    json[@"enabled"] = @(settings.enabled);
    json[@"stereo"] = @(settings.stereo);
    json[@"width"] = @(settings.width);
    json[@"height"] = @(settings.height);
    json[@"lensMode"] = @(settings.lensMode);
    [json removeObjectForKey:@"lensCorrection"];
    json[@"fov"] = @(settings.fov);
    json[@"anchor"] = @(settings.anchor);
    json[@"frame"] = @(settings.frame);
    json[@"direction"] = @(settings.direction);
    json[@"locked"] = @(settings.locked);
    json[@"hands"] = @(settings.hands);
    auto array = [](const float* q) {
        NSMutableArray* out = [NSMutableArray arrayWithCapacity:8];
        for (int i = 0; i < 8; ++i) [out addObject:@(q[i])];
        return out;
    };
    json[@"shape"] = array(settings.shape);
    [json removeObjectForKey:@"region"];
    if (settings.hasPose) {
        json[@"pose"] = @[@(settings.position[0]), @(settings.position[1]), @(settings.position[2]),
                          @(settings.orientation[0]), @(settings.orientation[1]), @(settings.orientation[2]),
                          @(settings.orientation[3])];
    }
    NSData* data = [NSJSONSerialization dataWithJSONObject:json options:NSJSONWritingPrettyPrinted error:nil];
    return data && [data writeToURL:url options:NSDataWritingAtomic error:nil];
}
