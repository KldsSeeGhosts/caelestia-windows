#pragma once

#include <qstring.h>

namespace caelestia::shell::settings {

// Plugin-side counterpart of the backend's logId(). Logs must never carry
// per-monitor names or keys verbatim (AGENTS.md); wrap them here. The salt is
// random per process, so a value can be correlated inside one run but not
// across runs and cannot be reversed without guessing the original.
[[nodiscard]] QString logId(const QString& value);

} // namespace caelestia::shell::settings
