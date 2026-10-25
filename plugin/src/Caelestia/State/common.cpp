#include "common.hpp"

#include <qstandardpaths.h>

namespace caelestia::shell::state {

using Qt::StringLiterals::operator""_s;

Q_LOGGING_CATEGORY(lcState, "caelestia.state", QtInfoMsg)

QString stateDir() {
    const auto isolated = qEnvironmentVariable("CAELESTIA_STATE_DIR");
    if (!isolated.isEmpty())
        return isolated;
    return QStandardPaths::writableLocation(QStandardPaths::GenericStateLocation) + u"/caelestia"_s;
}

QString monitorStateDir() {
    return stateDir() + u"/monitors"_s;
}

QString runtimeDir() {
    const auto isolated = qEnvironmentVariable("CAELESTIA_RUNTIME_DIR");
    if (!isolated.isEmpty())
        return isolated;
    return QStandardPaths::writableLocation(QStandardPaths::RuntimeLocation) + u"/caelestia"_s;
}

QString monitorRuntimeDir() {
    return runtimeDir() + u"/monitors"_s;
}

} // namespace caelestia::shell::state
