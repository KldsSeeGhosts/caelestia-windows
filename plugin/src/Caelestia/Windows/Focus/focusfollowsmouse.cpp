#include "focusfollowsmouse.hpp"

#include <algorithm>
#include <qstringlist.h>

namespace caelestia::shell::windows {

FocusFollowsMouseController::FocusFollowsMouseController(FocusFollowsMouseSystem& system)
    : m_system(system) {}

FocusFollowsMouseController::~FocusFollowsMouseController() {
    restore();
}

int FocusFollowsMouseController::clampDelay(int delayMs) {
    return std::clamp(delayMs, MIN_DELAY_MS, MAX_DELAY_MS);
}

bool FocusFollowsMouseController::apply(bool enabled, int delayMs, bool raise, QString* error) {
    if (error)
        error->clear();

    if (!enabled)
        return restore(error);

    if (!m_active) {
        FocusFollowsMouseValues saved;
        if (!m_system.read(saved)) {
            if (error)
                *error = QStringLiteral("Couldn't read the Windows focus-follows-mouse settings.");
            return false;
        }
        m_saved = saved;
        m_current = saved;
        m_active = true;
    }

    FocusFollowsMouseValues target;
    target.tracking = true;
    target.delayMs = clampDelay(delayMs);
    target.raise = raise;

    if (!writeValues(target, error)) {
        // A partially applied setting is worse than none. Put the desktop back
        // the way it was found and report the failure; a later config change
        // retries.
        restore(nullptr);
        if (error && error->isEmpty())
            *error = QStringLiteral("Couldn't apply the Windows focus-follows-mouse settings.");
        return false;
    }

    return true;
}

bool FocusFollowsMouseController::restore(QString* error) {
    if (error)
        error->clear();

    if (!m_active)
        return true;

    if (writeValues(m_saved, error)) {
        m_active = false;
        return true;
    }

    // Keep ownership so the destructor can retry whatever still differs.
    return false;
}

bool FocusFollowsMouseController::writeValues(
    const FocusFollowsMouseValues& values, QString* error) {
    QStringList failures;

    if (values.tracking != m_current.tracking) {
        if (m_system.setTracking(values.tracking))
            m_current.tracking = values.tracking;
        else
            failures.append(QStringLiteral("active window tracking"));
    }

    if (values.delayMs != m_current.delayMs) {
        if (m_system.setDelayMs(values.delayMs))
            m_current.delayMs = values.delayMs;
        else
            failures.append(QStringLiteral("tracking delay"));
    }

    if (values.raise != m_current.raise) {
        if (m_system.setRaise(values.raise))
            m_current.raise = values.raise;
        else
            failures.append(QStringLiteral("raise on focus"));
    }

    if (failures.isEmpty())
        return true;

    if (error)
        *error = QStringLiteral("Couldn't change %1.").arg(failures.join(QStringLiteral(", ")));
    return false;
}

} // namespace caelestia::shell::windows
