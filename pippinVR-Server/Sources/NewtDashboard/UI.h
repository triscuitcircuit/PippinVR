#ifndef NEWT_UI_H
#define NEWT_UI_H

#import <AppKit/AppKit.h>

#include <array>
#include "ColorPicker.h"
#include "WristClockSettings.h"
#include "PassthroughSettings.h"
#include "Newt/DrawHelpers.h"
#include <string>
#include <vector>

enum class Page { Screens, Media, Games, Settings };

constexpr std::array<const char*, 9> kMenuItems = {
    "Screens", "+ Screen", "Remove", "Reset", "Settings", "Hide", "Exit", "3D Apps", "Media"
};

PixelImage RenderMenu(int selected, const char* notice = "", bool buttons = true, int leftBattery = -1, int rightBattery = -1);
PixelImage RenderContent(Page page, GridColor grid = {}, float volume = 0.7f,
                         const std::vector<std::string>& apps = {},
                         const WristClockSettings& clock = {}, int settingsTab = 0,
                         const PassthroughSettings& passthrough = {}, int audioMode = 1);

PixelImage RenderPassthroughPlaceholder();
PixelImage RenderTracePrompt(NSString* title, NSString* detail, int placed);
PixelImage RenderAlertCard(NSString* title, NSString* detail);
PixelImage RenderDockButton(int index, bool selected);

void DrawPippinLogo(NSRect rect);
PixelImage RenderLogo();
NSString* WristClockText(const WristClockSettings& settings = {});
PixelImage RenderWristClock(NSString* text, const WristClockSettings& settings = {});
PixelImage RenderPanelBar();
PixelImage RenderModelPopup(int hoveredButton, float scale, bool inFront);

struct MetricsSnapshot {
    uint64_t framesPrepared = 0;
    float fps = 0.0f;
    float budgetMs = 0.0f;
    float periodMs = 0.0f;
    float prepareMs = 0.0f;
    float drawMs = 0.0f;
    bool metalFXEnabled = false;
    bool metalFXActive = false;
    uint32_t metalFXInputWidth = 0;
    uint32_t metalFXInputHeight = 0;
    uint32_t metalFXOutputWidth = 0;
    uint32_t metalFXOutputHeight = 0;
    float encodeStageMs = -1.0f;
    float txMs = -1.0f;
    uint64_t encodedFrames = 0;
    std::vector<float> ageHistory;
    std::vector<float> periodHistory;
    std::vector<float> drawHistory;
    std::vector<float> encodeHistory;
};
PixelImage RenderMetricsGraph(const MetricsSnapshot& snapshot);

#endif
