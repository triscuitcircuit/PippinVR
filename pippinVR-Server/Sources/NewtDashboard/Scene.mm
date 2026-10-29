// SPDX-License-Identifier: MIT




#include "NewtXRApp.h"
#include "NewtInternal.h"
#include "Environment.h"
#include "include/NewtLog.h"
using namespace NewtInternal;

void NewtXR::RestoreScene() {
    mSceneRestored = true;
    mMissingScene = SavedScene{};
    SavedScene saved;
    if (!LoadSavedScene(saved)) return;
    mContentHome = {saved.homeX, saved.homeZ, saved.homeYaw};
    if (!saved.environment.empty()) {
        if (SceneFileReadable(saved.environment) && LoadEnvironmentImage(saved.environment)) {
            if (saved.flipV) { FlipImageVertical(mEnvironmentImage); mEnvironmentFlipV = true; }
            if (saved.flipH) { FlipImageHorizontal(mEnvironmentImage); mEnvironmentFlipH = true; }
            if (saved.flipV || saved.flipH) mCore->UpdateTexture(mEnvironmentTexture, mEnvironmentImage);
        } else {
            const bool exists = SceneFileReadable(saved.environment);
            mMissingScene.environment = saved.environment;
            mMissingScene.flipV = saved.flipV;
            mMissingScene.flipH = saved.flipH;
            mMissingScene.environmentMissing = true;
            AddAlert(exists ? "Environment image couldn't be opened" : "Environment image not found",
                     SceneFileName(saved.environment) + " · dismiss to forget it", "env:" + saved.environment);
        }
    }
    for (const auto& model : saved.models) {
        ModelInstance* instance = SceneFileReadable(model.path) ? AddModelFromFile(model.path) : nullptr;
        if (instance) {
            instance->pose = model.pose;
            instance->scale = model.scale;
            instance->yaw = model.yaw;
            instance->inFront = model.inFront;
            continue;
        }
        SavedSceneModel missing = model;
        missing.missing = true;
        mMissingScene.models.push_back(missing);
        AddAlert(SceneFileReadable(model.path) ? "3D model couldn't be opened" : "3D model not found",
                 SceneFileName(model.path) + " · dismiss to forget it", "model:" + model.path);
    }
    Newt_Logf(NEWT_LOG_INFO, "Scene restored: %zu 3D model(s), environment %s, %zu missing item(s)", mModels.size(),
              mHasEnvironment ? "set" : "none",
              mMissingScene.models.size() + (mMissingScene.environment.empty() ? 0 : 1));
    mLastSceneText = SerializeScene(CurrentScene());
}

SavedScene NewtXR::CurrentScene() const {
    SavedScene scene;
    if (mHasEnvironment && !mEnvironmentPath.empty()) {
        scene.environment = mEnvironmentPath;
        scene.flipV = mEnvironmentFlipV;
        scene.flipH = mEnvironmentFlipH;
    } else if (!mMissingScene.environment.empty()) {
        scene.environment = mMissingScene.environment;
        scene.flipV = mMissingScene.flipV;
        scene.flipH = mMissingScene.flipH;
        scene.environmentMissing = true;
    }
    for (const auto& model : mModels) {
        if (model->path.empty()) continue;
        SavedSceneModel saved;
        saved.path = model->path;
        saved.pose = model->pose;
        saved.scale = model->scale;
        saved.yaw = model->yaw;
        saved.inFront = model->inFront;
        scene.models.push_back(saved);
    }
    scene.models.insert(scene.models.end(), mMissingScene.models.begin(), mMissingScene.models.end());
    scene.homeX = mContentHome[0];
    scene.homeZ = mContentHome[1];
    scene.homeYaw = mContentHome[2];
    return scene;
}



void NewtXR::SaveSceneIfChanged(bool force) {
    if (!mSceneRestored) return;
    const auto now = std::chrono::steady_clock::now();
    if (!force && now - mLastSceneCheck < std::chrono::seconds(1)) return;
    mLastSceneCheck = now;
    const std::string text = SerializeScene(CurrentScene());
    if (text.empty() || text == mLastSceneText) return;
    if (WriteSceneText(text)) mLastSceneText = text;
}
