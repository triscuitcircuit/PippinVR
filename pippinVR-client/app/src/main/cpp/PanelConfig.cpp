#include "PanelConfig.h"

#include "Log.h"

#include <fstream>
#include <yaml-cpp/yaml.h>

namespace pippinvr {

bool PanelConfig::save(const std::string& filePath, const PanelLayout& layout) {
    try {
        YAML::Node root;
        root["zoom"] = layout.zoom;

        for (const auto& panel : layout.panels) {
            YAML::Node panelNode;
            panelNode["id"] = static_cast<int>(panel.id);

            panelNode["position"] = YAML::Node(YAML::NodeType::Sequence);
            panelNode["position"].push_back(panel.position.x);
            panelNode["position"].push_back(panel.position.y);
            panelNode["position"].push_back(panel.position.z);

            panelNode["orientation"] = YAML::Node(YAML::NodeType::Sequence);
            panelNode["orientation"].push_back(panel.orientation.x);
            panelNode["orientation"].push_back(panel.orientation.y);
            panelNode["orientation"].push_back(panel.orientation.z);
            panelNode["orientation"].push_back(panel.orientation.w);

            root["panels"].push_back(panelNode);
        }

        std::ofstream file(filePath);
        if (!file.is_open()) {
            LOGW("Failed to open %s for writing", filePath.c_str());
            return false;
        }

        file << root;
        file.close();

        LOGI("Saved panel layout: zoom=%.1f, %zu panels to %s", layout.zoom, layout.panels.size(),
             filePath.c_str());
        return true;

    } catch (const YAML::Exception& e) {
        LOGE("YAML error while saving: %s", e.what());
        return false;
    } catch (const std::exception& e) {
        LOGE("Error saving panel layout: %s", e.what());
        return false;
    }
}

bool PanelConfig::load(const std::string& filePath, PanelLayout& layout) {
    try {
        std::ifstream file(filePath);
        if (!file.is_open()) {
            LOGI("No saved panel layout found at %s", filePath.c_str());
            return false;
        }

        YAML::Node root = YAML::Load(file);
        file.close();

        if (root["zoom"]) {
            layout.zoom = root["zoom"].as<float>();
        } else {
            layout.zoom = 1.0f;
        }

        layout.panels.clear();

        if (root["panels"] && root["panels"].IsSequence()) {
            for (const auto& panelNode : root["panels"]) {
                PanelState state;
                state.id = panelNode["id"].as<size_t>();

                if (panelNode["position"] && panelNode["position"].size() == 3) {
                    state.position.x = panelNode["position"][0].as<float>();
                    state.position.y = panelNode["position"][1].as<float>();
                    state.position.z = panelNode["position"][2].as<float>();
                } else {
                    state.position = glm::vec3(0.0f, 0.0f, -2.0f);
                }

                if (panelNode["orientation"] && panelNode["orientation"].size() == 4) {
                    float qx = panelNode["orientation"][0].as<float>();
                    float qy = panelNode["orientation"][1].as<float>();
                    float qz = panelNode["orientation"][2].as<float>();
                    float qw = panelNode["orientation"][3].as<float>();
                    state.orientation = glm::quat(qw, qx, qy, qz);
                } else {
                    state.orientation = glm::quat(1.0f, 0.0f, 0.0f, 0.0f);
                }

                layout.panels.push_back(state);
            }

            LOGI("Loaded layout: zoom=%.1f, %zu panels from %s", layout.zoom, layout.panels.size(),
                 filePath.c_str());
            return true;
        }

        LOGW("No panels array found in layout file");
        return false;

    } catch (const YAML::Exception& e) {
        LOGE("YAML error while loading: %s", e.what());
        return false;
    } catch (const std::exception& e) {
        LOGE("Error loading panel layout: %s", e.what());
        return false;
    }
}

}  // namespace pippinvr
