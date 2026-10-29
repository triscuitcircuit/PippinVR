#include "SceneStore.h"
#import <Foundation/Foundation.h>
#include <cmath>
#include <cstdlib>

namespace {
NSURL* SceneURL() {
    NSString* root = nil;
    if (const char* value = std::getenv("NEWT_STATE_DIR")) root = [NSString stringWithUTF8String:value];
    if (!root.length) root = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Newt"];
    return [[NSURL fileURLWithPath:root isDirectory:YES] URLByAppendingPathComponent:@"scene.json"];
}

bool Numbers(id value, float* out, NSUInteger count) {
    if (![value isKindOfClass:[NSArray class]] || [value count] != count) return false;
    for (NSUInteger i = 0; i < count; ++i) {
        id item = value[i];
        if (![item isKindOfClass:[NSNumber class]] || !std::isfinite([item floatValue])) return false;
        out[i] = [item floatValue];
    }
    return true;
}

float Number(NSDictionary* dict, NSString* key, float fallback) {
    id value = dict[key];
    return [value isKindOfClass:[NSNumber class]] && std::isfinite([value floatValue]) ? [value floatValue] : fallback;
}

bool Flag(NSDictionary* dict, NSString* key) {
    id value = dict[key];
    return [value isKindOfClass:[NSNumber class]] && [value boolValue];
}

NSString* String(NSDictionary* dict, NSString* key) {
    id value = dict[key];
    return [value isKindOfClass:[NSString class]] && [value length] ? value : nil;
}
}

bool LoadSavedScene(SavedScene& scene) {
    scene = SavedScene{};
    NSData* data = [NSData dataWithContentsOfURL:SceneURL()];
    id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![json isKindOfClass:[NSDictionary class]]) return false;
    if ([json[@"environment"] isKindOfClass:[NSDictionary class]]) {
        NSDictionary* environment = json[@"environment"];
        if (NSString* path = String(environment, @"path")) {
            scene.environment = path.UTF8String;
            scene.flipV = Flag(environment, @"flipV");
            scene.flipH = Flag(environment, @"flipH");
            scene.environmentMissing = Flag(environment, @"missing");
        }
    }
    if ([json[@"home"] isKindOfClass:[NSArray class]] && [json[@"home"] count] == 3) {
        float values[3];
        bool valid = true;
        for (int i = 0; i < 3; ++i) {
            id v = json[@"home"][NSUInteger(i)];
            valid = valid && [v isKindOfClass:[NSNumber class]] && std::isfinite([v doubleValue]);
            values[i] = valid ? [v floatValue] : 0;
        }
        if (valid) { scene.homeX = values[0]; scene.homeZ = values[1]; scene.homeYaw = values[2]; }
    }
    if ([json[@"models"] isKindOfClass:[NSArray class]]) {
        for (id item in json[@"models"]) {
            if (![item isKindOfClass:[NSDictionary class]]) continue;
            NSString* path = String(item, @"path");
            if (!path) continue;
            SavedSceneModel model;
            model.path = path.UTF8String;
            float position[3], orientation[4];
            if (Numbers(item[@"position"], position, 3)) model.pose.position = {position[0], position[1], position[2]};
            if (Numbers(item[@"orientation"], orientation, 4)) {
                const float n = std::sqrt(orientation[0] * orientation[0] + orientation[1] * orientation[1] +
                                          orientation[2] * orientation[2] + orientation[3] * orientation[3]);
                if (n > 1e-4f)
                    model.pose.orientation = {orientation[0] / n, orientation[1] / n, orientation[2] / n, orientation[3] / n};
            }
            model.scale = std::fmin(50.0f, std::fmax(0.02f, Number(item, @"scale", 1.0f)));
            model.yaw = Number(item, @"yaw", 0.0f);
            model.inFront = [item[@"inFront"] isKindOfClass:[NSNumber class]] ? [item[@"inFront"] boolValue] : true;
            model.missing = Flag(item, @"missing");
            scene.models.push_back(model);
        }
    }
    return true;
}

std::string SerializeScene(const SavedScene& scene) {
    NSMutableDictionary* json = [NSMutableDictionary dictionary];
    if (!scene.environment.empty()) {
        json[@"environment"] = @{@"path": [NSString stringWithUTF8String:scene.environment.c_str()],
                                 @"flipV": @(scene.flipV), @"flipH": @(scene.flipH),
                                 @"missing": @(scene.environmentMissing)};
    }
    NSMutableArray* models = [NSMutableArray array];
    for (const auto& model : scene.models) {
        const auto& p = model.pose.position;
        const auto& q = model.pose.orientation;
        [models addObject:@{@"path": [NSString stringWithUTF8String:model.path.c_str()],
                            @"position": @[@(p.x), @(p.y), @(p.z)],
                            @"orientation": @[@(q.x), @(q.y), @(q.z), @(q.w)],
                            @"scale": @(model.scale), @"yaw": @(model.yaw), @"inFront": @(model.inFront),
                            @"missing": @(model.missing)}];
    }
    json[@"models"] = models;
    if (scene.homeX != 0 || scene.homeZ != 0 || scene.homeYaw != 0)
        json[@"home"] = @[@(scene.homeX), @(scene.homeZ), @(scene.homeYaw)];
    NSData* data = [NSJSONSerialization dataWithJSONObject:json
                                                   options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                     error:nil];
    return data ? std::string(static_cast<const char*>(data.bytes), data.length) : std::string();
}

bool WriteSceneText(const std::string& text) {
    if (text.empty()) return false;
    NSURL* url = SceneURL();
    if (![[NSFileManager defaultManager] createDirectoryAtURL:url.URLByDeletingLastPathComponent
                                 withIntermediateDirectories:YES attributes:nil error:nil]) return false;
    NSData* data = [NSData dataWithBytes:text.data() length:text.size()];
    return [data writeToURL:url options:NSDataWritingAtomic error:nil];
}

bool SceneFileReadable(const std::string& path) {
    if (path.empty()) return false;
    return [[NSFileManager defaultManager] isReadableFileAtPath:[NSString stringWithUTF8String:path.c_str()]];
}

std::string SceneFileName(const std::string& path) {
    NSString* name = [[NSString stringWithUTF8String:path.c_str()] lastPathComponent];
    return name.length ? name.UTF8String : path;
}
