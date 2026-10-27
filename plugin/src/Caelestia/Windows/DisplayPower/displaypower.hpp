#pragma once

#include <qobject.h>
#include <qqmlintegration.h>
#include <qt_windows.h>
#include <qtimer.h>

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

// One delayed display-power request. The sender is injected so tests can
// verify the exact single-message scheduling without changing real power
// state. The delay lets the triggering key release be processed first, so it
// cannot wake the panels immediately after they switch off.
class DisplayPowerAction : public QObject {
    Q_OBJECT

public:
    using Sender = std::function<bool(HWND)>;

    explicit DisplayPowerAction(
        HWND window, Sender sender = sendMonitorPowerOff, int delayMs = 500, QObject* parent = nullptr);

    [[nodiscard]] HWND window() const { return m_window; }

    [[nodiscard]] int delayMs() const { return m_delayMs; }

    [[nodiscard]] bool pending() const { return m_timer.isActive(); }

    // Queues exactly one send after the delay. Returns false when a request is
    // already pending or the target window is gone.
    bool request();

signals:
    void delivered(bool accepted);

private:
    HWND m_window;
    Sender m_sender;
    int m_delayMs;
    QTimer m_timer;
};

// Explicit, opt-in shell action: IPC target `displays`, function `off`.
class WindowsDisplayPower : public QObject {
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

public:
    explicit WindowsDisplayPower(QObject* parent = nullptr);

    // Queues one panel-off request. Returns false when one is already pending
    // or no shell window is available.
    Q_INVOKABLE bool off();

signals:
    void delivered(bool accepted);

private:
    DisplayPowerAction m_action;
};

} // namespace caelestia::shell::windows
