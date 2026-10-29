// SPDX-License-Identifier: MIT
#include "NewtXRApp.h"
#include "NewtInternal.h"
#include "InteractionGeometry.h"
#include <algorithm>
#include <cmath>
using namespace NewtInternal;

namespace {
constexpr int kVisibleAlerts = 4;
constexpr float kAlertWidth = 0.46f, kAlertHeight = 0.1f;
constexpr float kSwipeDismiss = 0.15f;
constexpr float kCloseButtonU = 0.86f;
}

void NewtXR::AddAlert(const std::string& title, const std::string& detail, const std::string& key) {
    for (const auto& alert : mAlerts)
        if (!alert.dismissed && alert.key == key) return;
    DashboardAlert alert;
    alert.title = title;
    alert.detail = detail;
    alert.key = key;
    mAlerts.push_back(std::move(alert));
}

void NewtXR::DismissAlert(int index) {
    if (index < 0 || index >= static_cast<int>(mAlerts.size()) || mAlerts[index].dismissed) return;
    auto& alert = mAlerts[index];
    alert.dismissed = true;
    if (alert.key.rfind("env:", 0) == 0 && mMissingScene.environment == alert.key.substr(4)) {
        mMissingScene.environment.clear();
        mMissingScene.environmentMissing = false;
    } else if (alert.key.rfind("model:", 0) == 0) {
        const std::string path = alert.key.substr(6);
        auto& models = mMissingScene.models;
        const auto it = std::find_if(models.begin(), models.end(), [&](const auto& m) { return m.path == path; });
        if (it != models.end()) models.erase(it);
    }
    SaveSceneIfChanged(true);
    for (auto& drag : mAlertDrag) drag = -1;
}

std::vector<int> NewtXR::VisibleAlerts() const {
    std::vector<int> visible;
    for (int i = 0; i < static_cast<int>(mAlerts.size()) && static_cast<int>(visible.size()) < kVisibleAlerts; ++i)
        if (!mAlerts[i].dismissed) visible.push_back(i);
    return visible;
}

XrPosef NewtXR::AlertPose(int slot, float offset) const {
    const float x = 1.0f, z = -1.38f, yaw = std::atan2(-x, -z);
    XrPosef local = IdentityPose();
    local.orientation = {0, std::sin(yaw / 2), 0, std::cos(yaw / 2)};
    const Vec3 along = Rotate(local.orientation, Vec3{offset, 0, 0});
    local.position = {x + along.x, 0.36f - slot * 0.125f, z + along.z};
    return ComposePose(mDashboardPose, local);
}

void NewtXR::UpdateAlerts(Newt::InputState& input) {
    const std::array<bool, 2> raw = input.select;
    const std::vector<int> visible = VisibleAlerts();
    if (visible.empty() || mPassthrough.tracing) {
        mAlertDrag = {-1, -1};
        mAlertPrevSelect = raw;
        return;
    }
    for (int hand = 0; hand < 2; ++hand) {
        if (!input.aimValid[hand]) continue;
        const XrPosef& ray = input.aim[hand];
        const bool pressed = raw[hand] && !mAlertPrevSelect[hand];
        int& drag = mAlertDrag[hand];
        if (drag >= 0 && (drag >= static_cast<int>(mAlerts.size()) || mAlerts[drag].dismissed)) drag = -1;
        if (pressed && drag < 0) {
            for (size_t slot = 0; slot < visible.size(); ++slot) {
                float distance = 0, u = 0;
                if (!RayQuad(ray, AlertPose(static_cast<int>(slot), 0), kAlertWidth, kAlertHeight, distance, u)) continue;
                if (u > kCloseButtonU) {
                    DismissAlert(visible[slot]);
                } else {
                    drag = visible[slot];
                    mAlertDragStart[hand] = (u - 0.5f) * kAlertWidth;
                }
                input.select[hand] = false;
                break;
            }
        }
        if (drag >= 0) {
            const auto slot = std::find(visible.begin(), visible.end(), drag) - visible.begin();
            if (raw[hand]) {
                float distance = 0, u = 0;
                if (RayQuad(ray, AlertPose(static_cast<int>(slot), 0), 6.0f, 2.0f, distance, u))
                    mAlerts[drag].offset = (u - 0.5f) * 6.0f - mAlertDragStart[hand];
            } else {
                if (std::fabs(mAlerts[drag].offset) > kSwipeDismiss) DismissAlert(drag);
                else mAlerts[drag].offset = 0;
                drag = -1;
            }
            input.select[hand] = false;
        }
    }
    mAlertPrevSelect = raw;
}

void NewtXR::PruneAlerts() {
    const bool any = std::any_of(mAlerts.begin(), mAlerts.end(), [](const auto& a) { return a.dismissed; });
    if (!any || mAlertDrag[0] >= 0 || mAlertDrag[1] >= 0) return;
    CheckVk(vkDeviceWaitIdle(mCore->Device()), "dismiss alert");
    for (auto& alert : mAlerts)
        if (alert.dismissed) mCore->DestroyTexture(alert.texture);
    mAlerts.erase(std::remove_if(mAlerts.begin(), mAlerts.end(), [](const auto& a) { return a.dismissed; }),
                  mAlerts.end());
}

void NewtXR::RenderAlerts() {
    for (int index : VisibleAlerts()) {
        auto& alert = mAlerts[index];
        if (alert.rendered) continue;
        if (!alert.texture.initialized) mCore->CreateTexture(alert.texture, 1024, 220);
        mCore->UpdateTexture(alert.texture, RenderAlertCard([NSString stringWithUTF8String:alert.title.c_str()],
                                                            [NSString stringWithUTF8String:alert.detail.c_str()]));
        alert.rendered = true;
    }
}

void NewtXR::DrawAlerts(VkCommandBuffer cmd, const Mat4& viewProj) {
    const std::vector<int> visible = VisibleAlerts();
    for (size_t slot = 0; slot < visible.size(); ++slot) {
        const auto& alert = mAlerts[visible[slot]];
        if (!alert.rendered) continue;
        mCore->DrawTextured(cmd, viewProj, PoseMatrix(AlertPose(static_cast<int>(slot), alert.offset),
                                                      {kAlertWidth, kAlertHeight, 1}), alert.texture);
    }
}
