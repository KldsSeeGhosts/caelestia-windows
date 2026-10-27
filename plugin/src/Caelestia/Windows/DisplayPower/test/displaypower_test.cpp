// Fakes-only tests for the explicit panel-off action. Every system command is
// swallowed by the recording window procedure, so no test changes real display
// power state.

#include <qelapsedtimer.h>
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
    void actionSendsExactlyOnceAfterTheDelay();
    void repeatedRequestsShareOneSend();
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

void DisplayPowerTest::actionSendsExactlyOnceAfterTheDelay() {
    const HWND owner = displayPowerWindow();
    QVERIFY(owner);

    int calls = 0;
    HWND received = nullptr;
    QElapsedTimer elapsed;
    elapsed.start();
    DisplayPowerAction action(
        owner,
        [&calls, &received](HWND window) {
            ++calls;
            received = window;
            return true;
        },
        500);
    QSignalSpy spy(&action, &DisplayPowerAction::delivered);

    QVERIFY(action.request());
    QVERIFY(action.pending());
    QCOMPARE(calls, 0);

    QTest::qWait(50);
    QCOMPARE(calls, 0);

    QTRY_COMPARE_WITH_TIMEOUT(calls, 1, 2000);
    QVERIFY(elapsed.elapsed() >= action.delayMs());
    QCOMPARE(received, owner);
    QVERIFY(!action.pending());
    QCOMPARE(spy.count(), 1);
    QCOMPARE(spy.at(0).at(0).toBool(), true);

    DWORD process = 0;
    QVERIFY(GetWindowThreadProcessId(received, &process) > 0);
    QCOMPARE(process, GetCurrentProcessId());

    // No repeat and no extra send from the same request.
    QTest::qWait(150);
    QCOMPARE(calls, 1);
}

void DisplayPowerTest::repeatedRequestsShareOneSend() {
    RecordedCommand unused;
    const HWND owner = createRecordingWindow(unused);
    QVERIFY(owner);

    int calls = 0;
    DisplayPowerAction action(
        owner,
        [&calls](HWND) {
            ++calls;
            return true;
        },
        120);

    QVERIFY(action.request());
    QVERIFY(!action.request());
    QCOMPARE(calls, 0);
    QTRY_COMPARE_WITH_TIMEOUT(calls, 1, 2000);
    QTest::qWait(100);
    QCOMPARE(calls, 1);

    // A completed request may be started again.
    QVERIFY(action.request());
    QTRY_COMPARE_WITH_TIMEOUT(calls, 2, 2000);

    QVERIFY(DestroyWindow(owner));
}

void DisplayPowerTest::invalidWindowsAreRefused() {
    int calls = 0;
    DisplayPowerAction missing(
        nullptr,
        [&calls](HWND) {
            ++calls;
            return true;
        },
        20);
    QVERIFY(!missing.request());

    DisplayPowerAction stale(
        reinterpret_cast<HWND>(static_cast<quintptr>(0x1234)),
        [&calls](HWND) {
            ++calls;
            return true;
        },
        20);
    QVERIFY(!stale.request());

    QTest::qWait(80);
    QCOMPARE(calls, 0);
    QVERIFY(!sendMonitorPowerOff(nullptr));
}

void DisplayPowerTest::cleanupTestCase() {
    QVERIFY(UnregisterClassW(TEST_WINDOW_CLASS, GetModuleHandleW(nullptr)));
}

QTEST_GUILESS_MAIN(DisplayPowerTest)

#include "displaypower_test.moc"
