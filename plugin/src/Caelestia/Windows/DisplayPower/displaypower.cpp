#include "displaypower.hpp"

#include <qloggingcategory.h>

namespace caelestia::shell::windows {

Q_LOGGING_CATEGORY(logDisplayPower, "caelestia.windows.displaypower")

namespace {

constexpr wchar_t WINDOW_CLASS[] = L"CaelestiaDisplayPowerWindow";
constexpr int DEFAULT_DELAY_MS = 500;

LRESULT CALLBACK displayPowerWindowProc(HWND window, UINT message, WPARAM wParam, LPARAM lParam) {
    return DefWindowProcW(window, message, wParam, lParam);
}

HWND createDisplayPowerWindow() {
    const HINSTANCE instance = GetModuleHandleW(nullptr);
    WNDCLASSEXW windowClass{};
    windowClass.cbSize = sizeof(windowClass);
    windowClass.lpfnWndProc = displayPowerWindowProc;
    windowClass.hInstance = instance;
    windowClass.lpszClassName = WINDOW_CLASS;

    if (!RegisterClassExW(&windowClass) && GetLastError() != ERROR_CLASS_ALREADY_EXISTS) {
        qCWarning(logDisplayPower) << "Could not register the display power window class:" << GetLastError();
        return nullptr;
    }

    const HWND window = CreateWindowExW(
        0, WINDOW_CLASS, L"Caelestia display power", WS_POPUP, 0, 0, 0, 0, nullptr, nullptr, instance, nullptr);
    if (!window)
        qCWarning(logDisplayPower) << "Could not create the display power window:" << GetLastError();
    return window;
}

} // namespace

HWND displayPowerWindow() {
    static const HWND window = createDisplayPowerWindow();
    return window;
}

bool sendMonitorPowerOff(HWND window) {
    if (!window || !IsWindow(window)) {
        qCWarning(logDisplayPower) << "Refusing display power request without a valid window";
        return false;
    }

    DWORD process = 0;
    if (!GetWindowThreadProcessId(window, &process) || process != GetCurrentProcessId()) {
        qCWarning(logDisplayPower) << "Refusing display power request for a window outside this process";
        return false;
    }

    // lParam 2 switches the panels off. DefWindowProc owns the request; this
    // process never sends the command to HWND_BROADCAST, which could disturb
    // unrelated applications' message handling.
    qCDebug(logDisplayPower) << "Sending SC_MONITORPOWER=2";
    SendMessageW(window, WM_SYSCOMMAND, SC_MONITORPOWER, 2);
    return true;
}

DisplayPowerAction::DisplayPowerAction(HWND window, Sender sender, int delayMs, QObject* parent)
    : QObject(parent)
    , m_window(window)
    , m_sender(std::move(sender))
    , m_delayMs(delayMs) {
    m_timer.setSingleShot(true);
    connect(&m_timer, &QTimer::timeout, this, [this]() {
        const bool accepted = m_sender ? m_sender(m_window) : false;
        emit delivered(accepted);
    });
}

bool DisplayPowerAction::request() {
    if (m_timer.isActive())
        return false;
    if (!m_window || !IsWindow(m_window))
        return false;

    m_timer.start(m_delayMs);
    return true;
}

WindowsDisplayPower::WindowsDisplayPower(QObject* parent)
    : QObject(parent)
    , m_action(displayPowerWindow(), sendMonitorPowerOff, DEFAULT_DELAY_MS) {
    connect(&m_action, &DisplayPowerAction::delivered, this, &WindowsDisplayPower::delivered);
}

bool WindowsDisplayPower::off() {
    return m_action.request();
}

} // namespace caelestia::shell::windows
