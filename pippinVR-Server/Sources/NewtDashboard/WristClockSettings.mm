#include "WristClockSettings.h"
#import <Foundation/Foundation.h>
#include <cstdlib>

namespace {
NSURL* PreferencesURL() {
    NSString* root = nil;
    if (const char* value = std::getenv("NEWT_STATE_DIR")) root = [NSString stringWithUTF8String:value];
    if (!root.length) root = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Newt"];
    return [[NSURL fileURLWithPath:root isDirectory:YES] URLByAppendingPathComponent:@"wrist-clock.json"];
}
}

WristClockSettings LoadWristClockSettings() {
    WristClockSettings settings;
    NSData* data = [NSData dataWithContentsOfURL:PreferencesURL()];
    id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![json isKindOfClass:[NSDictionary class]]) return settings;
    auto number = [&](NSString* key, int fallback) {
        id value = json[key];
        return [value isKindOfClass:[NSNumber class]] ? [value intValue] : fallback;
    };
    settings.enabled = number(@"enabled", true) != 0;
    settings.hand = number(@"hand", 0);
    settings.size = number(@"size", 1);
    settings.format = number(@"format", 0);
    settings.showDate = number(@"showDate", true) != 0;
    settings.position = number(@"position", 0);
    settings.color = number(@"color", 0);
    settings.Normalize();
    return settings;
}

bool SaveWristClockSettings(const WristClockSettings& settings) {
    NSURL* url = PreferencesURL();
    if (![[NSFileManager defaultManager] createDirectoryAtURL:url.URLByDeletingLastPathComponent
                                 withIntermediateDirectories:YES attributes:nil error:nil]) return false;
    NSDictionary* json = @{@"enabled": @(settings.enabled), @"hand": @(settings.hand),
        @"size": @(settings.size), @"format": @(settings.format), @"showDate": @(settings.showDate),
        @"position": @(settings.position), @"color": @(settings.color)};
    NSData* data = [NSJSONSerialization dataWithJSONObject:json options:NSJSONWritingPrettyPrinted error:nil];
    return data && [data writeToURL:url options:NSDataWritingAtomic error:nil];
}
