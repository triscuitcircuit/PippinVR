#ifndef PIPPINVR_PANEL_CONFIG_H
#define PIPPINVR_PANEL_CONFIG_H

#include "Math.h"

#include <string>
#include <vector>

namespace pippinvr {

struct PanelState {
    size_t id;
    glm::vec3 position;
    glm::quat orientation;
};

struct PanelLayout {
    float zoom;
    std::vector<PanelState> panels;
};

class PanelConfig {
   public:
    static bool save(const std::string& filePath, const PanelLayout& layout);
    static bool load(const std::string& filePath, PanelLayout& layout);
};

}  // namespace pippinvr

#endif  // PIPPINVR_PANEL_CONFIG_H
