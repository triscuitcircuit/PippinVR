#include "NewtXRApp.h"
#include "NewtInternal.h"
#include "EnvironmentModel.h"
#import <Foundation/Foundation.h>
#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <sys/stat.h>
using namespace NewtInternal;
namespace {
NSString* Root() {
    if (const char* value = std::getenv("NEWT_STATE_DIR")) if (*value) return [NSString stringWithUTF8String:value];
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Newt"];
}
NSString* RequestDirectory() { return [Root() stringByAppendingPathComponent:@"ui/api-models"]; }
NSString* StatusDirectory() { return [Root() stringByAppendingPathComponent:@"ui/api-model-status"]; }
NSString* String(const std::string& value) { return [NSString stringWithUTF8String:value.c_str()]; }
NSString* RequestPath(const std::string& id) { return [RequestDirectory() stringByAppendingPathComponent:[String(id) stringByAppendingString:@".json"]]; }
NSString* StatusPath(const std::string& id) { return [StatusDirectory() stringByAppendingPathComponent:[String(id) stringByAppendingString:@".json"]]; }
}
void NewtXR::ReportAddonModel(const std::string& id, const std::string& revision, const char* state, const char* error) {
    if (![[NSFileManager defaultManager] fileExistsAtPath:RequestPath(id)]) {
        [[NSFileManager defaultManager] removeItemAtPath:StatusPath(id) error:nil];
        return;
    }
    NSMutableDictionary* result = [@{@"revision": String(revision), @"state": [NSString stringWithUTF8String:state]} mutableCopy];
    if (error) result[@"error"] = [NSString stringWithUTF8String:error];
    NSData* data = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    if (data && [data writeToFile:StatusPath(id) options:NSDataWritingAtomic error:nil]) chmod(StatusPath(id).fileSystemRepresentation, 0600);
}
void NewtXR::PollAddonModels() {
    const auto now = std::chrono::steady_clock::now();
    if (now - mAddonModelsLastScan < std::chrono::milliseconds(500)) return;
    mAddonModelsLastScan = now;
    NSFileManager* files = [NSFileManager defaultManager];
    NSArray<NSString*>* names = [files contentsOfDirectoryAtPath:RequestDirectory() error:nil] ?: @[];
    std::vector<std::string> present;
    for (NSString* name in names) {
        if (![name.pathExtension isEqualToString:@"json"]) continue;
        NSString* stem = name.stringByDeletingPathExtension;
        NSArray<NSString*>* parts = [stem componentsSeparatedByString:@"--"];
        if (parts.count != 3 || ![parts[0] isEqualToString:@"pippin-api"] || ![[NSUUID alloc] initWithUUIDString:parts[1]] || !parts[2].length ||
            [parts[2] rangeOfCharacterFromSet:[[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnopqrstuvwxyz0123456789-"] invertedSet]].location != NSNotFound) continue;
        std::string id = stem.UTF8String;
        present.push_back(id);
        NSString* path = [RequestDirectory() stringByAppendingPathComponent:name];
        NSDictionary* attributes = [files attributesOfItemAtPath:path error:nil];
        if (!attributes || attributes.fileSize > 8192) continue;
        NSData* data = [NSData dataWithContentsOfFile:path];
        NSObject* raw = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSDictionary* json = [raw isKindOfClass:[NSDictionary class]] ? (NSDictionary*)raw : nil;
        if (![json isKindOfClass:[NSDictionary class]] || ![json[@"path"] isKindOfClass:[NSString class]] ||
            ![json[@"revision"] isKindOfClass:[NSString class]] || ![[NSUUID alloc] initWithUUIDString:json[@"revision"]]) continue;
        const std::string revision = [json[@"revision"] UTF8String];
        auto found = mAddonModelRequests.find(id);
        if (found != mAddonModelRequests.end() && found->second == revision) continue;
        for (int i = int(mModels.size()) - 1; i >= 0; --i) if (mModels[size_t(i)]->addonID == id) {
            CheckVk(vkDeviceWaitIdle(mCore->Device()), "replace API model"); RemoveModel(i);
        }
        mAddonModelRequests[id] = revision;
        NSDictionary* rotation = json[@"rotation"];
        NSString* mode = [rotation isKindOfClass:[NSDictionary class]] ? rotation[@"mode"] : nil;
        NSNumber* speed = [rotation isKindOfClass:[NSDictionary class]] ? rotation[@"degreesPerSecond"] : nil;
        if (![mode isKindOfClass:[NSString class]] || ![speed isKindOfClass:[NSNumber class]] || !std::isfinite(speed.doubleValue) || std::abs(speed.doubleValue) > 180 ||
            !([mode isEqual:@"fixed"] || [mode isEqual:@"spin"] || [mode isEqual:@"faceUser"])) {
            ReportAddonModel(id, revision, "error", "Invalid rotation settings."); continue;
        }
        NSString* parent = json[@"parentPanel"];
        NSNumber* requestedSize = json[@"size"];
        if (parent) {
            if (![parent isKindOfClass:[NSString class]] || ![requestedSize isKindOfClass:[NSNumber class]] ||
                !std::isfinite(requestedSize.doubleValue) || requestedSize.doubleValue < 0.05 || requestedSize.doubleValue > 1) {
                ReportAddonModel(id, revision, "error", "Invalid model attachment."); continue;
            }
            NSArray<NSString*>* parentParts = [parent componentsSeparatedByString:@"--"];
            if (parentParts.count != 3 || ![parentParts[0] isEqualToString:@"pippin-api"] || ![parentParts[1] isEqualToString:parts[1]]) {
                ReportAddonModel(id, revision, "error", "Model and panel ownership do not match."); continue;
            }
        }
        NSString* modelPath = json[@"path"];
        if (!modelPath.isAbsolutePath || !IsModelFilePath(modelPath.UTF8String)) { ReportAddonModel(id, revision, "error", "Invalid model path."); continue; }
        ModelInstance* model = AddModelFromFile(modelPath.UTF8String);
        if (!model) { ReportAddonModel(id, revision, "error", "Could not load the model or the model limit was reached."); continue; }
        model->addonID = id; model->addonRevision = revision;
        if (parent) {
            model->addonParentPanel = parent.UTF8String;
            const float extent = 2 * std::max({model->halfExtents.x, model->halfExtents.y, model->halfExtents.z});
            model->scale = requestedSize.floatValue / std::max(0.001f, extent);
        }
        model->addonRotation = [mode isEqual:@"spin"] ? customui::RotationMode::Spin : [mode isEqual:@"faceUser"] ? customui::RotationMode::FaceUser : customui::RotationMode::Fixed;
        model->addonRotationSpeed = speed.floatValue; model->addonBaseOrientation = model->pose.orientation;
        model->addonRotationStart = std::chrono::steady_clock::now();
        ReportAddonModel(id, revision, "ready");
    }
    for (auto it = mAddonModelRequests.begin(); it != mAddonModelRequests.end();) {
        if (std::find(present.begin(), present.end(), it->first) != present.end()) { ++it; continue; }
        const std::string id = it->first;
        for (int i = int(mModels.size()) - 1; i >= 0; --i) if (mModels[size_t(i)]->addonID == id) {
            CheckVk(vkDeviceWaitIdle(mCore->Device()), "remove API model"); RemoveModel(i);
        }
        [files removeItemAtPath:StatusPath(id) error:nil];
        it = mAddonModelRequests.erase(it);
    }
}
void NewtXR::AnimateAddonModels() {
    const auto now = std::chrono::steady_clock::now();
    for (size_t i = 0; i < mModels.size(); ++i) {
        auto& model = *mModels[i];
        if (model.addonID.empty() || !model.addonParentPanel.empty()) continue;
        if (int(i) == mGrabbedModel || int(i) == mStretchModel) { model.addonWasGrabbed = true; continue; }
        if (model.addonWasGrabbed) {
            model.addonBaseOrientation = model.pose.orientation;
            model.addonRotationStart = now;
            model.addonWasGrabbed = false;
        }
        const float dx = mViewerPose.position.x - model.pose.position.x;
        const float dz = mViewerPose.position.z - model.pose.position.z;
        const double elapsed = std::chrono::duration<double>(now - model.addonRotationStart).count();
        float half = 0;
        if (!customui::RotationYaw(model.addonRotation, dx, dz, elapsed, model.addonRotationSpeed, half)) continue;
        XrQuaternionf yaw{0, std::sin(half), 0, std::cos(half)};
        model.pose.orientation = model.addonRotation == customui::RotationMode::FaceUser ? yaw : QuaternionProduct(model.addonBaseOrientation, yaw);
    }
}
