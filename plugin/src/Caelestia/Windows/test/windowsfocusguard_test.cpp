// The focus guard's event policy is checked with the production source and a
// fake Win32 foreground model. No real window is activated, so the test never
// changes the desktop.

#include <qhash.h>
#include <qlist.h>
#include <qloggingcategory.h>
#include <qquickitem.h>
#include <qquickwindow.h>
#include <qsignalspy.h>
#include <qtimer.h>
#include <qt_windows.h>

#include <QtTest/QtTest>

namespace mock {

struct Window {
    bool visible = true;
    DWORD process = 0;
    DWORD thread = 1;
    LONG_PTR exStyle = 0;
};

QHash<HWND, Window> windows;
HWND foreground = nullptr;
DWORD tick = 1000;
DWORD currentProcess = 1000;
bool acceptForeground = true;
QList<HWND> foregroundRequests;

void reset() {
    windows.clear();
    foreground = nullptr;
    tick = 1000;
    acceptForeground = true;
    foregroundRequests.clear();
}

HWND add(HWND hwnd, DWORD process, bool visible = true) {
    windows.insert(hwnd, {visible, process, 1, 0});
    return hwnd;
}

HWND fake(quintptr value) {
    return reinterpret_cast<HWND>(value);
}

} // namespace mock

static BOOL mock_IsWindow(HWND hwnd) {
    return mock::windows.contains(hwnd) ? TRUE : FALSE;
}

static BOOL mock_IsWindowVisible(HWND hwnd) {
    const auto found = mock::windows.constFind(hwnd);
    return found != mock::windows.constEnd() && found->visible ? TRUE : FALSE;
}

static DWORD mock_GetWindowThreadProcessId(HWND hwnd, DWORD* process) {
    const auto found = mock::windows.constFind(hwnd);
    if (found == mock::windows.constEnd()) {
        if (process)
            *process = 0;
        return 0;
    }
    if (process)
        *process = found->process;
    return found->thread;
}

static HWND mock_GetForegroundWindow() {
    return mock::foreground;
}

static DWORD mock_GetCurrentProcessId() {
    return mock::currentProcess;
}

static DWORD mock_GetTickCount() {
    return mock::tick;
}

static LONG_PTR mock_GetWindowLongPtrW(HWND hwnd, int index) {
    Q_UNUSED(index);
    const auto found = mock::windows.constFind(hwnd);
    return found != mock::windows.constEnd() ? found->exStyle : 0;
}

static BOOL mock_SetForegroundWindow(HWND hwnd) {
    mock::foregroundRequests.append(hwnd);
    if (!mock::acceptForeground || !mock::windows.contains(hwnd))
        return FALSE;
    mock::foreground = hwnd;
    return TRUE;
}

// Resolve the guard's Win32 calls to the model above. The Qt and Windows
// headers are included first, so only the production source sees the macros.
#define IsWindow mock_IsWindow
#define IsWindowVisible mock_IsWindowVisible
#define GetWindowThreadProcessId mock_GetWindowThreadProcessId
#define GetForegroundWindow mock_GetForegroundWindow
#define GetCurrentProcessId mock_GetCurrentProcessId
#define GetTickCount mock_GetTickCount
#define GetWindowLongPtrW mock_GetWindowLongPtrW
#define SetForegroundWindow mock_SetForegroundWindow

#include "../windowsfocusguard.cpp"

#undef IsWindow
#undef IsWindowVisible
#undef GetWindowThreadProcessId
#undef GetForegroundWindow
#undef GetCurrentProcessId
#undef GetTickCount
#undef GetWindowLongPtrW
#undef SetForegroundWindow

using namespace caelestia::shell::windows;

namespace {

// The source's sequence is the latest queued event, so it can be ahead of the
// last delivered signal. Activation records it as the ordered boundary.
class FakeForegroundSource: public QObject {
    Q_OBJECT;
    Q_PROPERTY(qulonglong sequence READ sequence)

public:
    [[nodiscard]] quint64 sequence() const { return m_sequence; }

    void setSequence(quint64 sequence) { m_sequence = sequence; }

    void deliver(HWND hwnd, uint time, quint64 sequence) {
        m_sequence = qMax(m_sequence, sequence);
        emit foregroundChanged(
            static_cast<qulonglong>(reinterpret_cast<quintptr>(hwnd)),
            time,
            static_cast<qulonglong>(sequence));
    }

signals:
    void foregroundChanged(qulonglong hwnd, uint time, qulonglong sequence);

private:
    quint64 m_sequence = 0;
};

} // namespace

class WindowsFocusGuardTest: public QObject {
    Q_OBJECT;

private slots:
    void init();
    void cleanup();

    // Finding 1: returning to the retained application is a foreground event
    // the guard must treat as an outside choice.
    void retainedApplicationReturnDismisses();

    // Finding 2: an event queued before activation must not dismiss even when
    // it shares the activation tick; a genuine same-tick choice still does.
    void queuedPreActivationEventDoesNotDismiss();
    void sameTickOutsideChoiceDismisses();

    // Finding 3: a pre-activation event delivered while the panel owns focus is
    // still the restore target.
    void preActivationEventBecomesRestoreTarget();

    // Closing after the user picked another application must leave that
    // application in front instead of restoring the saved one.
    void closeAfterOutsideSelectionDoesNotRestore();

    // A pre-activation event delivered while the panel is not foreground must
    // not dismiss; the early panel-foreground return does not apply there.
    void queuedPreActivationEventWhileNotForegroundDoesNotDismiss();

private:
    HWND m_appA = nullptr;
    HWND m_appB = nullptr;
    HWND m_panel = nullptr;
    QQuickWindow* m_window = nullptr;
    QQuickItem* m_target = nullptr;
    FakeForegroundSource* m_source = nullptr;
    WindowsFocusGuard* m_guard = nullptr;
};

void WindowsFocusGuardTest::init() {
    mock::reset();
    m_appA = mock::add(mock::fake(0xA001), 2000);
    m_appB = mock::add(mock::fake(0xB002), 3000);

    m_window = new QQuickWindow();
    m_window->resize(120, 80);
    m_target = new QQuickItem(m_window->contentItem());
    m_target->setSize(QSizeF(120, 80));

    const WId id = m_window->winId();
    QVERIFY2(id != 0, "the offscreen window has no native handle");
    m_panel = mock::add(reinterpret_cast<HWND>(id), mock::currentProcess);

    m_source = new FakeForegroundSource();
    m_guard = new WindowsFocusGuard();
    m_guard->setTarget(m_target);
    m_guard->setForegroundSource(m_source);

    mock::foreground = m_appA;
    m_source->setSequence(10);
    m_guard->setActive(true);
    QCoreApplication::processEvents();

    QCOMPARE(mock::foreground, m_panel);
}

void WindowsFocusGuardTest::cleanup() {
    delete m_guard;
    delete m_source;
    delete m_window;
    m_guard = nullptr;
    m_source = nullptr;
    m_window = nullptr;
    m_target = nullptr;
    mock::reset();
}

void WindowsFocusGuardTest::retainedApplicationReturnDismisses() {
    QSignalSpy dismiss(m_guard, &WindowsFocusGuard::dismissRequested);

    // The user clicks the application the panel was opened over. Its raw event
    // is the only signal the backend can give; the display address did not
    // change, so the guard must use this event, not a property change.
    mock::foreground = m_appA;
    m_source->deliver(m_appA, mock::tick + 1, 11);

    QCOMPARE(dismiss.count(), 1);
}

void WindowsFocusGuardTest::queuedPreActivationEventDoesNotDismiss() {
    QSignalSpy dismiss(m_guard, &WindowsFocusGuard::dismissRequested);

    // B was chosen in the same millisecond as the activation but queued before
    // it. The panel still owns the foreground, so this is not an outside
    // choice; the ordered boundary must reject it.
    QCOMPARE(mock::foreground, m_panel);
    m_source->deliver(m_appB, mock::tick, 9);

    QCOMPARE(dismiss.count(), 0);
}

void WindowsFocusGuardTest::sameTickOutsideChoiceDismisses() {
    QSignalSpy dismiss(m_guard, &WindowsFocusGuard::dismissRequested);

    // A genuine choice after the boundary may share the activation tick. The
    // sequence, not the tick, decides, so this must dismiss.
    mock::foreground = m_appB;
    m_source->deliver(m_appB, mock::tick, 11);

    QCOMPARE(dismiss.count(), 1);
}

void WindowsFocusGuardTest::preActivationEventBecomesRestoreTarget() {
    // B was the last application before the boundary but its event arrived
    // after the panel took the foreground. It must be the restore target.
    QCOMPARE(mock::foreground, m_panel);
    m_source->deliver(m_appB, mock::tick, 9);

    QSignalSpy outcome(m_guard, &WindowsFocusGuard::outcome);
    m_guard->setActive(false);
    QCoreApplication::processEvents();

    QCOMPARE(mock::foreground, m_appB);
    QVERIFY(!mock::foregroundRequests.isEmpty());
    QCOMPARE(mock::foregroundRequests.constLast(), m_appB);
    QVERIFY(!outcome.isEmpty());
    QCOMPARE(outcome.constLast().constFirst().toString(), QStringLiteral("restore-succeeded"));
}

void WindowsFocusGuardTest::closeAfterOutsideSelectionDoesNotRestore() {
    mock::foreground = m_appB;
    mock::foregroundRequests.clear();

    QSignalSpy outcome(m_guard, &WindowsFocusGuard::outcome);
    m_guard->setActive(false);
    QCoreApplication::processEvents();

    QCOMPARE(mock::foreground, m_appB);
    QVERIFY(mock::foregroundRequests.isEmpty());
    QVERIFY(!outcome.isEmpty());
    QCOMPARE(outcome.constLast().constFirst().toString(),
        QStringLiteral("restore-skipped-foreground-changed"));
}

void WindowsFocusGuardTest::queuedPreActivationEventWhileNotForegroundDoesNotDismiss() {
    QSignalSpy dismiss(m_guard, &WindowsFocusGuard::dismissRequested);

    mock::foreground = m_appB;
    m_source->deliver(m_appB, mock::tick, 9);

    QCOMPARE(dismiss.count(), 0);
}

QTEST_MAIN(WindowsFocusGuardTest)

#include "windowsfocusguard_test.moc"
