// Light logic tests for the clipboard worker helpers. These cover the
// decisions that previously failed silently: a non-Success
// SetHistoryItemAsContent status, and an event-driven history read scheduled
// for a picker that has since closed.

#include <QtTest/QtTest>

#include "clipboardlogic.hpp"

using namespace caelestia::shell::windows;

class ClipboardLogicTest: public QObject {
    Q_OBJECT

private slots:
    void setContentStatus();
    void refreshGateStaysClosed();
    void refreshGateCoalesces();
    void refreshGateDeactivationInvalidates();
    void refreshGateReopenInvalidatesStaleRead();
};

void ClipboardLogicTest::setContentStatus() {
    const auto success = clipboardSetContentResult(static_cast<int>(ClipboardSetContentStatus::Success));
    QVERIFY(success.ok);
    QVERIFY(success.message.isEmpty());

    const auto denied = clipboardSetContentResult(static_cast<int>(ClipboardSetContentStatus::AccessDenied));
    QVERIFY(!denied.ok);
    QVERIFY(denied.message.contains(QStringLiteral("denied")));

    const auto deleted = clipboardSetContentResult(static_cast<int>(ClipboardSetContentStatus::ItemDeleted));
    QVERIFY(!deleted.ok);
    QVERIFY(deleted.message.contains(QStringLiteral("deleted")));

    const auto unknown = clipboardSetContentResult(99);
    QVERIFY(!unknown.ok);
    QVERIFY(unknown.message.contains(QStringLiteral("unknown")));
}

void ClipboardLogicTest::refreshGateStaysClosed() {
    ClipboardRefreshGate gate;
    QVERIFY(!gate.active());
    QCOMPARE(gate.onEvent(), ClipboardRefreshGate::EventDecision::Ignore);
    QCOMPARE(gate.onTimeout(), ClipboardRefreshGate::TimeoutDecision::Ignore);

    gate.setActive(false);
    QCOMPARE(gate.onEvent(), ClipboardRefreshGate::EventDecision::Ignore);
    QCOMPARE(gate.onTimeout(), ClipboardRefreshGate::TimeoutDecision::Ignore);
}

void ClipboardLogicTest::refreshGateCoalesces() {
    ClipboardRefreshGate gate;
    gate.setActive(true);
    QVERIFY(gate.active());

    QCOMPARE(gate.onEvent(), ClipboardRefreshGate::EventDecision::Schedule);
    // Repeated events in the same window stay one pending read.
    QCOMPARE(gate.onEvent(), ClipboardRefreshGate::EventDecision::Schedule);
    QVERIFY(gate.pending());

    QCOMPARE(gate.onTimeout(), ClipboardRefreshGate::TimeoutDecision::Refresh);
    QVERIFY(!gate.pending());
    QCOMPARE(gate.onTimeout(), ClipboardRefreshGate::TimeoutDecision::Ignore);
}

void ClipboardLogicTest::refreshGateDeactivationInvalidates() {
    ClipboardRefreshGate gate;
    gate.setActive(true);
    QCOMPARE(gate.onEvent(), ClipboardRefreshGate::EventDecision::Schedule);
    const auto scheduledGeneration = gate.nextRead();
    QVERIFY(gate.accepts(scheduledGeneration));

    // Closing the picker must cancel the scheduled read and any in-flight
    // completion from the previous session.
    gate.setActive(false);
    QCOMPARE(gate.onTimeout(), ClipboardRefreshGate::TimeoutDecision::Ignore);
    QVERIFY(!gate.accepts(scheduledGeneration));

    gate.setActive(false);
    QCOMPARE(gate.onTimeout(), ClipboardRefreshGate::TimeoutDecision::Ignore);
}

void ClipboardLogicTest::refreshGateReopenInvalidatesStaleRead() {
    ClipboardRefreshGate gate;
    gate.setActive(true);
    const auto firstSession = gate.nextRead();

    gate.setActive(false);
    gate.setActive(true);
    // A completion for the first session must not publish into the reopened
    // picker.
    QVERIFY(!gate.accepts(firstSession));

    const auto secondSession = gate.nextRead();
    QVERIFY(gate.accepts(secondSession));

    // A newer explicit read invalidates the older completion too.
    const auto newer = gate.nextRead();
    QVERIFY(!gate.accepts(secondSession));
    QVERIFY(gate.accepts(newer));
}

QTEST_GUILESS_MAIN(ClipboardLogicTest)

#include "clipboardlogic_test.moc"
