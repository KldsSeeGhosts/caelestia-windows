#pragma once

#include "util/export.hpp"

#include "settings/objectnode.hpp"
#include "common.hpp"

namespace caelestia::shell::config {

class CAELESTIA_CONFIG_API SidebarConfig : public settings::ObjectNode {
    CONFIG_NODE(SidebarConfig, settings::ObjectNode)

    CONFIG_PROPERTY(bool, enabled, true)
    CONFIG_PROPERTY(bool, showOnHover, false)
    CONFIG_PROPERTY(int, minHoverThreshold, 200)
    CONFIG_PROPERTY(int, dragThreshold, 80)
};

} // namespace caelestia::shell::config
