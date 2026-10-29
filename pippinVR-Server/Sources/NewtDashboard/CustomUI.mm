// SPDX-License-Identifier: MIT


#include "NewtXRApp.h"
#include "NewtInternal.h"
#include "include/NewtLog.h"
#include "InteractionGeometry.h"
#import <AppKit/AppKit.h>
#include <algorithm>
#include <cmath>
#include <cstring>
using namespace NewtInternal;

namespace {
constexpr auto kScanInterval = std::chrono::milliseconds(500);
constexpr unsigned long long kEventsLimit = 64 * 1024;

NSString* StateRoot() {
    NSString* root = nil;
    if (const char* value = std::getenv("NEWT_STATE_DIR")) root = [NSString stringWithUTF8String:value];
    if (!root.length) root = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Newt"];
    return root;
}
NSString* PanelsDirectory() { return [StateRoot() stringByAppendingPathComponent:@"ui/panels"]; }
NSString* EventsFile() { return [StateRoot() stringByAppendingPathComponent:@"ui/events.jsonl"]; }
NSString* Str(const std::string& s) { return [NSString stringWithUTF8String:s.c_str()] ?: @""; }


void AppendEvent(NSDictionary* event) {
    NSData* json = [NSJSONSerialization dataWithJSONObject:event options:0 error:nil];
    if (!json) return;
    NSString* path = EventsFile();
    [[NSFileManager defaultManager] createDirectoryAtPath:path.stringByDeletingLastPathComponent
                              withIntermediateDirectories:YES attributes:nil error:nil];
    NSMutableData* line = [json mutableCopy];
    [line appendBytes:"\n" length:1];
    NSDictionary* attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:nil];
    if (attributes && attributes.fileSize + line.length > kEventsLimit) {
        NSData* old = [NSData dataWithContentsOfFile:path];
        NSData* tail = old.length > kEventsLimit / 2 ? [old subdataWithRange:NSMakeRange(old.length - kEventsLimit / 2, kEventsLimit / 2)] : old;

        const NSRange newline = [tail rangeOfData:[NSData dataWithBytes:"\n" length:1] options:0 range:NSMakeRange(0, tail.length)];
        NSMutableData* kept = [NSMutableData dataWithData:newline.location == NSNotFound ? NSData.data
                                                          : [tail subdataWithRange:NSMakeRange(newline.location + 1, tail.length - newline.location - 1)]];
        [kept appendData:line];
        [kept writeToFile:path atomically:YES];
        return;
    }
    NSFileHandle* handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!handle) {
        [line writeToFile:path atomically:YES];
        return;
    }
    [handle seekToEndOfFile];
    [handle writeData:line];
    [handle closeFile];
}

PixelImage RenderPanel(const customui::PanelSpec& spec, const customui::Layout& layout, NSImage* image) {
    const int height = int(std::ceil(layout.height));
    NSColor* accent = RGB(spec.accent[0], spec.accent[1], spec.accent[2]);
    return MakeImage(^(NSRect bounds) {
        FillRounded(bounds, 28, RGB(0.06f, 0.075f, 0.09f, 0.96f));
        FillRounded(NSMakeRect(0, 0, 12, bounds.size.height), 6, accent);
        auto rect = [](const customui::Area& r) { return NSMakeRect(r.x, r.y, r.w, r.h); };
        if (!spec.title.empty()) DrawText(Str(spec.title), rect(layout.title), 40, YES, accent);
        for (size_t i = 0; i < layout.lines.size(); ++i)
            DrawText(Str(spec.lines[i]), rect(layout.lines[i]), 27, NO, RGB(0.88f, 0.9f, 0.92f));
        if (image && layout.image.w > 0)
            [image drawInRect:rect(layout.image) fromRect:NSZeroRect operation:NSCompositingOperationSourceOver
                     fraction:1 respectFlipped:YES hints:nil];
        for (size_t i = 0; i < layout.buttons.size(); ++i) {
            const auto& b = layout.buttons[i];
            FillRounded(rect(b), 18, RGB(0.15f, 0.19f, 0.23f));
            DrawText(Str(spec.buttons[i].label), NSMakeRect(b.x + 12, b.y + (b.h - 40) / 2, b.w - 24, 44), 30, YES,
                     RGB(0.95f, 0.96f, 0.97f), NSTextAlignmentCenter);
        }
        if (spec.closable) {
            const auto& c = layout.close;
            FillRounded(rect(c), c.w / 2, RGB(0.17f, 0.2f, 0.24f));
            DrawText(@"×", NSMakeRect(c.x, c.y + 4, c.w, c.h - 8), 52, YES, RGB(0.9f, 0.92f, 0.94f), NSTextAlignmentCenter);
        }
    }, uint32_t(customui::kCardWidth), uint32_t(height));
}
}

void NewtXR::ShowCustomPanel(const customui::PanelSpec& spec, CustomPanelHandler handler) {
    for (auto& panel : mCustomPanels) {
        if (panel.spec.id != spec.id || panel.removed) continue;
        const bool moved = panel.spec.anchor != spec.anchor || std::memcmp(panel.spec.position, spec.position, sizeof spec.position);
        panel.spec = spec;
        panel.dirty = true;
        panel.hidden = false;
        if (moved) panel.placed = false;
        if (handler) panel.handler = std::move(handler);
        return;
    }
    CustomPanel panel;
    panel.spec = spec;
    panel.handler = std::move(handler);
    mCustomPanels.push_back(std::move(panel));
}

void NewtXR::RemoveCustomPanel(const std::string& id) {
    for (auto& panel : mCustomPanels)
        if (panel.spec.id == id) panel.removed = true;
}

void NewtXR::EmitCustomPanelEvent(CustomPanel& panel, const std::string& event, const std::string& button) {
    if (panel.handler) panel.handler(panel.spec.id, event, button);
    if (!panel.fromScript) return;
    NSMutableDictionary* line = [@{@"time": @([[NSDate date] timeIntervalSince1970]), @"panel": Str(panel.spec.id),
                                   @"event": Str(event)} mutableCopy];
    if (!button.empty()) line[@"button"] = Str(button);
    AppendEvent(line);
}


void NewtXR::ScanCustomPanelFiles() {
    const auto now = std::chrono::steady_clock::now();
    if (now - mCustomScan < kScanInterval) return;
    mCustomScan = now;
    NSFileManager* files = [NSFileManager defaultManager];
    NSString* directory = PanelsDirectory();
    NSArray<NSString*>* names = [files contentsOfDirectoryAtPath:directory error:nil] ?: @[];
    std::vector<std::string> present;
    for (NSString* name in names) {
        if (![name.pathExtension.lowercaseString isEqualToString:@"json"]) continue;
        NSString* path = [directory stringByAppendingPathComponent:name];
        const std::string panelId = name.stringByDeletingPathExtension.UTF8String;
        present.push_back(panelId);
        const double modified = [[files attributesOfItemAtPath:path error:nil].fileModificationDate timeIntervalSince1970];
        auto it = std::find_if(mCustomPanels.begin(), mCustomPanels.end(),
                               [&](const CustomPanel& p) { return p.spec.id == panelId && !p.removed; });
        if (it != mCustomPanels.end() && (!it->fromScript || it->fileTime == modified)) continue;
        NSData* data = [NSData dataWithContentsOfFile:path];
        id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        customui::PanelSpec spec;
        std::string error = json ? "" : "not valid JSON";
        if (json && customui::ParsePanelSpec(json, panelId, spec, error)) {
            ShowCustomPanel(spec);
            auto shown = std::find_if(mCustomPanels.begin(), mCustomPanels.end(),
                                      [&](const CustomPanel& p) { return p.spec.id == panelId && !p.removed; });
            shown->fromScript = true;
            shown->fileTime = modified;
        } else {

            if (mCustomPanelErrors[panelId] != modified)
                Newt_Logf(NEWT_LOG_WARNING, "Custom panel %s: %s", panelId.c_str(), error.c_str());
            mCustomPanelErrors[panelId] = modified;
        }
    }
    for (auto& panel : mCustomPanels)
        if (panel.fromScript && std::find(present.begin(), present.end(), panel.spec.id) == present.end()) panel.removed = true;
}


void NewtXR::PruneCustomPanels() {
    ScanCustomPanelFiles();
    const bool any = std::any_of(mCustomPanels.begin(), mCustomPanels.end(),
                                 [](const CustomPanel& p) { return p.removed || (p.dirty && p.texture.initialized); });
    if (!any) return;
    CheckVk(vkDeviceWaitIdle(mCore->Device()), "custom panels");
    for (auto& panel : mCustomPanels)
        if (panel.removed || panel.dirty) mCore->DestroyTexture(panel.texture);
    mCustomPanels.erase(std::remove_if(mCustomPanels.begin(), mCustomPanels.end(), [](const CustomPanel& p) { return p.removed; }),
                        mCustomPanels.end());
}

void NewtXR::RenderCustomPanels() {
    for (auto& panel : mCustomPanels) {
        if (!panel.dirty) continue;
        NSImage* image = panel.spec.image.empty() ? nil : [[NSImage alloc] initWithContentsOfFile:Str(panel.spec.image)];
        if (!panel.spec.image.empty() && !image)
            Newt_Logf(NEWT_LOG_WARNING, "Custom panel %s: can't read image %s", panel.spec.id.c_str(), panel.spec.image.c_str());
        const float aspect = image && image.size.height > 0 ? float(image.size.width / image.size.height) : 0;
        panel.layout = customui::LayoutPanel(panel.spec, aspect);
        mCore->CreateTexture(panel.texture, uint32_t(customui::kCardWidth), uint32_t(std::ceil(panel.layout.height)));
        mCore->UpdateTexture(panel.texture, RenderPanel(panel.spec, panel.layout, image));
        panel.dirty = false;
    }
}



bool NewtXR::CustomPanelPose(CustomPanel& panel, XrPosef& pose, float& width, float& height) {
    if (panel.hidden || panel.removed || !panel.texture.initialized) return false;
    width = panel.spec.width;
    height = width * panel.layout.height / customui::kCardWidth;
    XrPosef local = IdentityPose();
    local.position = {panel.spec.position[0], panel.spec.position[1], panel.spec.position[2]};
    switch (panel.spec.anchor) {
    case customui::Anchor::Head:
        pose = ComposePose(mViewerPose, local);
        return true;
    case customui::Anchor::Dashboard:
        if (!mMenuOpen) return false;
        pose = ComposePose(mDashboardPose, local);
        return true;
    case customui::Anchor::World:
        if (!panel.placed) {
            const Vec3 f = Rotate(mViewerPose.orientation, Vec3{0, 0, -1});
            const float yaw = std::atan2(-f.x, -f.z);
            XrPosef level = mViewerPose;
            level.orientation = {0, std::sin(yaw / 2), 0, std::cos(yaw / 2)};
            panel.worldPose = ComposePose(level, local);
            panel.placed = true;
        }
        pose = panel.worldPose;
        return true;
    }
    return false;
}

void NewtXR::UpdateCustomPanels(Newt::InputState& input) {
    const std::array<bool, 2> raw = input.select;
    for (int hand = 0; hand < 2; ++hand) {
        if (!input.aimValid[hand] || !raw[hand] || mCustomPrevSelect[hand] || mPassthrough.tracing) continue;
        CustomPanel* best = nullptr;
        float bestDistance = 1e9f, bestX = 0, bestY = 0;
        for (auto& panel : mCustomPanels) {
            XrPosef pose;
            float w, h, distance, u, v;
            if (!CustomPanelPose(panel, pose, w, h) || !RayQuadUV(input.aim[hand], pose, w, h, distance, u, v)) continue;
            if (distance < bestDistance) { best = &panel; bestDistance = distance; bestX = u * customui::kCardWidth; bestY = (1 - v) * panel.layout.height; }
        }
        if (!best) continue;
        input.select[hand] = false;
        const int hit = customui::HitTest(best->layout, bestX, bestY);
        if (hit == customui::kCloseHit) {
            mCore->PulseHaptic(hand, 0.2f);
            best->hidden = true;
            EmitCustomPanelEvent(*best, "closed", "");
            if (!best->fromScript) best->removed = true;
        } else if (hit >= 0) {
            mCore->PulseHaptic(hand, 0.3f);
            EmitCustomPanelEvent(*best, "button", best->spec.buttons[size_t(hit)].id);
        }
    }
    mCustomPrevSelect = raw;
}


void NewtXR::DrawCustomPanels(const Newt::EyeFrame& eye, bool headPanels) {
    bool cleared = false;
    for (auto& panel : mCustomPanels) {
        if ((panel.spec.anchor == customui::Anchor::Head) != headPanels) continue;
        XrPosef pose;
        float w, h;
        if (!CustomPanelPose(panel, pose, w, h)) continue;
        if (headPanels && !cleared) {
            VkClearAttachment depth{};
            depth.aspectMask = VK_IMAGE_ASPECT_DEPTH_BIT;
            depth.clearValue.depthStencil.depth = 1.0f;
            VkClearRect rect{};
            rect.rect.extent = {eye.width, eye.height};
            rect.layerCount = 1;
            vkCmdClearAttachments(eye.command, 1, &depth, 1, &rect);
            cleared = true;
        }
        mCore->DrawTextured(eye.command, eye.viewProjection, PoseMatrix(pose, {w, h, 1}), panel.texture);
    }
}
