// Owned hidden-window fixture only. No capture, input, tray, foreground or
// installed-host names. The per-test class is supplied by its parent.
#include <windows.h>
#include <shellapi.h>
#include <qjsondocument.h>
#include <qjsonobject.h>
#include <qstringlist.h>

namespace {
int closeDelay = 0;
LRESULT CALLBACK procedure(HWND window, UINT message, WPARAM w, LPARAM l) {
    if (message == WM_CLOSE) {
        SetTimer(window, 1, UINT(closeDelay > 0 ? closeDelay : 1), nullptr);
        return 0;
    }
    if (message == WM_TIMER) {
        DestroyWindow(window);
        return 0;
    }
    if (message == WM_DESTROY) {
        PostQuitMessage(0);
        return 0;
    }
    return DefWindowProcW(window, message, w, l);
}
}

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE, PWSTR, int) {
    const auto name = qEnvironmentVariable("CAELESTIA_CAPTURE_FIXTURE_CLASS");
    if (!name.startsWith(QStringLiteral("CaelestiaCaptureFixture.")))
        return 2; // Never find/create a production host.
    int count = 0;
    auto** argv = CommandLineToArgvW(GetCommandLineW(), &count);
    QStringList args;
    for (int i = 1; i < count; ++i)
        args.append(QString::fromWCharArray(argv[i]));
    LocalFree(argv);
    if (args.contains(QStringLiteral("--status"))) {
        const auto window = FindWindowW(reinterpret_cast<LPCWSTR>(name.utf16()), nullptr);
        DWORD pid = 0;
        if (window)
            GetWindowThreadProcessId(window, &pid);
        QJsonObject status{{QStringLiteral("version"), 1}, {QStringLiteral("ok"), pid != 0}};
        if (pid) {
            status.insert(QStringLiteral("host_id"), QString::number(pid) + QStringLiteral("-fixture"));
            status.insert(QStringLiteral("state"), QStringLiteral("idle"));
        }
        const auto body = QJsonDocument(status).toJson(QJsonDocument::Compact) + '\n';
        DWORD written = 0;
        WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), body.constData(), DWORD(body.size()), &written, nullptr);
        return pid ? 0 : 1;
    }
    if (FindWindowW(reinterpret_cast<LPCWSTR>(name.utf16()), nullptr))
        return 0; // A forwarded client is not a host.
    closeDelay = qEnvironmentVariableIntValue("CAELESTIA_CAPTURE_FIXTURE_CLOSE_DELAY");
    WNDCLASSW wc{};
    wc.hInstance = instance;
    wc.lpszClassName = reinterpret_cast<LPCWSTR>(name.utf16());
    wc.lpfnWndProc = procedure;
    if (!RegisterClassW(&wc))
        return 3;
    const auto window = CreateWindowW(wc.lpszClassName, L"", WS_OVERLAPPED,
        0, 0, 0, 0, nullptr, nullptr, instance, nullptr);
    if (!window)
        return 4;
    // Deliberately no ShowWindow, focus or capture calls.
    MSG message{};
    while (GetMessageW(&message, nullptr, 0, 0) > 0) {
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }
    return 0;
}
