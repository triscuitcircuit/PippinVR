#ifndef NEWT_COLORPICKER_H
#define NEWT_COLORPICKER_H
// SPDX-License-Identifier: MIT
#include <algorithm>
#include "WristClockSettings.h"
#include "PassthroughSettings.h"
#include <array>
#include <cmath>
struct GridColor {
    float hue=7.0f/12.0f, saturation=1.0f/3.0f, value=0.24f;
    bool enabled=true;
    std::array<float,3> rgb() const {
        float h=(hue-std::floor(hue))*6, c=value*saturation;
        float x=c*(1-std::abs(std::fmod(h,2.0f)-1)), m=value-c;
        std::array<float,3> out;
        if(h<1) out={c,x,0}; else if(h<2) out={x,c,0}; else if(h<3) out={0,c,x};
        else if(h<4) out={0,x,c}; else if(h<5) out={x,0,c}; else out={c,0,x};
        for(auto& channel:out) channel+=m;
        return out;
    }
};
inline int GridControlAt(float x,float y) {
    if(x>=70 && x<=640 && y>=140 && y<=176) return 100;
    if(x>=70 && x<=640 && y>=202 && y<=442) return 102;
    if(x>=690 && x<=910 && y>=330 && y<=390) return 103;
    if(x>=690 && x<=910 && y>=400 && y<=450) return 111;
    if(x>=70 && x<=640 && y>=470 && y<=538) return 101;
    if(x>=690 && x<=910 && y>=470 && y<=538) return 107;
    if(x>=690 && x<=910 && y>=548 && y<=584) return 108;
    if(x>=70 && x<=440 && y>=548 && y<=584) return 109;
    if(x>=460 && x<=670 && y>=548 && y<=584) return 110;
    return -1;
}
constexpr float kSettingsTabX[3] = {340, 550, 760};
constexpr float kSettingsTabWidth = 194;
inline int HeadsetSettingsControlAt(float x, float y, int tab) {
    if (y >= 36 && y <= 86) {
        for (int i = 0; i < 3; ++i)
            if (x >= kSettingsTabX[i] && x <= kSettingsTabX[i] + kSettingsTabWidth) return 104 + i;
    }
    return tab == 1 ? WristClockControlAt(x, y) : tab == 2 ? PassthroughControlAt(x, y) : GridControlAt(x, y);
}
inline bool PickGridColor(GridColor& color,int control,float x,float y) {
    auto before=color;
    if(control==100) color.hue=std::clamp((x-70)/570,0.0f,1.0f);
    else if(control==102) {
        color.saturation=std::clamp((x-70)/570,0.0f,1.0f);
        color.value=std::clamp(1-(y-202)/240,0.0f,1.0f);
    } else return false;
    return before.hue!=color.hue || before.saturation!=color.saturation || before.value!=color.value;
}

#endif
