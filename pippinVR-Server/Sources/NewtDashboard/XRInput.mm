#include "NewtXRApp.h"
#include "NewtInternal.h"
#include "include/NewtLog.h"
#include "InteractionGeometry.h"
#include <algorithm>
using namespace NewtInternal;
void NewtXR::OnInput(const Newt::InputState& input) {
    const auto inputNow = std::chrono::steady_clock::now();
    const float inputDt = mLastInput.time_since_epoch().count() ? std::clamp(std::chrono::duration<float>(inputNow-mLastInput).count(), 0.0f, 0.05f) : 0;
    mLastInput = inputNow;
    mAimPoses=input.aim; mGripPoses=input.grip;
    mAimValid=input.aimValid; mGripValid=input.gripValid;
    if(input.viewerValid) {
        mViewerPose=input.viewer;
        if(mRecenterMenu) {
            const auto forward=Rotate(input.viewer.orientation,{0,0,-1});
            const float yaw=std::atan2(-forward.x,-forward.z);
            mDashboardPose=IdentityPose();
            mDashboardPose.orientation={0,std::sin(yaw/2),0,std::cos(yaw/2)};
            mDashboardPose.position=input.viewer.position;
            mRecenterMenu=false;
        }
    }
    const double rayTime = std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count();
    for (int hand = 0; hand < 2; ++hand) {
        const auto& grab=input.grab[hand];
        const auto& stick=input.stick[hand];
        const bool interacting = input.select[hand] || input.menu[hand] ||
            (grab.isActive && grab.currentState > 0.7f) ||
            (stick.isActive && (std::fabs(stick.currentState.x) > 0.2f || std::fabs(stick.currentState.y) > 0.2f));
        const auto& pose = mAimPoses[hand];
        mRayActivity[hand].Update(rayTime, mAimValid[hand],
            {pose.position.x, pose.position.y, pose.position.z},
            {pose.orientation.x, pose.orientation.y, pose.orientation.z, pose.orientation.w}, interacting);
        mRayAlpha[hand] = mRayActivity[hand].Alpha(rayTime);
    }

    int hoveredRow[2]{ -1, -1 };
    if (mMenuOpen) {
        bool anyCursor = false;
        for (int i = 0; i < 2; ++i) {
            if (!mAimValid[i] || mRayAlpha[i] <= 0) { mPrevHover[i] = -1; continue; }
            Vec3 hit{ 0, 0, -999.0f };
            const int index = MenuHit(mAimPoses[i], hit);
            hoveredRow[i] = index;
            if (hit.z > -900.0f) {
                mCursor = hit;
                mCursorAlpha = mRayAlpha[i];
                anyCursor = true;
            }
            if (index >= 0 && index < 9 && index != mPrevHover[i]) {
                mSelected = index;
            }
            mPrevHover[i] = index;
        }
        mCursorValid = anyCursor;
    } else {
        mCursorValid = false;
    }



    for (int i = 0; i < 2; ++i) {
        const bool sel = input.select[i];
        if(sel && mMenuOpen && mPage==Page::Settings && (hoveredRow[i]==100 || hoveredRow[i]==102)) {
            Vec3 hit; MenuHit(mAimPoses[i],hit);
            const auto local=Rotate(Conjugate(mDashboardPose.orientation),hit-Vec3{mDashboardPose.position.x,mDashboardPose.position.y,mDashboardPose.position.z});
            float x=(0.5f+(local.x-mContentCenter.x)/mContentWidth)*1024;
            float y=(0.5f-(local.y-mContentCenter.y)/mContentHeight)*640;
            if(PickGridColor(mGridColor,hoveredRow[i],x,y)) mContentDirty=true;
        }
        if (sel && !mPrevSelect[i]) {
            if (!mMenuOpen) {
                if (mGrabHand>=0) { mPrevSelect[i]=sel; continue; }
                if (mPage == Page::Screens) {
                    if (!mPanels.empty()) mActivePanel = (mActivePanel + 1) % mPanels.size();
                } else if (mPage == Page::Media) {
                    if (!mPanels.empty()) mActivePanel = (mActivePanel + 1) % mPanels.size();
                } else {
                    mMenuOpen = true;
                }
                Newt_Logf(NEWT_LOG_DEBUG, "Select pressed (hand %d, menu closed)", i);
            } else {
                const int target = hoveredRow[i] >= 0 ? hoveredRow[i] : mSelected;
                SelectItem(target);
            }
        }
        mPrevSelect[i] = sel;

        const bool menu = input.menu[i];
        if (menu && !mPrevMenu[i]) {
            mMenuOpen = !mMenuOpen;
            if (mMenuOpen) { mRecenterMenu = true; mGrabHand = -1; mGrabbedPanel = -1; }
            Newt_Logf(NEWT_LOG_DEBUG, "Menu pressed (hand %d) -> menuOpen=%d", i, static_cast<int>(mMenuOpen));
        }
        mPrevMenu[i] = menu;
    }

    // Two-handed stretch resize: both grips held together resizes width and
    // height independently, by how the hands' current separation compares
    // to their separation when the stretch started. Computed before the
    // single-hand grab loop below so a just-starting two-hand squeeze is
    // never claimed by hand 0 alone as an ordinary single-hand grab first.
    const bool bothHeld = !mMenuOpen && !mPanels.empty() &&
        input.grab[0].isActive && input.grab[0].currentState > 0.7f && mGripValid[0] &&
        input.grab[1].isActive && input.grab[1].currentState > 0.7f && mGripValid[1];
    auto localGripOf = [&](const Panel& panel, const XrPosef& p) {
        const auto inverse = Conjugate(panel.pose.orientation);
        return Rotate(inverse, {p.position.x-panel.pose.position.x,
            p.position.y-panel.pose.position.y, p.position.z-panel.pose.position.z});
    };
    if (!mStretchActive && bothHeld) {
        // Hands rarely cross the grip threshold on the exact same frame, so
        // whichever hand got there first may have already claimed a
        // single-hand grab (any panel-body hit does, not just its bar) by
        // the time the second hand catches up. Two-hand intent wins: once
        // both are confirmed held, force-release that claim rather than
        // require it to have never happened.
        mGrabHand = -1; mGrabbedPanel = -1;
        Panel& panel = *mPanels[mActivePanel];
        const Vec3 l0 = localGripOf(panel, mGripPoses[0]), l1 = localGripOf(panel, mGripPoses[1]);
        mStretchActive = true; mStretchPanel = mActivePanel;
        mStretchStartWidth = panel.width; mStretchStartHeight = panel.height;
        mStretchStartDeltaX = std::max(0.05f, std::abs(l1.x - l0.x));
        mStretchStartDeltaY = std::max(0.05f, std::abs(l1.y - l0.y));
        mCore->PulseHaptic(0, 0.5f); mCore->PulseHaptic(1, 0.5f);
    }
    if (mStretchActive) {
        if (!bothHeld || mStretchPanel < 0 || mStretchPanel >= static_cast<int>(mPanels.size())) {
            mStretchActive = false;
        } else {
            Panel& panel = *mPanels[mStretchPanel];
            const Vec3 l0 = localGripOf(panel, mGripPoses[0]), l1 = localGripOf(panel, mGripPoses[1]);
            const float dx = std::abs(l1.x - l0.x), dy = std::abs(l1.y - l0.y);
            panel.width = std::clamp(mStretchStartWidth * (dx / mStretchStartDeltaX), 0.4f, 4.0f);
            panel.height = std::clamp(mStretchStartHeight * (dy / mStretchStartDeltaY), 0.25f, 3.0f);
        }
    }

    // Squeeze and move/rotate the selected panel, preserving its initial controller offset.
    for (int hand = 0; hand < 2; ++hand) {
        const auto& state=input.grab[hand];
        const bool held = !mMenuOpen && state.isActive && state.currentState > 0.7f && mGripValid[hand];
        if (held && !mGrabbing[hand] && !mPanels.empty() && mGrabHand < 0 && !bothHeld) {
            int picked = -1; float distance = 0;
            const int zone = mAimValid[hand] ? PanelHit(mAimPoses[hand], picked, distance) : -1;
            if (picked < 0) { mGrabbing[hand] = held; continue; }
            mActivePanel = picked;
            mCore->PulseHaptic(hand, 0.5f); // Confirms the squeeze actually caught a panel.
            if (zone == 2) {
                auto& pose = mPanels[picked]->pose;
                const float yaw = std::atan2(mViewerPose.position.x-pose.position.x, mViewerPose.position.z-pose.position.z);
                pose.orientation = {0,std::sin(yaw/2),0,std::cos(yaw/2)};
                mGrabbing[hand] = held; continue;
            }
            mGrabZone = zone;
            mGrabHand = hand;
            mGrabbedPanel = picked;
            const auto& pose = mPanels[mGrabbedPanel]->pose;
            const auto& grip = mGripPoses[hand];
            const Vec3 offset = Rotate(Conjugate(grip.orientation),
                Vec3{pose.position.x - grip.position.x, pose.position.y - grip.position.y, pose.position.z - grip.position.z});
            mGrabOffsets[hand].position = {offset.x, offset.y, offset.z};
            mGrabOffsets[hand].orientation = QuaternionProduct(Conjugate(grip.orientation), pose.orientation);
        }
        if (held && mGrabHand == hand && mGrabbedPanel >= 0) {
            auto& pose = mPanels[mGrabbedPanel]->pose;
            const auto& grip = mGripPoses[hand];
            auto& offset = mGrabOffsets[hand];
            if (mGrabZone == 1) {
                const auto& stick=input.stick[hand];
                if (stick.isActive && input.select[hand]) {
                    auto& panel=*mPanels[mGrabbedPanel];
                    if(std::abs(stick.currentState.x)>0.2f) {
                        const float raw=panel.curvature+stick.currentState.x*inputDt;
                        panel.curvature=std::clamp(raw,0.0f,2.4f);
                        if (panel.curvature!=raw) mCore->PulseHaptic(hand);
                    }
                    mGrabbing[hand]=held;
                    continue; // Curvature gesture keeps the screen stationary.
                }
                if (stick.isActive) {
                    if (std::abs(stick.currentState.x)>0.2f) {
                        const float angle=-stick.currentState.x*inputDt;
                        const XrQuaternionf yaw{0,std::sin(angle/2),0,std::cos(angle/2)};
                        offset.orientation=QuaternionProduct(Conjugate(grip.orientation),
                            QuaternionProduct(yaw,QuaternionProduct(grip.orientation,offset.orientation)));
                    }
                    if (std::abs(stick.currentState.y)>0.2f) {
                        const float length=std::sqrt(offset.position.x*offset.position.x+offset.position.y*offset.position.y+offset.position.z*offset.position.z);
                        if (length>0.001f) {
                            const float raw=length+stick.currentState.y*inputDt;
                            const float clamped=std::clamp(raw,0.35f,16.0f);
                            if (clamped!=raw) mCore->PulseHaptic(hand);
                            const float scale=clamped/length;
                            offset.position.x*=scale;offset.position.y*=scale;offset.position.z*=scale;
                        }
                    }
                }
            }
            const Vec3 delta = Rotate(grip.orientation, {offset.position.x, offset.position.y, offset.position.z});
            if (mGrabZone == 0 || mGrabZone == 3) {
                const float angle = (mGrabZone == 0 ? 1.0f : -1.0f)*inputDt;
                pose.orientation = QuaternionProduct({0,std::sin(angle/2),0,std::cos(angle/2)},pose.orientation);
            } else {
                pose.position = {grip.position.x + delta.x, grip.position.y + delta.y, grip.position.z + delta.z};
                pose.orientation = QuaternionProduct(grip.orientation, offset.orientation);
            }
        }
        if (!held && mGrabHand == hand) { mGrabHand = -1; mGrabbedPanel = -1; }
        mGrabbing[hand] = held;
    }

    if (!mMenuOpen && !mPanels.empty() && mGrabHand < 0 && !mStretchActive) {
        Panel& panel = *mPanels[mActivePanel];
        const auto now = std::chrono::steady_clock::now();
        const float dt = mLastAdjust.time_since_epoch().count() == 0 ? 0.0f :
            std::min(0.05f, std::chrono::duration<float>(now - mLastAdjust).count());
        mLastAdjust = now;
        for (int hand = 0; hand < 2; ++hand) {
            const auto& stick=input.stick[hand];
            if (!stick.isActive) continue;
            const float x = std::fabs(stick.currentState.x) > 0.2f ? stick.currentState.x : 0;
            const float y = std::fabs(stick.currentState.y) > 0.2f ? stick.currentState.y : 0;
            if (hand == 0) {
                panel.pose.position.x += x * dt;
                const float rawY = panel.pose.position.y + y * dt;
                panel.pose.position.y = std::clamp(rawY, 0.3f, 4.0f);
                if (panel.pose.position.y != rawY) mCore->PulseHaptic(hand);
            } else {
                const float rawWidth = panel.width + x * dt;
                const float newWidth = std::clamp(rawWidth, 0.4f, 4.0f);
                // Uniform scale, preserving whatever aspect the panel
                // currently has -- independent width/height is the two-
                // handed stretch gesture's job, not this one's.
                if (panel.width > 0.0001f) panel.height *= newWidth / panel.width;
                panel.width = newWidth;
                const float rawZ = panel.pose.position.z - y * dt;
                panel.pose.position.z = std::clamp(rawZ, -16.0f, -0.6f);
                if (panel.width != rawWidth || panel.pose.position.z != rawZ) mCore->PulseHaptic(hand);
            }
        }
    } else { mLastAdjust = {}; }

    // Thumbstick up/down/left/right moves the menu selection (debounced).
    const auto now = std::chrono::steady_clock::now();
    if (mMenuOpen && now - mLastNav > std::chrono::milliseconds(250)) {
        for (int i = 0; i < 2; ++i) {
            const auto& st=input.stick[i];
            if (st.isActive == XR_FALSE) continue;
            if (st.currentState.y > 0.5f || st.currentState.x < -0.5f) {
                mSelected = (mSelected + kMenuItems.size() - 1) % kMenuItems.size();
                mLastNav = now;
                Newt_Logf(NEWT_LOG_DEBUG, "Thumbstick nav (hand %d) -> item %d", i, mSelected);
                break;
            }
            if (st.currentState.y < -0.5f || st.currentState.x > 0.5f) {
                mSelected = (mSelected + 1) % kMenuItems.size();
                mLastNav = now;
                Newt_Logf(NEWT_LOG_DEBUG, "Thumbstick nav (hand %d) -> item %d", i, mSelected);
                break;
            }
        }
    }
}
