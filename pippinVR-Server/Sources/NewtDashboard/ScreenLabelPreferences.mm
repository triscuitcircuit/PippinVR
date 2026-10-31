#include "ScreenLabelPreferences.h"
#import <Foundation/Foundation.h>
#include <cstdlib>

namespace {
NSURL* PreferencesURL() {
    NSString* root = nil;
    if (const char* value = std::getenv("NEWT_STATE_DIR")) root = [NSString stringWithUTF8String:value];
    if (!root.length) root = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Newt"];
    return [NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"screen-labels.json"]];
}
}
bool LoadScreenLabelPreference() {
    NSData* data = [NSData dataWithContentsOfURL:PreferencesURL()];
    id object = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    id visible = [object isKindOfClass:[NSDictionary class]] ? object[@"visible"] : nil;
    if ([visible isKindOfClass:[NSNumber class]]) return [visible boolValue];
    NSNumber* legacy = [[NSUserDefaults standardUserDefaults] objectForKey:@"directShowScreenLabels"];
    return legacy ? legacy.boolValue : true;
}
bool SaveScreenLabelPreference(bool visible) {
    NSURL* url = PreferencesURL();
    if (![[NSFileManager defaultManager] createDirectoryAtURL:url.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil]) return false;
    NSData* data = [NSJSONSerialization dataWithJSONObject:@{@"visible": @(visible)} options:0 error:nil];
    return data && [data writeToURL:url options:NSDataWritingAtomic error:nil];
}
