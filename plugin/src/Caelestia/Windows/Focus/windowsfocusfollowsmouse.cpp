#include "windowsfocusfollowsmouse.hpp"

#include <qcoreapplication.h>
#include <qdir.h>
#include <qloggingcategory.h>
#include <qt_windows.h>

namespace caelestia::shell::windows {

namespace {

Q_LOGGING_CATEGORY(logFocusFollowsMouse, "caelestia.windows.focusfollowsmouse")

} // namespace

bool SystemParametersFocusFollowsMouse::read(FocusFollowsMouseValues& values) {
    BOOL tracking = FALSE;
    if (SystemParametersInfoW(SPI_GETACTIVEWINDOWTRACKING, 0, &tracking, 0) == 0)
        return false;

    DWORD delay = 0;
    if (SystemParametersInfoW(SPI_GETACTIVEWNDTRKTIMEOUT, 0, &delay, 0) == 0)
        return false;

    BOOL raise = FALSE;
    if (SystemParametersInfoW(SPI_GETACTIVEWNDTRKZORDER, 0, &raise, 0) == 0)
        return false;

    values.tracking = tracking != FALSE;
    values.delayMs = static_cast<int>(delay);
    values.raise = raise != FALSE;
    return true;
}

bool SystemParametersFocusFollowsMouse::setTracking(bool tracking) {
    // No SPIF_UPDATEINIFILE: the registry value keeps the user's stored
    // preference, so a crash or forced kill cannot make this permanent.
    return SystemParametersInfoW(SPI_SETACTIVEWINDOWTRACKING, 0,
               reinterpret_cast<PVOID>(static_cast<UINT_PTR>(tracking ? TRUE : FALSE)), 0)
        != 0;
}

bool SystemParametersFocusFollowsMouse::setDelayMs(int delayMs) {
    return SystemParametersInfoW(SPI_SETACTIVEWNDTRKTIMEOUT, 0,
               reinterpret_cast<PVOID>(static_cast<UINT_PTR>(delayMs)), 0)
        != 0;
}

bool SystemParametersFocusFollowsMouse::setRaise(bool raise) {
    return SystemParametersInfoW(SPI_SETACTIVEWNDTRKZORDER, 0,
               reinterpret_cast<PVOID>(static_cast<UINT_PTR>(raise ? TRUE : FALSE)), 0)
        != 0;
}

WindowsFocusFollowsMouse::WindowsFocusFollowsMouse(QObject* parent): QObject(parent) {
    // QML teardown destroys this object, but restore at the explicit clean-exit
    // signal as well so a quit path that defers engine deletion still returns
    // the Windows values.
    if (auto* app = QCoreApplication::instance()) {
        connect(app, &QCoreApplication::aboutToQuit, this, [this] { restore(); });
    }
}

WindowsFocusFollowsMouse::~WindowsFocusFollowsMouse() = default;

bool WindowsFocusFollowsMouse::apply(bool enabled, int delayMs, bool raise) {
    // The profile runtime directory is provided by the QML facade. The
    // baseline is persisted there before the first SET write so a supervisor
    // restart after a crash knows what to restore.
    m_controller.setRecoveryPath(m_recoveryDirectory.isEmpty()
            ? QString()
            : QDir(m_recoveryDirectory)
                  .filePath(QStringLiteral("focus-follows-mouse-recovery.json")));

    QString error;
    const bool ok = m_controller.apply(enabled, delayMs, raise, &error);

    if (ok) {
        setState(enabled ? QStringLiteral("applied") : QStringLiteral("disabled"), {});
        if (enabled) {
            qCInfo(logFocusFollowsMouse)
                << "applied"
                << "delayMs=" << FocusFollowsMouseController::clampDelay(delayMs)
                << "raise=" << raise;
        } else {
            qCInfo(logFocusFollowsMouse) << "restored the previous Windows values";
        }
    } else {
        setState(QStringLiteral("error"), error);
        qCWarning(logFocusFollowsMouse) << error;
    }

    return ok;
}

void WindowsFocusFollowsMouse::restore() {
    QString error;
    if (m_controller.restore(&error)) {
        if (m_status != QStringLiteral("idle"))
            setState(QStringLiteral("disabled"), {});
        return;
    }

    setState(QStringLiteral("error"), error);
    qCWarning(logFocusFollowsMouse) << error;
}

void WindowsFocusFollowsMouse::setState(const QString& status, const QString& error) {
    if (m_status == status && m_lastError == error)
        return;

    m_status = status;
    m_lastError = error;
    emit stateChanged();
}

} // namespace caelestia::shell::windows
