#include "AddonInputBridge.h"
#import <Foundation/Foundation.h>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdlib>
#include <sys/stat.h>

namespace {
dispatch_queue_t queue;
NSString* directory;
std::atomic<bool> active{false}, busy{false}, requested{false};
std::atomic<int64_t> lastSubmission{0};

NSString* ValidLease() {
    NSString* path = [directory stringByAppendingPathComponent:@"controllers.request"];
    NSDictionary* attrs = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    NSDate* modified = attrs[NSFileModificationDate];
    if (!modified || std::abs(modified.timeIntervalSinceNow) > 2) return nil;
    NSString* value = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
    return [[NSUUID alloc] initWithUUIDString:value] ? value : nil;
}
NSDictionary* Pose(const XrPosef& p) {
    return @{@"position": @[@(p.position.x), @(p.position.y), @(p.position.z)],
             @"orientation": @[@(p.orientation.x), @(p.orientation.y), @(p.orientation.z), @(p.orientation.w)]};
}
NSDictionary* Button(const XrActionStateBoolean& value) {
    return @{@"active": @(bool(value.isActive)), @"pressed": @(value.isActive && value.currentState)};
}
NSDictionary* Controller(const Newt::InputState& input, int hand) {
    const auto& trigger = input.trigger[hand];
    const auto& grab = input.grab[hand];
    const auto& stick = input.stick[hand];
    return @{@"aim": input.aimValid[hand] ? Pose(input.aim[hand]) : (id)[NSNull null],
             @"gripPose": input.gripValid[hand] ? Pose(input.grip[hand]) : (id)[NSNull null],
             @"select": @(input.select[hand]), @"menu": @(input.menu[hand]),
             @"trigger": @{@"active": @(bool(trigger.isActive)), @"value": @(trigger.isActive ? trigger.currentState : 0)},
             @"squeeze": @{@"active": @(bool(grab.isActive)), @"value": @(grab.isActive ? grab.currentState : 0)},
             @"stick": @{@"active": @(bool(stick.isActive)), @"x": @(stick.isActive ? stick.currentState.x : 0), @"y": @(stick.isActive ? stick.currentState.y : 0)},
             @"primary": Button(input.primary[hand]), @"secondary": Button(input.secondary[hand]),
             @"stickClick": Button(input.stickClick[hand]), @"menuClick": Button(input.menuClick[hand])};
}
void Publish(const Newt::InputState& input) {
    NSString* lease = ValidLease();
    requested.store(lease != nil);
    if (!lease || !active.load()) return;
    NSDictionary* snapshot = @{@"lease": lease, @"focused": @(input.focused),
        @"predictedDisplayTimeNs": [NSString stringWithFormat:@"%lld", (long long)input.displayTime],
        @"left": Controller(input, 0), @"right": Controller(input, 1)};
    NSData* data = [NSJSONSerialization dataWithJSONObject:snapshot options:0 error:nil];
    if (!data || !active.load() || ![lease isEqualToString:ValidLease()]) return;
    NSString* path = [directory stringByAppendingPathComponent:@"controllers.json"];
    if (![data writeToFile:path options:NSDataWritingAtomic error:nil]) return;
    chmod(path.fileSystemRepresentation, 0600);
    if (!active.load() || ![lease isEqualToString:ValidLease()]) [[NSFileManager defaultManager] removeItemAtPath:path error:nil];
}
}
void StartAddonInputBridge() {
    if (active.exchange(true)) return;
    NSString* root = nil;
    if (const char* value = std::getenv("NEWT_STATE_DIR")) root = [NSString stringWithUTF8String:value];
    if (!root.length) root = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Newt"];
    directory = [root stringByAppendingPathComponent:@"ui/api-input"];
    queue = dispatch_queue_create("org.newt.addon-input", DISPATCH_QUEUE_SERIAL);
    lastSubmission.store(0); requested.store(false);
}
void StopAddonInputBridge() {
    if (!active.exchange(false)) return;
    dispatch_sync(queue, ^{});
    queue = nil; directory = nil; requested.store(false);
}
void SubmitAddonInput(const Newt::InputState& input) {
    if (!active.load()) return;
    auto now = std::chrono::duration_cast<std::chrono::nanoseconds>(std::chrono::steady_clock::now().time_since_epoch()).count();
    if (now - lastSubmission.load() < (requested.load() ? 33000000 : 250000000) || busy.exchange(true)) return;
    lastSubmission.store(now);
    Newt::InputState snapshot = input;
    dispatch_async(queue, ^{ @autoreleasepool { Publish(snapshot); busy.store(false); } });
}
