#include "UI.h"
#include "InteractionGeometry.h"
#include <algorithm>

PixelImage RenderMenu(int selected, const char* notice, bool buttons) {
    return MakeImage(^(NSRect bounds) {
        FillRounded(bounds, 16, RGB(0.08f, 0.085f, 0.095f));


        NSArray<NSString*>* symbols = @[@"display.2", @"plus.rectangle", @"minus.rectangle", @"arrow.counterclockwise", @"gearshape", @"chevron.down", @"power", @"cube", @"play.rectangle"];
        for (size_t i = 0; buttons && i < kMenuItems.size(); ++i) {
            CGFloat x = 148 + i * 95;
            BOOL active = static_cast<int>(i) == selected;
            // Square, not rounded: the button's 3D body is a flat rectangular
            // extrusion wrapped onto the dock's curve (see InteractionGeometry.h's
            // MakeDockButton), and a rounded highlight drawn into this flat 2D
            // texture never actually matched that geometry's real silhouette.
            FillRounded(NSMakeRect(x, 46, 88, 82), 0, active ? RGB(0.12f, 0.38f, 0.34f) : RGB(0.15f, 0.16f, 0.18f));
            NSImage* icon = [[NSImage imageWithSystemSymbolName:symbols[i] accessibilityDescription:nil]
                imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithHierarchicalColor:[NSColor whiteColor]]];
            [icon drawInRect:NSMakeRect(x + 30, 60, 28, 28)];
            DrawText([NSString stringWithUTF8String:kMenuItems[i]], NSMakeRect(x + 2, 100, 84, 23), 14, YES,
                RGB(0.94f, 0.96f, 0.95f), NSTextAlignmentCenter);
        }
        DrawText([NSString stringWithUTF8String:notice], NSMakeRect(148, 14, 850, 23), 15, NO, RGB(0.66f, 0.76f, 0.74f));
        DrawText(@"Y / B or Menu: reopen dashboard", NSMakeRect(148, 138, 840, 20), 12, NO, RGB(0.66f, 0.70f, 0.72f));
    }, 1024, 160);
}

PixelImage RenderContent(Page page, GridColor grid, float volume, const std::vector<std::string>& apps) {
    return MakeImage(^(NSRect bounds) {
        FillRounded(bounds, 24, RGB(0.055f, 0.07f, 0.085f, 0.98f));
        NSColor* white = RGB(0.93f, 0.95f, 0.94f);
        NSColor* muted = RGB(0.62f, 0.68f, 0.70f);
        if (page == Page::Screens) {
            DrawText(@"Screens", NSMakeRect(52, 36, 500, 54), 42, YES, white);
            FillRounded(NSMakeRect(70, 150, 400, 260), 10, RGB(0.16f, 0.34f, 0.38f));
            FillRounded(NSMakeRect(510, 170, 350, 220), 10, RGB(0.28f, 0.32f, 0.30f));
            DrawText(@"Virtual display", NSMakeRect(98, 250, 340, 40), 28, YES, white,
                     NSTextAlignmentCenter);
            DrawText(@"Desktop", NSMakeRect(535, 255, 300, 40), 28, YES, white,
                     NSTextAlignmentCenter);
            DrawText(@"Starting live macOS desktop screen capture...",
                     NSMakeRect(70, 500, 850, 70), 24, NO, muted);
        } else if (page == Page::Media) {
            DrawText(@"Media", NSMakeRect(52, 36, 500, 54), 42, YES, white);
            FillRounded(NSMakeRect(70, 145, 410, 280), 10, RGB(0.42f, 0.25f, 0.18f));
            FillRounded(NSMakeRect(495, 145, 410, 280), 10, RGB(0.18f, 0.30f, 0.42f));
            DrawText(@"LEFT", NSMakeRect(70, 260, 410, 42), 30, YES, white, NSTextAlignmentCenter);
            DrawText(@"RIGHT", NSMakeRect(495, 260, 410, 42), 30, YES, white, NSTextAlignmentCenter);
            DrawText(@"Starting live camera / video feed...",
                     NSMakeRect(70, 500, 850, 70), 24, NO, muted);
        } else if (page == Page::Games) {
            DrawText(@"3D Apps", NSMakeRect(52, 36, 500, 54), 42, YES, white);
            const int shown = std::min(static_cast<int>(apps.size()), kAppsVisible);
            for (int i = 0; i < shown; ++i) {
                FillRounded(NSMakeRect(kAppsRowX, kAppsRowTop + i * kAppsRowStride, kAppsRowWidth, kAppsRowHeight), 12, RGB(0.15f, 0.18f, 0.20f));
                DrawText([NSString stringWithUTF8String:apps[i].c_str()],
                         NSMakeRect(kAppsRowX + 30, kAppsRowTop + i * kAppsRowStride + 20, 760, 38), 28, YES, white);
            }
            if (shown == 0) {
                DrawText(@"No apps configured. On your Mac run:\nnewt configure --app \"Title=/path/to/app\"",
                         NSMakeRect(70, 160, 850, 90), 24, NO, muted);
            }
            DrawText(@"Point and squeeze the trigger to launch. Pippin hands the headset to the app, then returns here.",
                     NSMakeRect(70, 520, 850, 60), 24, NO, muted);
        } else {
            DrawText(@"Settings", NSMakeRect(52, 36, 500, 54), 42, YES, white);
            DrawText(@"Grid color — hold trigger and drag",NSMakeRect(70,105,840,28),22,YES,white);
            CGContextRef ctx=[NSGraphicsContext currentContext].CGContext;
            CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB();
            const CGFloat hueStops[]={1,0,0,1, 1,1,0,1, 0,1,0,1, 0,1,1,1, 0,0,1,1, 1,0,1,1, 1,0,0,1};
            CGGradientRef hue=CGGradientCreateWithColorComponents(space,hueStops,nullptr,7);
            CGContextSaveGState(ctx);CGContextClipToRect(ctx,CGRectMake(70,140,570,36));
            CGContextDrawLinearGradient(ctx,hue,CGPointMake(70,140),CGPointMake(640,140),0);
            CGContextRestoreGState(ctx);CGGradientRelease(hue);
            GridColor pure=grid;pure.saturation=1;pure.value=1;auto hueRGB=pure.rgb();
            const CGFloat svStops[]={1,1,1,1,hueRGB[0],hueRGB[1],hueRGB[2],1};
            CGGradientRef saturation=CGGradientCreateWithColorComponents(space,svStops,nullptr,2);
            const CGFloat valueStops[]={0,0,0,0,0,0,0,1};
            CGGradientRef value=CGGradientCreateWithColorComponents(space,valueStops,nullptr,2);
            CGContextSaveGState(ctx);CGContextClipToRect(ctx,CGRectMake(70,202,570,240));
            CGContextDrawLinearGradient(ctx,saturation,CGPointMake(70,202),CGPointMake(640,202),0);
            CGContextDrawLinearGradient(ctx,value,CGPointMake(70,202),CGPointMake(70,442),0);
            CGContextRestoreGState(ctx);CGGradientRelease(saturation);CGGradientRelease(value);CGColorSpaceRelease(space);
            [white setStroke];
            NSBezierPath* marker=[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(70+grid.saturation*570-7,202+(1-grid.value)*240-7,14,14)];
            marker.lineWidth=3;[marker stroke];
            NSBezierPath* hueMarker=[NSBezierPath bezierPathWithRect:NSMakeRect(70+grid.hue*570-3,137,6,42)];hueMarker.lineWidth=2;[hueMarker stroke];
            auto selected=grid.rgb();
            FillRounded(NSMakeRect(690,202,220,98),12,RGB(selected[0],selected[1],selected[2]));
            DrawText([NSString stringWithFormat:@"#%02X%02X%02X",int(selected[0]*255+0.5f),int(selected[1]*255+0.5f),int(selected[2]*255+0.5f)],NSMakeRect(690,305,220,25),20,YES,white,NSTextAlignmentCenter);
            FillRounded(NSMakeRect(690,330,220,60),10,RGB(0.15f,0.18f,0.20f));
            DrawText(grid.enabled?@"Grid: On":@"Grid: Off",NSMakeRect(700,347,200,30),23,YES,white,NSTextAlignmentCenter);
            FillRounded(NSMakeRect(70,470,840,68),10,RGB(0.15f,0.18f,0.20f));
            DrawText([NSString stringWithFormat:@"Media volume: %d%% — select to change",int(volume*100+0.5f)],NSMakeRect(100,488,760,38),23,NO,white);
            DrawText(@"Audio output: Mac headphones / speakers",NSMakeRect(70,548,840,30),20,NO,muted);

        }
        DrawText(@"Y / B or Menu brings Pippin back in front of you", NSMakeRect(54, 594, 700, 28), 19, NO, muted);
    });
}

PixelImage RenderLogo() {
    return MakeImage(^(NSRect bounds) {
        NSString* path = [[NSBundle mainBundle] pathForResource:@"pippin-logo" ofType:@"png"];

        NSImage* logo = [[NSImage alloc] initWithContentsOfFile:path];
        if (logo) [logo drawInRect:bounds];
        else DrawText(@"Pippin", NSMakeRect(8, 94, 240, 64), 44, YES, RGB(0.45f,0.85f,0.72f), NSTextAlignmentCenter);
    },256,256);
}
PixelImage RenderPanelBar() {
    return MakeImage(^(NSRect bounds) {
        FillRounded(bounds,12,RGB(0.10f,0.13f,0.15f));
        DrawText(@"↶",NSMakeRect(0,10,123,46),32,YES,RGB(0.7f,0.9f,0.85f),NSTextAlignmentCenter);
        DrawText(@"Hold squeeze to move",NSMakeRect(123,14,676,40),25,YES,RGB(0.9f,0.94f,0.93f),NSTextAlignmentCenter);
        DrawText(@"Face me",NSMakeRect(799,20,102,32),18,YES,RGB(0.7f,0.9f,0.85f),NSTextAlignmentCenter);
        DrawText(@"↷",NSMakeRect(901,10,123,46),32,YES,RGB(0.7f,0.9f,0.85f),NSTextAlignmentCenter);
    },1024,64);
}

PixelImage RenderDockButton(int index, bool selected) {
    auto atlas=RenderMenu(selected?index:-1);
    PixelImage out; out.width=88;out.height=82;out.pixels.resize(88*82*4);
    for(int y=0;y<82;++y) std::copy_n(atlas.pixels.data()+((y+46)*1024+148+index*95)*4,88*4,out.pixels.data()+y*88*4);
    return out;
}
