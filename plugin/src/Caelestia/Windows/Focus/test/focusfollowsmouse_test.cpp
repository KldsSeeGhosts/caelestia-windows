// Logic tests for the focus-follows-mouse controller. The fake system boundary
// is the point of this test: it proves the option reads the previous values
// before writing, writes only what differs, restores them when disabled or
// destroyed, and never touches the real Windows X-Mouse setting.

#include <qstring.h>
#include <qstringlist.h>

#include <QtTest/QtTest>

#include "focusfollowsmouse.hpp"

using namespace caelestia::shell::windows;

namespace {

class FakeFocusFollowsMouseSystem final: public FocusFollowsMouseSystem {
public:
    FocusFollowsMouseValues values;
    bool readResult = true;
    bool trackingResult = true;
    bool delayResult = true;
    bool raiseResult = true;

    int reads = 0;
    QStringList writes;

    bool read(FocusFollowsMouseValues& out) override {
        ++reads;
        if (!readResult)
            return false;
        out = values;
        return true;
    }

    bool setTracking(bool tracking) override {
        writes.append(QStringLiteral("tracking=%1").arg(tracking ? 1 : 0));
        if (!trackingResult)
            return false;
        values.tracking = tracking;
        return true;
    }

    bool setDelayMs(int delayMs) override {
        writes.append(QStringLiteral("delay=%1").arg(delayMs));
        if (!delayResult)
            return false;
        values.delayMs = delayMs;
        return true;
    }

    bool setRaise(bool raise) override {
        writes.append(QStringLiteral("raise=%1").arg(raise ? 1 : 0));
        if (!raiseResult)
            return false;
        values.raise = raise;
        return true;
    }
};

} // namespace

class FocusFollowsMouseTest: public QObject {
    Q_OBJECT

private slots:
    void disabledDoesNotTouchTheSystem();
    void enableCapturesAndRestores();
    void matchingValuesAreNotWritten();
    void reapplyWritesOnlyChanges();
    void recapturesAfterDisable();
    void clampsDelay();
    void readFailureDoesNotWrite();
    void partialFailureRollsBack();
    void destructorRestores();
    void restoreIsIdempotent();
};

void FocusFollowsMouseTest::disabledDoesNotTouchTheSystem() {
    FakeFocusFollowsMouseSystem system;
    system.values = {false, 400, false};
    FocusFollowsMouseController controller(system);

    QString error;
    QVERIFY(controller.apply(false, 100, false, &error));
    QVERIFY(error.isEmpty());
    QVERIFY(!controller.active());
    QCOMPARE(system.reads, 0);
    QVERIFY(system.writes.isEmpty());
    QCOMPARE(system.values.tracking, false);
    QCOMPARE(system.values.delayMs, 400);
}

void FocusFollowsMouseTest::enableCapturesAndRestores() {
    FakeFocusFollowsMouseSystem system;
    system.values = {false, 400, false};
    FocusFollowsMouseController controller(system);

    QString error;
    QVERIFY(controller.apply(true, 100, false, &error));
    QVERIFY(error.isEmpty());
    QVERIFY(controller.active());
    QCOMPARE(system.reads, 1);
    QCOMPARE(system.values.tracking, true);
    QCOMPARE(system.values.delayMs, 100);
    QCOMPARE(system.values.raise, false);
    QCOMPARE(system.writes, QStringList({QStringLiteral("tracking=1"), QStringLiteral("delay=100")}));
    QCOMPARE(controller.saved().tracking, false);
    QCOMPARE(controller.saved().delayMs, 400);
    QCOMPARE(controller.saved().raise, false);

    system.writes.clear();
    QVERIFY(controller.restore(&error));
    QVERIFY(error.isEmpty());
    QVERIFY(!controller.active());
    QCOMPARE(system.values.tracking, false);
    QCOMPARE(system.values.delayMs, 400);
    QCOMPARE(system.values.raise, false);
    QCOMPARE(system.writes, QStringList({QStringLiteral("tracking=0"), QStringLiteral("delay=400")}));
}

void FocusFollowsMouseTest::matchingValuesAreNotWritten() {
    FakeFocusFollowsMouseSystem system;
    system.values = {true, 100, false};
    FocusFollowsMouseController controller(system);

    QVERIFY(controller.apply(true, 100, false));
    QVERIFY(controller.active());
    QVERIFY(system.writes.isEmpty());

    QVERIFY(controller.restore());
    QVERIFY(!controller.active());
    QVERIFY(system.writes.isEmpty());
    QCOMPARE(system.values.tracking, true);
    QCOMPARE(system.values.delayMs, 100);
}

void FocusFollowsMouseTest::reapplyWritesOnlyChanges() {
    FakeFocusFollowsMouseSystem system;
    system.values = {false, 100, false};
    FocusFollowsMouseController controller(system);

    QVERIFY(controller.apply(true, 100, false));
    system.writes.clear();

    QVERIFY(controller.apply(true, 250, true));
    QVERIFY(controller.active());
    QCOMPARE(system.writes, QStringList({QStringLiteral("delay=250"), QStringLiteral("raise=1")}));
    QCOMPARE(controller.saved().delayMs, 100);
    QCOMPARE(controller.saved().raise, false);

    system.writes.clear();
    QVERIFY(controller.restore());
    QCOMPARE(system.writes,
        QStringList({QStringLiteral("tracking=0"), QStringLiteral("delay=100"),
            QStringLiteral("raise=0")}));
    QCOMPARE(system.values.tracking, false);
    QCOMPARE(system.values.delayMs, 100);
    QCOMPARE(system.values.raise, false);
}

void FocusFollowsMouseTest::recapturesAfterDisable() {
    FakeFocusFollowsMouseSystem system;
    system.values = {false, 100, false};
    FocusFollowsMouseController controller(system);

    QVERIFY(controller.apply(true, 100, false));
    QVERIFY(controller.restore());

    // The user changed the Windows setting while the option was off. A later
    // enable must save that value, not the one from the first enable.
    system.values = {true, 300, true};
    QVERIFY(controller.apply(true, 50, false));
    QCOMPARE(controller.saved().tracking, true);
    QCOMPARE(controller.saved().delayMs, 300);
    QCOMPARE(controller.saved().raise, true);
    QCOMPARE(system.values.tracking, true);
    QCOMPARE(system.values.delayMs, 50);
    QCOMPARE(system.values.raise, false);

    QVERIFY(controller.restore());
    QCOMPARE(system.values.tracking, true);
    QCOMPARE(system.values.delayMs, 300);
    QCOMPARE(system.values.raise, true);
}

void FocusFollowsMouseTest::clampsDelay() {
    FakeFocusFollowsMouseSystem system;
    system.values = {false, 100, false};
    FocusFollowsMouseController controller(system);

    QVERIFY(controller.apply(true, -50, false));
    QCOMPARE(system.values.delayMs, FocusFollowsMouseController::MIN_DELAY_MS);

    QVERIFY(controller.apply(true, 99999, false));
    QCOMPARE(system.values.delayMs, FocusFollowsMouseController::MAX_DELAY_MS);

    QVERIFY(controller.apply(true, FocusFollowsMouseController::DEFAULT_DELAY_MS, false));
    QCOMPARE(system.values.delayMs, FocusFollowsMouseController::DEFAULT_DELAY_MS);
}

void FocusFollowsMouseTest::readFailureDoesNotWrite() {
    FakeFocusFollowsMouseSystem system;
    system.values = {false, 100, false};
    system.readResult = false;
    FocusFollowsMouseController controller(system);

    QString error;
    QVERIFY(!controller.apply(true, 100, false, &error));
    QVERIFY(!error.isEmpty());
    QVERIFY(!controller.active());
    QCOMPARE(system.reads, 1);
    QVERIFY(system.writes.isEmpty());
}

void FocusFollowsMouseTest::partialFailureRollsBack() {
    FakeFocusFollowsMouseSystem system;
    system.values = {false, 100, false};
    system.delayResult = false;
    FocusFollowsMouseController controller(system);

    QString error;
    QVERIFY(!controller.apply(true, 250, false, &error));
    QVERIFY(!error.isEmpty());
    QVERIFY(!controller.active());
    // Tracking was applied, then the delay failed; the rollback put tracking
    // back and left the already-matching delay alone.
    QCOMPARE(system.values.tracking, false);
    QCOMPARE(system.values.delayMs, 100);
    QCOMPARE(system.writes,
        QStringList({QStringLiteral("tracking=1"), QStringLiteral("delay=250"),
            QStringLiteral("tracking=0")}));
}

void FocusFollowsMouseTest::destructorRestores() {
    FakeFocusFollowsMouseSystem system;
    system.values = {false, 100, false};
    {
        FocusFollowsMouseController controller(system);
        QVERIFY(controller.apply(true, 200, true));
        QCOMPARE(system.values.tracking, true);
        QCOMPARE(system.values.delayMs, 200);
        QCOMPARE(system.values.raise, true);
    }

    QCOMPARE(system.values.tracking, false);
    QCOMPARE(system.values.delayMs, 100);
    QCOMPARE(system.values.raise, false);
}

void FocusFollowsMouseTest::restoreIsIdempotent() {
    FakeFocusFollowsMouseSystem system;
    system.values = {false, 100, false};
    FocusFollowsMouseController controller(system);

    QVERIFY(controller.apply(true, 200, false));
    system.writes.clear();
    QVERIFY(controller.restore());
    QCOMPARE(system.writes, QStringList({QStringLiteral("tracking=0"), QStringLiteral("delay=100")}));
    system.writes.clear();
    QVERIFY(controller.restore());
    QVERIFY(system.writes.isEmpty());
}

QTEST_GUILESS_MAIN(FocusFollowsMouseTest)

#include "focusfollowsmouse_test.moc"
