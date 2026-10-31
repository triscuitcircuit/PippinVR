// SPDX-License-Identifier: MIT

#include "CustomUI.h"
#include <cmath>

namespace customui {
namespace {
bool Floats(id value, float* out, int count) {
    if (![value isKindOfClass:[NSArray class]] || [value count] != NSUInteger(count)) return false;
    for (int i = 0; i < count; ++i) {
        id item = value[NSUInteger(i)];
        if (![item isKindOfClass:[NSNumber class]] || !std::isfinite([item doubleValue])) return false;
        out[i] = [item floatValue];
    }
    return true;
}
std::string Text(NSString* s, NSUInteger limit) {
    if (s.length > limit) s = [[s substringToIndex:limit] stringByAppendingString:@"…"];
    return s.UTF8String ? s.UTF8String : "";
}
}

bool ParsePanelSpec(NSDictionary* json, const std::string& panelId, PanelSpec& out, std::string& error) {
    PanelSpec spec;
    spec.id = panelId;
    if (![json isKindOfClass:[NSDictionary class]]) { error = "not a JSON object"; return false; }
    if (panelId.empty()) { error = "empty panel id"; return false; }
    id title = json[@"title"];
    if (title && ![title isKindOfClass:[NSString class]]) { error = "\"title\" must be text"; return false; }
    if (title) spec.title = Text(title, 80);
    id lines = json[@"lines"];
    if ([lines isKindOfClass:[NSString class]]) lines = @[lines];
    if (lines) {
        if (![lines isKindOfClass:[NSArray class]]) { error = "\"lines\" must be a list of text"; return false; }
        for (id line in lines) {
            if (![line isKindOfClass:[NSString class]]) { error = "\"lines\" must be a list of text"; return false; }
            if (int(spec.lines.size()) < kMaxLines) spec.lines.push_back(Text(line, 120));
        }
    }
    id buttons = json[@"buttons"];
    if (buttons) {
        if (![buttons isKindOfClass:[NSArray class]]) { error = "\"buttons\" must be a list"; return false; }
        for (id b in buttons) {
            Button button;
            if ([b isKindOfClass:[NSString class]]) {
                button.id = button.label = Text(b, 40);
            } else if ([b isKindOfClass:[NSDictionary class]] && [b[@"label"] isKindOfClass:[NSString class]]) {
                button.label = Text(b[@"label"], 40);
                id bid = b[@"id"];
                if (bid && ![bid isKindOfClass:[NSString class]]) { error = "button \"id\" must be text"; return false; }
                button.id = bid ? Text(bid, 64) : button.label;
            } else {
                error = "each button is text or {\"id\", \"label\"}";
                return false;
            }
            if (int(spec.buttons.size()) < kMaxButtons) spec.buttons.push_back(button);
        }
    }
    id image = json[@"image"];
    if (image && ![image isKindOfClass:[NSString class]]) { error = "\"image\" must be a file path"; return false; }
    if (image) spec.image = [[image stringByExpandingTildeInPath] UTF8String];
    id anchor = json[@"anchor"];
    if (anchor) {
        if ([anchor isEqual:@"world"]) spec.anchor = Anchor::World;
        else if ([anchor isEqual:@"head"]) spec.anchor = Anchor::Head;
        else if ([anchor isEqual:@"dashboard"]) spec.anchor = Anchor::Dashboard;
        else { error = "\"anchor\" is \"world\", \"head\" or \"dashboard\""; return false; }
    }
    id width = json[@"width"];
    if (width) {
        if (![width isKindOfClass:[NSNumber class]] || !std::isfinite([width doubleValue])) {
            error = "\"width\" must be a number (meters)";
            return false;
        }
        spec.width = std::clamp([width floatValue], 0.15f, 2.0f);
    }
    if (json[@"position"] && !Floats(json[@"position"], spec.position, 3)) {
        error = "\"position\" must be [x, y, z] in meters";
        return false;
    }
    for (float& p : spec.position) p = std::clamp(p, -5.0f, 5.0f);
    if (json[@"orientation"]) {
        if (!Floats(json[@"orientation"], spec.orientation, 4)) { error = "orientation must be a unit quaternion [x,y,z,w]"; return false; }
        float norm = 0;
        for (float v : spec.orientation) norm += v * v;
        if (!std::isfinite(norm) || std::abs(norm - 1.0f) > 0.001f) { error = "orientation must be a unit quaternion"; return false; }
    }
    id rotation = json[@"rotation"];
    if (rotation) {
        if (![rotation isKindOfClass:[NSDictionary class]] || ![rotation[@"mode"] isKindOfClass:[NSString class]]) { error = "rotation requires a mode"; return false; }
        NSString* mode = rotation[@"mode"];
        if ([mode isEqual:@"fixed"]) spec.rotation = RotationMode::Fixed;
        else if ([mode isEqual:@"spin"]) spec.rotation = RotationMode::Spin;
        else if ([mode isEqual:@"faceUser"]) spec.rotation = RotationMode::FaceUser;
        else { error = "rotation mode must be fixed, spin or faceUser"; return false; }
        id speed = rotation[@"degreesPerSecond"];
        if (speed) {
            if (![speed isKindOfClass:[NSNumber class]] || !std::isfinite([speed doubleValue]) || std::abs([speed doubleValue]) > 180) { error = "rotation speed must be between -180 and 180 degrees per second"; return false; }
            spec.degreesPerSecond = [speed floatValue];
        }
    }
    id decoration = json[@"decoration"];
    if (decoration) {
        if (![decoration isKindOfClass:[NSDictionary class]] || ![decoration[@"shape"] isKindOfClass:[NSString class]]) { error = "decoration needs a shape"; return false; }
        NSString* shape = decoration[@"shape"];
        if ([shape isEqual:@"cube"]) spec.decoration = DecorationShape::Cube;
        else if ([shape isEqual:@"cutCube"]) spec.decoration = DecorationShape::CutCube;
        else if ([shape isEqual:@"fractal"]) spec.decoration = DecorationShape::Fractal;
        else { error = "unknown decoration shape"; return false; }
        id size = decoration[@"size"];
        if (size) {
            if (![size isKindOfClass:[NSNumber class]] || !std::isfinite([size doubleValue]) || [size doubleValue] < 0.04 || [size doubleValue] > 0.3) { error = "cube size must be between 0.04 and 0.3 meters"; return false; }
            spec.cubeSize = [size floatValue];
        }
        id color = decoration[@"color"];
        if (color) {
            if (!Floats(color, spec.cubeColor, 3) || std::any_of(std::begin(spec.cubeColor), std::end(spec.cubeColor), [](float v) { return v < 0 || v > 1; })) { error = "cube color must be [r,g,b] between 0 and 1"; return false; }
        }
        id speed = decoration[@"degreesPerSecond"];
        if (speed) {
            if (![speed isKindOfClass:[NSNumber class]] || !std::isfinite([speed doubleValue]) || std::abs([speed doubleValue]) > 180) { error = "cube speed must be between -180 and 180 degrees per second"; return false; }
            spec.cubeSpeed = [speed floatValue];
        }
    }
    id closable = json[@"closable"];
    if (closable && ![closable isKindOfClass:[NSNumber class]]) { error = "\"closable\" must be true or false"; return false; }
    if (closable) spec.closable = [closable boolValue];
    if (json[@"accent"] && !Floats(json[@"accent"], spec.accent, 3)) {
        error = "\"accent\" must be [r, g, b] (0-1)";
        return false;
    }
    for (float& c : spec.accent) c = std::clamp(c, 0.0f, 1.0f);
    out = spec;
    return true;
}
}
