// Fakes-only tests for the explicit panel-off action. Every system command is
// swallowed by the recording window procedure, so no test changes real display
// power state.

#include <qsignalspy.h>
#include <qt_windows.h>

#include <QtTest/QtTest>

#include "displaypower.hpp"

using namespace caelestia::shell::windows;

namespace {

struct RecordedCommand {
    int count = 0;
    WPARAM command = 0;
    LPARAM monitorPower = 0;
};

constexpr wchar_t TEST_WINDOW_CLASS[] = L"CaelestiaDisplayPowerTestWindow";

LRESULT CALLBACK recordingWindowProc(HWND window, UINT message, WPARAM wParam, LPARAM lParam) {
    if (message == WM_SYSCOMMAND) {
        auto* record = reinterpret_cast<RecordedCommand*>(GetWindowLongPtrW(window, GWLP_USERDATA));
        if (record) {
            ++record->count;
            record->command = wParam;
            record->monitorPower = lParam;
        }
        // Never call DefWindowProc: the fake must not ask Windows for display
        // power, even though the real sender is exercised.
        return 0;
    }
    return DefWindowProcW(window, message, wParam, lParam);
}

HWND createRecordingWindow(RecordedCommand& record) {
    const HWND window = CreateWindowExW(0, TEST_WINDOW_CLASS, L"Display power test", WS_POPUP, 0, 0, 0, 0, nullptr,
        nullptr, GetModuleHandleW(nullptr), nullptr);
    if (window)
        SetWindowLongPtrW(window, GWLP_USERDATA, reinterpret_cast<LONG_PTR>(&record));
    return window;
}

} // namespace

class DisplayPowerTest : public QObject {
    Q_OBJECT

private slots:
    void initTestCase();
    void ownerWindowIsOwnedByThisProcess();
    void senderSendsOneExactMonitorPowerCommand();
    void actionSendsImmediatelyWithoutScheduling();
    void everyRequestSendsOnce();
    void senderFailureIsReported();
    void invalidWindowsAreRefused();
    void cleanupTestCase();
};

void DisplayPowerTest::initTestCase() {
    WNDCLASSEXW windowClass{};
    windowClass.cbSize = sizeof(windowClass);
    windowClass.lpfnWndProc = recordingWindowProc;
    windowClass.hInstance = GetModuleHandleW(nullptr);
    windowClass.lpszClassName = TEST_WINDOW_CLASS;
    const bool registered = RegisterClassExW(&windowClass);
    QVERIFY(registered || GetLastError() == ERROR_CLASS_ALREADY_EXISTS);
}

void DisplayPowerTest::ownerWindowIsOwnedByThisProcess() {
    const HWND owner = displayPowerWindow();
    QVERIFY(owner);
    QVERIFY(IsWindow(owner));
    QVERIFY(!IsWindowVisible(owner));

    DWORD process = 0;
    QVERIFY(GetWindowThreadProcessId(owner, &process) > 0);
    QCOMPARE(process, GetCurrentProcessId());
}

void DisplayPowerTest::senderSendsOneExactMonitorPowerCommand() {
    RecordedCommand record;
    const HWND window = createRecordingWindow(record);
    QVERIFY(window);

    QVERIFY(sendMonitorPowerOff(window));
    QCOMPARE(record.count, 1);
    QCOMPARE(record.command, static_cast<WPARAM>(SC_MONITORPOWER));
    QCOMPARE(record.monitorPower, static_cast<LPARAM>(2));

    QVERIFY(DestroyWindow(window));
}

void DisplayPowerTest::actionSendsImmediatelyWithoutScheduling() {
    const HWND owner = displayPowerWindow();
    QVERIFY(owner);

    int calls = 0;
    HWND received = nullptr;
    DisplayPowerAction action(owner, [&calls, &received](HWND window) {
        ++calls;
        received = window;
        return true;
    });

    // No timer, event loop or delay: the send has already happened on return.
    QVERIFY(action.send());
    QCOMPARE(calls, 1);
    QCOMPARE(received, owner);

    DWORD process = 0;
    QVERIFY(GetWindowThreadProcessId(received, &process) > 0);
    QCOMPARE(process, GetCurrentProcessId());
}

void DisplayPowerTest::everyRequestSendsOnce() {
    RecordedCommand unused;
    const HWND owner = createRecordingWindow(unused);
    QVERIFY(owner);

    int calls = 0;
    DisplayPowerAction action(owner, [&calls](HWND) {
        ++calls;
        return true;
    });

    QVERIFY(action.send());
    QCOMPARE(calls, 1);
    QVERIFY(action.send());
    QCOMPARE(calls, 2);

    QVERIFY(DestroyWindow(owner));
}

void DisplayPowerTest::senderFailureIsReported() {
    const HWND owner = displayPowerWindow();
    QVERIFY(owner);

    int calls = 0;
    DisplayPowerAction action(owner, [&calls](HWND) {
        ++calls;
        return false;
    });

    QVERIFY(!action.send());
    QCOMPARE(calls, 1);
}

void DisplayPowerTest::invalidWindowsAreRefused() {
    int calls = 0;
    DisplayPowerAction missing(nullptr, [&calls](HWND) {
        ++calls;
        return true;
    });
    QVERIFY(!missing.send());

    DisplayPowerAction stale(reinterpret_cast<HWND>(static_cast<quintptr>(0x1234)),
        [&calls](HWND) {
            ++calls;
            return true;
        });
    QVERIFY(!stale.send());

    QCOMPARE(calls, 0);
    QVERIFY(!sendMonitorPowerOff(nullptr));
}

void DisplayPowerTest::cleanupTestCase() {
    QVERIFY(UnregisterClassW(TEST_WINDOW_CLASS, GetModuleHandleW(nullptr)));
}

QTEST_GUILESS_MAIN(DisplayPowerTest)

#include "displaypower_test.moc"
