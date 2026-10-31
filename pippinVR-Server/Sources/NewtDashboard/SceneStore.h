#pragma once
// SPDX-License-Identifier: MIT




#include "Newt/MathTypes.h"
#include <string>
#include <vector>

struct SavedSceneModel {
    std::string path;
    XrPosef pose = IdentityPose();
    float scale = 1.0f;
    float yaw = 0.0f;
    bool inFront = true;
    bool missing = false;
};

struct SavedScene {
    std::string environment;
    bool flipV = false, flipH = false;
    bool environmentMissing = false;
    std::vector<SavedSceneModel> models;


    float homeX = 0, homeZ = 0, homeYaw = 0;
};


bool LoadSavedScene(SavedScene& scene);
std::string SerializeScene(const SavedScene& scene);
bool WriteSceneText(const std::string& text);
bool SceneFileReadable(const std::string& path);
std::string SceneFileName(const std::string& path);
