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
