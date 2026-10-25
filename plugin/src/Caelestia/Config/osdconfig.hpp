#pragma once

#include "util/export.hpp"

#include "settings/objectnode.hpp"
#include "common.hpp"

namespace caelestia::shell::config {

class CAELESTIA_CONFIG_API OsdConfig : public settings::ObjectNode {
    CONFIG_NODE(OsdConfig, settings::ObjectNode)

    CONFIG_PROPERTY(bool, enabled, true)
    CONFIG_PROPERTY(int, hideDelay, 2000)
    CONFIG_PROPERTY(bool, enableBrightness, true)
    CONFIG_PROPERTY(bool, enableMicrophone, false)
};

} // namespace caelestia::shell::config
