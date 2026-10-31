#include "../../Sources/NewtDashboard/WristClockSettings.h"
#include "../../Sources/NewtDashboard/ColorPicker.h"
#import <Foundation/Foundation.h>
#include <cassert>
#include <cstdio>

int main() {
    @autoreleasepool {
        NSString* directory = [NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        setenv("NEWT_STATE_DIR", directory.UTF8String, 1);
        auto settings = LoadWristClockSettings();
        assert(settings.enabled && settings.showDate && settings.size == 1);
        for (int i = 0; i < 8; ++i) {
            const float x = kClockControlX + (i % 2) * kClockColumnStride + kClockControlWidth / 2;
            const float y = kClockControlY + (i / 2) * kClockRowStride + kClockControlHeight / 2;
            assert(HeadsetSettingsControlAt(x, y, true) == 200 + i);
        }
        assert(HeadsetSettingsControlAt(600, 60, true) == 104);
        assert(HeadsetSettingsControlAt(800, 60, false) == 105);
        assert(HeadsetSettingsControlAt(510, 170, true) == -1);
        assert(HeadsetSettingsControlAt(100, 150, false) == 100);
        assert(!settings.Select(110));
        settings.Select(201);
        assert(settings.AllowsHand(0) && !settings.AllowsHand(1));
        settings.Select(201);
        assert(!settings.AllowsHand(0) && settings.AllowsHand(1));
        settings.Select(202); settings.Select(203); settings.Select(204); settings.Select(205); settings.Select(206);
        settings.enabled = false;
        assert(SaveWristClockSettings(settings));
        const auto loaded = LoadWristClockSettings();
        assert(!loaded.enabled && loaded.hand == 2 && loaded.size == 2 && loaded.format == 1);
        assert(!loaded.showDate && loaded.position == 1 && loaded.color == 1);
        NSString* path = [directory stringByAppendingPathComponent:@"wrist-clock.json"];
        [@"{\"hand\":99,\"size\":-10,\"color\":null,\"format\":\"bad\"}" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        const auto repaired = LoadWristClockSettings();
        assert(repaired.hand == 2 && repaired.size == 0 && repaired.color == 0 && repaired.format == 0);
        [@"broken" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
        assert(LoadWristClockSettings().enabled);
        settings.Select(207);
        assert(settings.enabled && settings.hand == 0 && settings.size == 1 && settings.format == 0 && settings.showDate);
        [[NSFileManager defaultManager] removeItemAtPath:directory error:nil];
        puts("PASS: headset settings hit targets, customization, persistence, invalid preferences and reset");
    }
}
