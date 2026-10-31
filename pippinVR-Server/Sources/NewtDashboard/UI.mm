#include "UI.h"
#include "Newt/Capture.h"
#include "InteractionGeometry.h"
#include <algorithm>

PixelImage RenderMenu(int selected, const char* notice, bool buttons, int leftBattery, int rightBattery) {
    return MakeImage(^(NSRect bounds) {
        FillRounded(bounds, 16, RGB(0.08f, 0.085f, 0.095f));


        NSArray<NSString*>* symbols = @[@"display.2", @"plus.rectangle", @"minus.rectangle", @"arrow.counterclockwise", @"gearshape", @"chevron.down", @"power", @"cube", @"play.rectangle"];
        for (size_t i = 0; buttons && i < kMenuItems.size(); ++i) {
            CGFloat x = 148 + i * 95;
            BOOL active = static_cast<int>(i) == selected;
            FillRounded(NSMakeRect(x, 46, 88, 82), 0, active ? RGB(0.12f, 0.38f, 0.34f) : RGB(0.15f, 0.16f, 0.18f));
            NSImage* icon = [[NSImage imageWithSystemSymbolName:symbols[i] accessibilityDescription:nil]
                imageWithSymbolConfiguration:[NSImageSymbolConfiguration configurationWithHierarchicalColor:[NSColor whiteColor]]];
            [icon drawInRect:NSMakeRect(x + 30, 60, 28, 28)];
            DrawText([NSString stringWithUTF8String:kMenuItems[i]], NSMakeRect(x + 2, 100, 84, 23), 14, YES,
                RGB(0.94f, 0.96f, 0.95f), NSTextAlignmentCenter);
        }
        DrawText([NSString stringWithUTF8String:notice], NSMakeRect(148, 14, 490, 23), 15, NO, RGB(0.66f, 0.76f, 0.74f));
        NSString* left = leftBattery >= 0 ? [NSString stringWithFormat:@"%d%%", leftBattery] : @"—";
        NSString* right = rightBattery >= 0 ? [NSString stringWithFormat:@"%d%%", rightBattery] : @"—";
        DrawText([NSString stringWithFormat:@"Quest —   L %@   R %@", left, right],
                 NSMakeRect(640, 14, 358, 23), 15, YES, RGB(0.66f, 0.76f, 0.74f), NSTextAlignmentRight);
        DrawText(@"Y / B or Menu: reopen dashboard", NSMakeRect(148, 138, 840, 20), 12, NO, RGB(0.66f, 0.70f, 0.72f));
    }, 1024, 160);
}

PixelImage RenderContent(Page page, GridColor grid, float volume, const std::vector<std::string>& apps,
                         const WristClockSettings& clock, int settingsTab,
                         const PassthroughSettings& passthrough, int audioMode) {
    const bool clockPage = settingsTab == 1;
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
        } else if (clockPage) {
            DrawText(@"Settings", NSMakeRect(52, 36, 450, 54), 42, YES, white);
            DrawText(@"Select a tile to change its value", NSMakeRect(70, 104, 840, 30), 22, NO, muted);
            NSArray<NSString*>* titles = @[@"Wrist clock", @"Show on", @"Clock size", @"Time format",
                                           @"Date", @"Position", @"Accent color", @"Reset clock"];
            NSArray<NSString*>* hands = @[@"Either hand", @"Left hand", @"Right hand"];
            NSArray<NSString*>* sizes = @[@"Small", @"Medium", @"Large"];
            NSArray<NSString*>* formats = @[@"System default", @"12-hour", @"24-hour"];
            NSArray<NSString*>* colors = @[@"Mint", @"Blue", @"Amber", @"White"];
            NSArray<NSString*>* values = @[clock.enabled ? @"On" : @"Off", hands[clock.hand], sizes[clock.size],
                formats[clock.format], clock.showDate ? @"Show date" : @"Time only",
                clock.position == 0 ? @"Above wrist" : @"Close to wrist", colors[clock.color], @"Restore defaults"];
            for (int i = 0; i < 8; ++i) {
                const CGFloat x = kClockControlX + (i % 2) * kClockColumnStride;
                const CGFloat y = kClockControlY + (i / 2) * kClockRowStride;
                FillRounded(NSMakeRect(x, y, kClockControlWidth, kClockControlHeight), 12, RGB(0.13f, 0.17f, 0.20f));
                DrawText(titles[i], NSMakeRect(x + 20, y + 9, 390, 26), 19, NO, muted);
                DrawText(values[i], NSMakeRect(x + 20, y + 36, 390, 34), 27, YES, white);
            }
            DrawText(@"Changes apply immediately and save automatically.", NSMakeRect(70, 534, 884, 28), 21, NO, muted);
            DrawText(@"Turn your palm toward your face to reveal the clock.", NSMakeRect(70, 562, 884, 28), 20, NO, muted);
        } else if (settingsTab == 2) {
            DrawText(@"Settings", NSMakeRect(52, 36, 280, 54), 42, YES, white);
            DrawText(passthrough.allowed ? @"See your room through a window in VR · camera access allowed on Mac"
                                         : @"Camera access is off — allow it in PippinVR Settings on your Mac",
                     NSMakeRect(70, 104, 840, 30), 22, NO, muted);
            NSArray<NSString*>* titles = @[@"Passthrough portal", @"View", @"Portal size", @"Lens",
                                           @"Field of view", @"Anchor", @"Frame", @"Direction",
                                           @"Cutout", @"Reset cutout", @"Position", @"Hands"];
            NSArray<NSString*>* fovs = @[@"Narrow (70°)", @"Normal (90°)", @"Wide (110°)"];
            NSArray<NSString*>* values = @[passthrough.enabled ? @"On" : @"Off",
                passthrough.stereo ? @"3D (both cameras)" : @"2D (left camera)",
                [NSString stringWithFormat:@"%.2f × %.2f m · Reset", passthrough.width, passthrough.height],
                @[@"Fisheye", @"Corrected", @"See-through"][passthrough.lensMode],
                fovs[passthrough.fov],
                passthrough.anchor == 0 ? @"Room (stays put)" : @"Follow me",
                passthrough.frame ? @"Window frame" : @"None",
                passthrough.direction == 0 ? @"Ahead" : @"Desk (looks down)",
                passthrough.tracing ? @"Tracing · select to cancel" : @"Trace in room",
                @"Whole portal",
                passthrough.locked ? @"Locked · select to unlock" : @"Movable · select to lock",
                @[@"Off", @"Real hands · outline", @"Real hands · shape", @"Real hands · depth"][passthrough.hands]];
            for (int i = 0; i < kPassthroughControls; ++i) {
                const CGFloat x = kClockControlX + (i % 2) * kClockColumnStride;
                const CGFloat y = kClockControlY + (i / 2) * kPassthroughRowStride;
                const bool active = (i == 8 && passthrough.tracing) || (i == 10 && passthrough.locked) ||
                                    (i == 11 && passthrough.hands != 0);
                FillRounded(NSMakeRect(x, y, kClockControlWidth, kPassthroughTileHeight), 12,
                            active ? RGB(0.12f, 0.38f, 0.34f) : RGB(0.13f, 0.17f, 0.20f));
                DrawText(titles[i], NSMakeRect(x + 20, y + 4, 390, 22), 17, NO, muted);
                DrawText(values[i], NSMakeRect(x + 20, y + 26, 390, 30), 22, YES, white);
            }
            DrawText(@"Grab the bar to move · both grips to stretch · right stick to resize. VR recordings can include this view.",
                     NSMakeRect(70, 536, 884, 26), 19, NO, muted);
            DrawText(@"Trace in room: touch 4 real corners with a controller tip and pull the trigger at each.",
                     NSMakeRect(70, 562, 884, 26), 19, NO, muted);
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
            FillRounded(NSMakeRect(690,400,220,50),10,RGB(0.15f,0.18f,0.20f));
            DrawText(ScreenCaptureBadgeVisible()?@"Screen labels: On":@"Screen labels: Off",NSMakeRect(700,412,200,28),19,YES,white,NSTextAlignmentCenter);
            FillRounded(NSMakeRect(70,470,570,68),10,RGB(0.15f,0.18f,0.20f));
            DrawText([NSString stringWithFormat:@"Media volume: %d%% — select to change",int(volume*100+0.5f)],NSMakeRect(100,488,520,38),23,NO,white);
            NSArray<NSString*>* soundModes=@[@"Sound: Mac",@"Sound: Stereo",@"Sound: HRTF",@"Sound: HRTF HQ"];
            FillRounded(NSMakeRect(690,470,220,68),10,audioMode>=2?RGB(0.12f,0.38f,0.34f):RGB(0.15f,0.18f,0.20f));
            DrawText(soundModes[std::clamp(audioMode,0,3)],NSMakeRect(700,488,200,38),23,YES,white,NSTextAlignmentCenter);
            FillRounded(NSMakeRect(70,548,370,36),8,RGB(0.15f,0.18f,0.20f));
            DrawText(@"Recording view: change",NSMakeRect(80,553,350,26),19,YES,white,NSTextAlignmentCenter);
            FillRounded(NSMakeRect(460,548,210,36),8,RGB(0.15f,0.18f,0.20f));
            DrawText(@"Show / hide view",NSMakeRect(466,553,198,26),17,YES,white,NSTextAlignmentCenter);
            FillRounded(NSMakeRect(690,548,220,36),8,RGB(0.15f,0.18f,0.20f));
            DrawText(@"Record / Stop",NSMakeRect(700,553,200,26),19,YES,white,NSTextAlignmentCenter);

        }
        if (page == Page::Settings) {
            NSArray<NSString*>* tabs = @[@"Appearance", @"Wrist Clock", @"Passthrough"];
            for (int tab = 0; tab < 3; ++tab) {
                const CGFloat x = kSettingsTabX[tab];
                FillRounded(NSMakeRect(x, 36, kSettingsTabWidth, 50), 10,
                            settingsTab == tab ? RGB(0.12f, 0.38f, 0.34f) : RGB(0.15f, 0.18f, 0.20f));
                DrawText(tabs[tab], NSMakeRect(x + 8, 46, kSettingsTabWidth - 16, 32),
                         23, YES, white, NSTextAlignmentCenter);
            }
        }
        DrawText(@"Y / B or Menu brings Pippin back in front of you", NSMakeRect(54, 594, 700, 28), 19, NO, muted);
    });
}

PixelImage RenderPassthroughPlaceholder() {
    return MakeImage(^(NSRect bounds) {
        FillRounded(bounds, 24, RGB(0.055f, 0.07f, 0.085f, 0.98f));
        DrawText(@"Passthrough", NSMakeRect(52, 36, 600, 54), 42, YES, RGB(0.93f, 0.95f, 0.94f));
        DrawPippinLogo(NSMakeRect(448, 108, 128, 128));
        DrawText(@"Waiting for headset cameras…", NSMakeRect(70, 260, 884, 44), 30, YES,
                 RGB(0.48f, 0.88f, 0.78f), NSTextAlignmentCenter);
        DrawText(@"If nothing appears, restart the headset session after allowing camera access on your Mac.",
                 NSMakeRect(70, 330, 884, 60), 22, NO, RGB(0.62f, 0.68f, 0.70f), NSTextAlignmentCenter);
    });
}

PixelImage RenderTracePrompt(NSString* title, NSString* detail, int placed) {
    return MakeImage(^(NSRect bounds) {
        FillRounded(bounds, 28, RGB(0.055f, 0.07f, 0.085f, 0.92f));
        DrawText(title, NSMakeRect(36, 26, 952, 64), 44, YES, RGB(0.95f, 0.68f, 0.20f), NSTextAlignmentCenter);

        for (int i = 0; i < 4; ++i) {
            const NSRect dot = NSMakeRect(512 - 2 * 46 + i * 46 + 6, 104, 34, 34);
            NSBezierPath* path = [NSBezierPath bezierPathWithOvalInRect:dot];
            if (i < placed) { [RGB(0.30f, 0.85f, 0.65f) setFill]; [path fill]; }
            else { [RGB(0.62f, 0.68f, 0.70f) setStroke]; path.lineWidth = 3; [path stroke]; }
        }
        DrawText(detail, NSMakeRect(36, 160, 952, 60), 26, NO, RGB(0.85f, 0.88f, 0.87f), NSTextAlignmentCenter);
    }, 1024, 240);
}

PixelImage RenderAlertCard(NSString* title, NSString* detail) {
    return MakeImage(^(NSRect bounds) {
        FillRounded(bounds, 26, RGB(0.10f, 0.07f, 0.075f, 0.94f));
        FillRounded(NSMakeRect(0, 0, 14, bounds.size.height), 7, RGB(0.93f, 0.42f, 0.32f));
        DrawText(title, NSMakeRect(40, 30, 800, 56), 38, YES, RGB(0.97f, 0.82f, 0.76f));
        DrawText(detail, NSMakeRect(40, 100, 800, 90), 26, NO, RGB(0.80f, 0.80f, 0.80f));

        FillRounded(NSMakeRect(890, 60, 100, 100), 50, RGB(0.22f, 0.16f, 0.16f));
        DrawText(@"×", NSMakeRect(890, 70, 100, 80), 64, YES, RGB(0.97f, 0.82f, 0.76f), NSTextAlignmentCenter);
        DrawText(@"swipe", NSMakeRect(890, 168, 100, 30), 18, NO, RGB(0.55f, 0.55f, 0.55f), NSTextAlignmentCenter);
    }, 1024, 220);
}

void DrawPippinLogo(NSRect rect) {
    NSString* path = [[NSBundle mainBundle] pathForResource:@"pippin-logo" ofType:@"png"];
    NSImage* logo = path ? [[NSImage alloc] initWithContentsOfFile:path] : nil;
    if (!logo) logo = [NSApp applicationIconImage];
    if (logo) {
        [logo drawInRect:rect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1.0
             respectFlipped:YES hints:nil];
    } else {
        DrawText(@"Pippin", rect, std::min(rect.size.width, rect.size.height) * 0.17, YES,
                 RGB(0.45f,0.85f,0.72f), NSTextAlignmentCenter);
    }
}

PixelImage RenderLogo() {
    return MakeImage(^(NSRect bounds) { DrawPippinLogo(bounds); }, 256, 256);
}

PixelImage RenderModelPopup(int hoveredButton, float scale, bool inFront) {
    return MakeImage(^(NSRect bounds) {
        FillRounded(bounds, 24, RGB(0.055f, 0.07f, 0.085f, 0.97f));
        DrawText([NSString stringWithFormat:@"3D MODEL  ·  %.2fx  ·  %@", scale,
                                                inFront ? @"In front" : @"Room origin"],
                 NSMakeRect(28, 190, 968, 42), 28, YES,
                 RGB(0.93f, 0.95f, 0.94f), NSTextAlignmentCenter);
        NSArray<NSString*>* labels = @[@"- Scale", @"+ Scale", @"Rotate", @"Place", @"Remove"];
        for (int i = 0; i < 5; ++i) {
            const CGFloat x = 24 + i * 196;
            const BOOL hovered = i == hoveredButton;
            NSColor* fill = hovered
                ? (i == 4 ? RGB(0.55f, 0.20f, 0.20f) : RGB(0.12f, 0.42f, 0.37f))
                : (i == 4 ? RGB(0.28f, 0.13f, 0.14f) : RGB(0.15f, 0.18f, 0.21f));
            FillRounded(NSMakeRect(x, 28, 184, 132), 16, fill);
            DrawText(labels[i], NSMakeRect(x + 6, 76, 172, 38), 25, YES,
                     RGB(0.94f, 0.96f, 0.95f), NSTextAlignmentCenter);
        }
    }, 1024, 256);
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

NSString* WristClockText(const WristClockSettings& settings) {
    NSDate* now = [NSDate date];
    NSString* time = [NSDateFormatter localizedStringFromDate:now dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterShortStyle];
    if (settings.format != 0) {
        NSDateFormatter* formatter = [[NSDateFormatter alloc] init];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.dateFormat = settings.format == 1 ? @"h:mm a" : @"HH:mm";
        time = [formatter stringFromDate:now];
    }
    if (!settings.showDate) return time;
    NSString* date = [NSDateFormatter localizedStringFromDate:now dateStyle:NSDateFormatterMediumStyle timeStyle:NSDateFormatterNoStyle];
    return [NSString stringWithFormat:@"%@\n%@", time, date];
}

PixelImage RenderWristClock(NSString* text, const WristClockSettings& settings) {
    return MakeImage(^(NSRect bounds) {
        FillRounded(bounds, 32, RGB(0.035f, 0.055f, 0.07f, 0.97f));
        NSColor* accent = settings.color == 1 ? RGB(0.38f, 0.68f, 1.0f) :
                          settings.color == 2 ? RGB(1.0f, 0.72f, 0.30f) :
                          settings.color == 3 ? RGB(0.94f, 0.96f, 0.98f) : RGB(0.4f, 0.85f, 0.75f);
        FillRounded(NSMakeRect(24, 28, 5, 136), 2, accent);
        NSArray<NSString*>* lines = [text componentsSeparatedByString:@"\n"];
        DrawText(lines.firstObject ?: @"", NSMakeRect(42, settings.showDate ? 22 : 48, 446, 92), 64, YES,
                 RGB(0.96f, 0.98f, 0.98f), NSTextAlignmentCenter);
        if (settings.showDate) DrawText(lines.count > 1 ? lines[1] : @"", NSMakeRect(42, 120, 446, 42), 28, NO,
                 accent, NSTextAlignmentCenter);
    }, 512, 192);
}

PixelImage RenderMetricsGraph(const MetricsSnapshot& s) {
    return MakeImage(^(NSRect bounds) {
        FillRounded(bounds, 20, RGB(0.045f, 0.06f, 0.075f, 0.96f));
        NSColor* white = RGB(0.94f, 0.96f, 0.95f);
        NSColor* muted = RGB(0.72f, 0.78f, 0.76f);
        DrawText(@"PERFORMANCE", NSMakeRect(36, 24, 400, 36), 30, YES, white);
        NSString* headline = s.fps > 0
            ? [NSString stringWithFormat:@"%.0f FPS / %.0f Hz target", s.fps, s.budgetMs > 0 ? 1000 / s.budgetMs : 0]
            : @"Collecting frames…";
        DrawText(headline, NSMakeRect(420, 20, 568, 44), 32, YES, white, NSTextAlignmentRight);
        DrawText([NSString stringWithFormat:@"Frame %.2f ms   Prepare %.2f ms   CPU draw %.2f ms",
                  s.periodMs, s.prepareMs, s.drawMs], NSMakeRect(36, 72, 952, 34), 25, NO, white);
        NSString* encodeText = s.encodeStageMs >= 0
            ? [NSString stringWithFormat:@"Encode stage %.2f ms     USB transfer %.2f ms", s.encodeStageMs, s.txMs]
            : @"Encode / USB: waiting for fresh samples";
        DrawText(encodeText, NSMakeRect(36, 110, 952, 34), 25, NO, muted);
        NSString* fxText = s.metalFXActive
            ? [NSString stringWithFormat:@"MetalFX %ux%u → %ux%u", s.metalFXInputWidth, s.metalFXInputHeight,
               s.metalFXOutputWidth, s.metalFXOutputHeight]
            : (s.metalFXEnabled ? @"MetalFX ready · no active upscale" : @"MetalFX off");
        DrawText(fxText, NSMakeRect(36, 152, 952, 30), 22, NO, muted);

        const CGFloat graphX = 94, graphY = 216, graphW = 882, graphH = 208;
        CGFloat peak = std::max(10.0f, s.budgetMs);
        for (const auto* values : {&s.periodHistory, &s.drawHistory, &s.encodeHistory}) {
            for (size_t i = 0; i < values->size(); ++i) {
                if (i < s.ageHistory.size() && s.ageHistory[i] <= 30 && std::isfinite((*values)[i]))
                    peak = std::max<CGFloat>(peak, (*values)[i]);
            }
        }
        const CGFloat maxMs = std::ceil(peak / 5.0) * 5.0;
        for (int i = 0; i <= 2; ++i) {
            const CGFloat y = graphY + graphH * (1 - i / 2.0);
            [RGB(1, 1, 1, 0.16f) setStroke];
            NSBezierPath* grid = [NSBezierPath bezierPath];
            [grid moveToPoint:NSMakePoint(graphX, y)];
            [grid lineToPoint:NSMakePoint(graphX + graphW, y)];
            [grid stroke];
            DrawText([NSString stringWithFormat:@"%.0f", maxMs * i / 2], NSMakeRect(20, y - 12, 62, 26),
                     20, NO, muted, NSTextAlignmentRight);
        }
        if (s.budgetMs > 0) {
            NSBezierPath* budget = [NSBezierPath bezierPath];
            const CGFloat y = graphY + graphH * (1 - s.budgetMs / maxMs);
            [budget moveToPoint:NSMakePoint(graphX, y)];
            [budget lineToPoint:NSMakePoint(graphX + graphW, y)];
            CGFloat dash[] = {7, 5};
            [budget setLineDash:dash count:2 phase:0];
            [muted setStroke];
            [budget stroke];
        }
        auto drawSeries = [&](const std::vector<float>& values, NSColor* color) {
            NSBezierPath* path = [NSBezierPath bezierPath];
            bool connected = false;
            for (size_t i = 0; i < values.size() && i < s.ageHistory.size(); ++i) {
                if (!std::isfinite(values[i]) || values[i] < 0 || s.ageHistory[i] > 30) {
                    connected = false;
                    continue;
                }
                const CGFloat x = graphX + graphW * (1 - s.ageHistory[i] / 30.0);
                const CGFloat y = graphY + graphH * (1 - values[i] / maxMs);
                if (i > 0 && s.ageHistory[i - 1] - s.ageHistory[i] > 1) connected = false;
                if (connected) [path lineToPoint:NSMakePoint(x, y)];
                else [path moveToPoint:NSMakePoint(x, y)];
                connected = true;
            }
            [color setStroke];
            path.lineWidth = 3;
            [path stroke];
        };
        drawSeries(s.periodHistory, [NSColor systemBlueColor]);
        drawSeries(s.drawHistory, [NSColor systemGreenColor]);
        drawSeries(s.encodeHistory, [NSColor systemOrangeColor]);
        DrawText(@"30 seconds ago", NSMakeRect(94, 432, 260, 26), 20, NO, muted);
        DrawText(@"ms · dashed = frame budget", NSMakeRect(350, 432, 420, 26), 20, NO, muted);
        DrawText(@"Now", NSMakeRect(876, 432, 100, 26), 20, NO, muted, NSTextAlignmentRight);
        DrawText(@"● Frame interval", NSMakeRect(94, 468, 290, 28), 22, YES, [NSColor systemBlueColor]);
        DrawText(@"● CPU draw", NSMakeRect(408, 468, 260, 28), 22, YES, [NSColor systemGreenColor]);
        DrawText(@"● Encode stage", NSMakeRect(710, 468, 280, 28), 22, YES, [NSColor systemOrangeColor]);
    }, 1024, 512);
}

PixelImage RenderDockButton(int index, bool selected) {
    auto atlas=RenderMenu(selected?index:-1);
    PixelImage out; out.width=88;out.height=82;out.pixels.resize(88*82*4);
    for(int y=0;y<82;++y) std::copy_n(atlas.pixels.data()+((y+46)*1024+148+index*95)*4,88*4,out.pixels.data()+y*88*4);
    return out;
}
