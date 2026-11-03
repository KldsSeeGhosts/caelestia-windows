#include "windowsfocusguard.hpp"

#include <qloggingcategory.h>
#include <qtimer.h>

namespace caelestia::shell::windows {

Q_LOGGING_CATEGORY(logFocusGuard, "caelestia.windows.focusguard")

WindowsFocusGuard::WindowsFocusGuard(QObject* parent)
    : QObject(parent) {
    sampleExternalForeground();
}

WindowsFocusGuard::~WindowsFocusGuard() {
    // Context-bound single shots are cancelled by QObject destruction.
    // Destruction must never activate another application.
    ++m_generation;
}

WindowsFocusGuard::NativeWindow WindowsFocusGuard::identify(HWND hwnd) {
    NativeWindow identity;
    if (!hwnd || !IsWindow(hwnd) || !IsWindowVisible(hwnd))
        return identity;

    identity.thread = GetWindowThreadProcessId(hwnd, &identity.process);
    if (identity.thread && identity.process)
        identity.hwnd = hwnd;
    return identity;
}

WindowsFocusGuard::NativeWindow WindowsFocusGuard::identify(QQuickWindow* window) {
    // winId() can create a native surface. Only inspect an existing surface.
    if (!window || !window->handle())
        return {};
    return identify(reinterpret_cast<HWND>(window->winId()));
}

bool WindowsFocusGuard::valid(const NativeWindow& window) {
    if (!window.hwnd)
        return false;
    const auto current = identify(window.hwnd);
    return current.hwnd == window.hwnd && current.process == window.process && current.thread == window.thread;
}

bool WindowsFocusGuard::notBefore(DWORD time, DWORD reference) {
    return static_cast<LONG>(time - reference) >= 0;
}

void WindowsFocusGuard::sampleExternalForeground() {
    const auto foreground = identify(GetForegroundWindow());
    if (foreground.hwnd && foreground.process != GetCurrentProcessId())
        m_lastExternal = foreground;
}

void WindowsFocusGuard::setForegroundSource(QObject* source) {
    if (m_foregroundSource == source)
        return;

    disconnect(m_foregroundConnection);
    m_foregroundSource = source;

    if (source) {
        // The backend observer is a QML singleton from another module, so the
        // signal is resolved by name rather than by a link-time type.
        m_foregroundConnection = connect(source,
            SIGNAL(foregroundChanged(qulonglong,uint)),
            this, SLOT(onForegroundChanged(qulonglong,uint)));
        if (!m_foregroundConnection) {
            qCWarning(logFocusGuard)
                << "The foreground source does not provide foregroundChanged(qulonglong,uint).";
        }
    }

    emit foregroundSourceChanged();
}

void WindowsFocusGuard::setTarget(QQuickItem* target) {
    if (m_target == target)
        return;

    disconnect(m_itemWindowConnection);
    disconnect(m_itemDestroyedConnection);
    m_target = target;

    if (target) {
        m_itemWindowConnection = connect(target, &QQuickItem::windowChanged, this,
            [this](QQuickWindow* window) { bindWindow(window); });
        m_itemDestroyedConnection = connect(target, &QObject::destroyed, this, [this]() {
            m_target = nullptr;
            bindWindow(nullptr);
            emit targetChanged();
        });
    }

    bindWindow(target ? target->window() : nullptr);
    emit targetChanged();
}

void WindowsFocusGuard::bindWindow(QQuickWindow* window) {
    // A new target/window starts a new policy generation, even while active.
    // Neither a close timer nor a request for an old native surface may survive.
    ++m_generation;
    disconnect(m_windowDestroyedConnection);
    m_window = window;
    m_savedExternal = {};

    if (window) {
        m_windowDestroyedConnection = connect(window, &QObject::destroyed, this, [this]() {
            ++m_generation;
            m_window = nullptr;
            m_savedExternal = {};
            report(QStringLiteral("target-unavailable"));
        });
    }

    sampleExternalForeground();
    if (m_active && window) {
        m_savedExternal = m_lastExternal;
        m_activatedAt = GetTickCount();
        m_dismissSignaled = false;
        queueActivation(m_generation);
    } else {
        report(window ? QStringLiteral("idle") : QStringLiteral("target-unavailable"));
    }
}

void WindowsFocusGuard::setActive(bool active) {
    if (m_active == active)
        return;

    // Sample before changing state. A backend FocusGrab may already have
    // activated our window; in that case retain the last inactive sample.
    if (active)
        sampleExternalForeground();

    m_active = active;
    const auto generation = ++m_generation;
    if (active) {
        m_activatedAt = GetTickCount();
        m_dismissSignaled = false;
        m_savedExternal = m_lastExternal;
        queueActivation(generation);
    } else {
        queueRestore(generation);
    }
    emit activeChanged();
}

void WindowsFocusGuard::onForegroundChanged(qulonglong hwnd, uint time) {
    // The panel still owns the foreground. This is its own activation or a
    // title change, not a choice made outside it.
    const auto target = identify(m_window.data());
    if (target.hwnd && GetForegroundWindow() == target.hwnd)
        return;

    const auto native = identify(reinterpret_cast<HWND>(static_cast<quintptr>(hwnd)));
    if (native.hwnd && native.process == GetCurrentProcessId())
        return;

    // Track the user's last application even while inactive. The panel can own
    // the foreground by the time the active binding runs, so the sample there
    // would see our own window and the restore target must already be current.
    if (native.hwnd)
        m_lastExternal = native;

    // A queued event from before this activation cannot describe the user's
    // latest choice. Event time is the tick count at which Windows raised it.
    if (!m_active || m_dismissSignaled || !notBefore(time, m_activatedAt))
        return;

    m_dismissSignaled = true;
    report(QStringLiteral("dismiss-external-foreground"));
    emit dismissRequested();
}

void WindowsFocusGuard::queueActivation(quint64 generation) {
    const QPointer<QQuickWindow> window = m_window;
    const auto openingForeground = identify(GetForegroundWindow());

    // Run once after QML/backend focus flags have had an event-loop turn.
    // No surface-created retries: a missing/hidden/no-focus target is a result.
    QTimer::singleShot(0, this, [this, generation, window, openingForeground]() {
        if (generation != m_generation || !m_active || window != m_window)
            return;

        const auto native = identify(window.data());
        if (!native.hwnd) {
            report(QStringLiteral("activation-target-unavailable"));
            return;
        }
        if (GetForegroundWindow() == native.hwnd) {
            report(QStringLiteral("activation-already-foreground"));
            return;
        }

        // Do not override a different app selected after opening was queued.
        // This observes state only, not every intervening foreground change.
        if (GetForegroundWindow() != openingForeground.hwnd || !valid(openingForeground)) {
            report(QStringLiteral("activation-skipped-foreground-changed"));
            return;
        }
        if (window->flags().testFlag(Qt::WindowDoesNotAcceptFocus)
            || (GetWindowLongPtrW(native.hwnd, GWL_EXSTYLE) & WS_EX_NOACTIVATE)) {
            report(QStringLiteral("activation-target-not-focusable"));
            return;
        }

        // One ordinary native request. Windows owns the foreground permission;
        // never use AttachThreadInput, synthetic input or a retry loop.
        const bool accepted = SetForegroundWindow(native.hwnd) != FALSE;
        const bool foreground = GetForegroundWindow() == native.hwnd;
        report(foreground ? QStringLiteral("activation-succeeded")
                          : accepted ? QStringLiteral("activation-requested") : QStringLiteral("activation-denied"),
            !accepted && !foreground);
    });
}

void WindowsFocusGuard::queueRestore(quint64 generation) {
    if (generation != m_generation || m_active)
        return;

    const QPointer<QQuickWindow> window = m_window;
    const auto saved = m_savedExternal;
    m_savedExternal = {};

    // One event-loop turn after the host's state change, so a window that is
    // still closing is observed in its final visibility. No fixed delay and no
    // retry: either the target is foreground here or the user has moved on.
    QTimer::singleShot(0, this, [this, generation, window, saved]() {
        if (generation != m_generation || m_active || window != m_window)
            return;

        const auto target = identify(window.data());
        if (!valid(target)) {
            report(QStringLiteral("restore-skipped-target-changed"));
            return;
        }
        if (GetForegroundWindow() != target.hwnd) {
            // The user already gave the foreground to another window. Leave it.
            report(QStringLiteral("restore-skipped-foreground-changed"));
            return;
        }
        if (!valid(saved) || saved.process == GetCurrentProcessId()) {
            report(QStringLiteral("restore-skipped-no-valid-external"));
            return;
        }

        const bool accepted = SetForegroundWindow(saved.hwnd) != FALSE;
        const bool foreground = GetForegroundWindow() == saved.hwnd;
        report(foreground ? QStringLiteral("restore-succeeded")
                          : accepted ? QStringLiteral("restore-requested") : QStringLiteral("restore-denied"),
            !accepted && !foreground);
    });
}

void WindowsFocusGuard::report(const QString& status, bool denied) {
    if (m_status != status) {
        m_status = status;
        emit statusChanged();
    }
    if (denied)
        qCWarning(logFocusGuard).noquote() << status;
    else
        qCInfo(logFocusGuard).noquote() << status;
    emit outcome(status);
}

} // namespace caelestia::shell::windows
