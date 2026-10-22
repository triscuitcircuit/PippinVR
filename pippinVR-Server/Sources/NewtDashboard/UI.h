#ifndef NEWT_UI_H
#define NEWT_UI_H
#import <AppKit/AppKit.h>

#include <array>
#include "ColorPicker.h"
#include "Newt/DrawHelpers.h"
#include <string>
#include <vector>

enum class Page { Screens, Media, Games, Settings };

constexpr std::array<const char*, 9> kMenuItems = {
    "Screens", "+ Screen", "Remove", "Reset", "Settings", "Hide", "Exit", "3D Apps", "Media"
};

PixelImage RenderMenu(int selected, const char* notice = "", bool buttons = true);
PixelImage RenderContent(Page page, GridColor grid = {}, float volume = 0.7f,
                         const std::vector<std::string>& apps = {});
PixelImage RenderDockButton(int index, bool selected);

PixelImage RenderLogo();
PixelImage RenderPanelBar();

#endif // NEWT_UI_H
