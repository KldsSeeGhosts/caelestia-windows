#pragma once

#include <windows.h>

#include <iterator>

#include <qobject.h>
#include <qqmlintegration.h>
#include <qstring.h>

namespace caelestia::shell::windows {

// Native process and window queries for the shell-owned Glazier tray host.
// No process enumeration, injection or file access: only the named top-level
// window and the image path of the process that owns it.
class WindowsProcess : public QObject {
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

public:
    using QObject::QObject;

    // Empty when the window or its process image cannot be read.
    Q_INVOKABLE QString windowImagePath(const QString& className) const {
        const auto hwnd = FindWindowW(reinterpret_cast<LPCWSTR>(className.utf16()), nullptr);
        if (hwnd == nullptr)
            return {};

        DWORD pid = 0;
        GetWindowThreadProcessId(hwnd, &pid);
        if (pid == 0)
            return {};

        const auto process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
        if (process == nullptr)
            return {};

        wchar_t path[32768];
        DWORD length = static_cast<DWORD>(std::size(path));
        const auto ok = QueryFullProcessImageNameW(process, 0, path, &length);
        CloseHandle(process);
        return ok ? QString::fromWCharArray(path, static_cast<int>(length)) : QString();
    }

    // 0 when the window does not exist.
    Q_INVOKABLE int windowProcessId(const QString& className) const {
        const auto hwnd = FindWindowW(reinterpret_cast<LPCWSTR>(className.utf16()), nullptr);
        if (hwnd == nullptr)
            return 0;
        DWORD pid = 0;
        GetWindowThreadProcessId(hwnd, &pid);
        return static_cast<int>(pid);
    }

    // Posts WM_CLOSE; the host's own window procedure decides how to exit.
    Q_INVOKABLE bool closeWindow(const QString& className) const {
        const auto hwnd = FindWindowW(reinterpret_cast<LPCWSTR>(className.utf16()), nullptr);
        return hwnd != nullptr && PostMessageW(hwnd, WM_CLOSE, 0, 0) != FALSE;
    }

    // Graceful close with a bounded wait for the owning process to exit.
    // Returns true when no window remains or the process exited in time.
    Q_INVOKABLE bool closeWindowAndWait(const QString& className, int timeoutMs) const {
        const auto hwnd = FindWindowW(reinterpret_cast<LPCWSTR>(className.utf16()), nullptr);
        if (hwnd == nullptr)
            return true;

        DWORD pid = 0;
        GetWindowThreadProcessId(hwnd, &pid);
        if (pid == 0)
            return false;

        const auto process = OpenProcess(SYNCHRONIZE, FALSE, pid);
        if (process == nullptr)
            return FindWindowW(reinterpret_cast<LPCWSTR>(className.utf16()), nullptr) == nullptr;

        PostMessageW(hwnd, WM_CLOSE, 0, 0);
        const auto wait = WaitForSingleObject(process, timeoutMs > 0 ? static_cast<DWORD>(timeoutMs) : 0);
        CloseHandle(process);
        return wait == WAIT_OBJECT_0;
    }
};

} // namespace caelestia::shell::windows
