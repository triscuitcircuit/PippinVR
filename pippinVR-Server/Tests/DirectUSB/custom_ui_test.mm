#include "CustomUI.h"
#include <cassert>
#include <cstdio>
using namespace customui;
static bool Parse(NSString* json, PanelSpec& spec, std::string& error) {
    id object = [NSJSONSerialization JSONObjectWithData:[json dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
    return ParsePanelSpec(object, "demo", spec, error);
}
int main() {
    @autoreleasepool {

        PanelSpec spec;
        spec.title = "Hello";
        spec.lines = {"one", "two"};
        spec.buttons = {{"a", "A"}, {"b", "B"}, {"c", "C"}, {"d", "D"}, {"e", "E"}};
        Layout layout = LayoutPanel(spec, 2.0f);
        assert(layout.buttons.size() == 5 && layout.lines.size() == 2 && layout.image.w > 0);
        assert(layout.buttons[3].y > layout.buttons[0].y + 80);
        assert(layout.image.y > layout.lines[1].y && layout.buttons[0].y > layout.image.y + layout.image.h - 1);
        assert(layout.height > layout.buttons[4].y + layout.buttons[4].h && layout.height <= kMaxCardHeight);

        for (size_t i = 0; i < layout.buttons.size(); ++i) {
            const Area& b = layout.buttons[i];
            assert(HitTest(layout, b.x + b.w / 2, b.y + b.h / 2) == int(i));
        }
        assert(HitTest(layout, layout.close.x + 10, layout.close.y + 10) == kCloseHit);
        assert(HitTest(layout, 512, layout.lines[0].y + 5) == kNoHit);

        PanelSpec plain;
        plain.closable = false;
        Layout tall = LayoutPanel(plain, 0.25f);
        assert(tall.image.h <= 640 && tall.image.x > 300 && tall.close.w == 0 && tall.buttons.empty());
        assert(LayoutPanel(PanelSpec{}, 0).height >= 120);

        PanelSpec big;
        for (int i = 0; i < 40; ++i) { big.lines.push_back("x"); big.buttons.push_back({"b", "b"}); }
        Layout capped = LayoutPanel(big, 0);
        assert(int(capped.lines.size()) == kMaxLines && int(capped.buttons.size()) == kMaxButtons && capped.height <= kMaxCardHeight);


        float half = 0;
        assert(RotationYaw(RotationMode::Spin, 0, 0, 2, 45, half) && std::abs(half - 0.785398f) < 0.0001f);
        assert(RotationYaw(RotationMode::FaceUser, 1, 0, 0, 0, half) && std::abs(half - 0.785398f) < 0.0001f);
        assert(!RotationYaw(RotationMode::FaceUser, 0, 0, 0, 0, half));
        assert(!RotationYaw(RotationMode::Fixed, 1, 1, 1, 1, half));
        std::string error;
        assert(Parse(@"{\"title\":\"Build\",\"lines\":[\"ok\"],\"buttons\":[\"Retry\",{\"id\":\"stop\",\"label\":\"Stop\"}],"
                     "\"anchor\":\"head\",\"width\":0.4,\"position\":[0.1,0.2,-0.8],\"closable\":false,\"accent\":[1,0.5,0]}",
                     spec, error));
        assert(spec.id == "demo" && spec.title == "Build" && spec.lines.size() == 1 && spec.buttons.size() == 2);
        assert(spec.buttons[0].id == "Retry" && spec.buttons[1].id == "stop" && spec.buttons[1].label == "Stop");
        assert(spec.anchor == Anchor::Head && spec.width == 0.4f && spec.position[2] == -0.8f && !spec.closable);
        assert(Parse(@"{\"lines\":\"single line\"}", spec, error) && spec.lines.size() == 1 && spec.anchor == Anchor::World);
        assert(Parse(@"{\"width\":50,\"position\":[0,0,-99]}", spec, error) && spec.width == 2.0f && spec.position[2] == -5.0f);
        assert(Parse(@"{\"orientation\":[0,0,0,1],\"rotation\":{\"mode\":\"spin\",\"degreesPerSecond\":-45}}", spec, error));
        assert(spec.orientation[3] == 1 && spec.rotation == RotationMode::Spin && spec.degreesPerSecond == -45);
        assert(Parse(@"{\"rotation\":{\"mode\":\"faceUser\"}}", spec, error) && spec.rotation == RotationMode::FaceUser);
        assert(Parse(@"{\"decoration\":{\"shape\":\"fractal\",\"size\":0.15,\"color\":[0.2,0.8,0.6],\"degreesPerSecond\":25}}", spec, error));
        assert(spec.decoration == DecorationShape::Fractal && std::abs(spec.cubeSize - 0.15f) < 0.0001f);
        assert(Parse(@"{\"decoration\":{\"shape\":\"cutCube\"}}", spec, error) && spec.decoration == DecorationShape::CutCube);
        assert(!Parse(@"{\"decoration\":{\"shape\":\"fractal\",\"size\":5}}", spec, error));
        assert(!Parse(@"{\"decoration\":{\"shape\":\"nope\"}}", spec, error));
        assert(!Parse(@"{\"orientation\":[0,0,0,0]}", spec, error));
        assert(!Parse(@"{\"rotation\":{\"mode\":\"spin\",\"degreesPerSecond\":181}}", spec, error));
        assert(!Parse(@"{\"anchor\":\"wall\"}", spec, error) && error.find("anchor") != std::string::npos);
        assert(!Parse(@"{\"buttons\":[3]}", spec, error));
        assert(!Parse(@"{\"position\":[1,2]}", spec, error));
        assert(!Parse(@"{\"title\":5}", spec, error));
        assert(!Parse(@"[1,2]", spec, error));
        assert(Parse(@"{\"title\":\"0123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890\"}", spec, error)
               && spec.title.size() < 90);
        puts("PASS: custom panel layout, hit testing, caps; script panel parsing and errors");
    }
}
