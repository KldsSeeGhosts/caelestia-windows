#pragma once

#include <qobject.h>
#include <qqmlintegration.h>
#include <qt_windows.h>

#include <functional>
#include <utility>

namespace caelestia::shell::windows {

// The shell's own hidden top-level window, created on first use. Its window
// procedure forwards to DefWindowProc, which handles SC_MONITORPOWER. The
// command is deliberately never broadcast to other applications.
[[nodiscard]] HWND displayPowerWindow();

// Sends WM_SYSCOMMAND / SC_MONITORPOWER = 2 to a window owned by this process.
// A true result means the message was delivered to the shell's window
// procedure, not that the panels have been observed to go dark. Foreign or
// invalid windows are refused.
[[nodiscard]] bool sendMonitorPowerOff(HWND window);

// One panel-off send. The sender is injected so tests can verify the exact
// single-message behavior without changing real power state. Waiting for the
// triggering chord is a separate input concern: the shell asks the keyboard
// hook for its release and calls this only when the request may be sent.
class DisplayPowerAction {
public:
    using Sender = std::function<bool(HWND)>;

    explicit DisplayPowerAction(HWND window, Sender sender = sendMonitorPowerOff);

    [[nodiscard]] HWND window() const { return m_window; }

    // Sends exactly one command. Returns false when the target window is gone.
    bool send();

private:
    HWND m_window;
    Sender m_sender;
};

// Explicit, opt-in shell action: IPC target `displays`, function `off`.
class WindowsDisplayPower : public QObject {
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

public:
    explicit WindowsDisplayPower(QObject* parent = nullptr);

    // Sends one panel-off request now. The caller has already established
    // that the triggering chord is released, or that this is a direct request.
    Q_INVOKABLE bool off();

signals:
    void delivered(bool accepted);

private:
    DisplayPowerAction m_action;
};

} // namespace caelestia::shell::windows
