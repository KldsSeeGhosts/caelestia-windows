// Logic tests for the focus-follows-mouse controller. The fake system boundary
// is the point of this test: it proves the option reads the previous values
// before writing, writes only what differs, restores them when disabled or
// destroyed, shares one baseline between overlapping QML generations, and
// never touches the real Windows X-Mouse setting.

#include <memory>

#include <qdir.h>
#include <qfile.h>
#include <qstring.h>
#include <qstringlist.h>
#include <qtemporarydir.h>

#include <QtTest/QtTest>

#include "focusfollowsmouse.hpp"

using namespace caelestia::shell::windows;

namespace {

QByteArray recoveryContents(const FocusFollowsMouseValues& baseline,
    const FocusFollowsMouseValues& applied) {
    return QStringLiteral("version=2\ntracking=%1\ndelay=%2\nraise=%3\n"
                          "appliedTracking=%4\nappliedDelay=%5\nappliedRaise=%6\n")
        .arg(baseline.tracking ? 1 : 0)
        .arg(baseline.delayMs)
        .arg(baseline.raise ? 1 : 0)
        .arg(applied.tracking ? 1 : 0)
        .arg(applied.delayMs)
        .arg(applied.raise ? 1 : 0)
        .toUtf8();
}

bool writeFile(const QString& path, const QByteArray& contents) {
    QFile file(path);
    if (!file.open(QIODevice::WriteOnly))
        return false;
    return file.write(contents) == contents.size();
}

QByteArray readFile(const QString& path) {
    QFile file(path);
    if (!file.open(QIODevice::ReadOnly))
        return {};
    return file.readAll();
}

class FakeFocusFollowsMouseSystem final: public FocusFollowsMouseSystem {
public:
    FocusFollowsMouseValues values;
    bool readResult = true;
    bool trackingResult = true;
    bool delayResult = true;
    bool raiseResult = true;

    int reads = 0;
    QStringList writes;
    QString recoveryFileThatMustExist;

    bool recoveryReady() const {
        return recoveryFileThatMustExist.isEmpty() || QFile::exists(recoveryFileThatMustExist);
    }

    bool read(FocusFollowsMouseValues& out) override {
        ++reads;
        if (!readResult)
            return false;
        out = values;
        return true;
    }

    bool setTracking(bool tracking) override {
        writes.append(QStringLiteral("tracking=%1").arg(tracking ? 1 : 0));
        if (!recoveryReady() || !trackingResult)
            return false;
        values.tracking = tracking;
        return true;
    }

    bool setDelayMs(int delayMs) override {
        writes.append(QStringLiteral("delay=%1").arg(delayMs));
        if (!recoveryReady() || !delayResult)
            return false;
        values.delayMs = delayMs;
        return true;
    }

    bool setRaise(bool raise) override {
        writes.append(QStringLiteral("raise=%1").arg(raise ? 1 : 0));
        if (!recoveryReady() || !raiseResult)
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
    void overlappingGenerationsShareBaseline();
    void mostRecentUpdateWins();
    void recoveryFileUsedWhenSystemStillMatches();
    void recoveryFileDiscardedWhenUserChangedSetting();
    void recoveryFileWithoutAppliedValuesIsDiscarded();
    void liveDelayChangeRewritesAppliedValues();
    void recoveryFileWrittenBeforeFirstChange();
    void disabledDoesNotWriteRecoveryFile();
};

void FocusFollowsMouseTest::disabledDoesNotTouchTheSystem() {
    FakeFocusFollowsMouseSystem system;
    system.values = {false, 400, false};
    FocusFollowsMouseOwner owner;
    FocusFollowsMouseController controller(system, &owner);

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
    FocusFollowsMouseOwner owner;
    FocusFollowsMouseController controller(system, &owner);

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
    FocusFollowsMouseOwner owner;
    FocusFollowsMouseController controller(system, &owner);

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
    FocusFollowsMouseOwner owner;
    FocusFollowsMouseController controller(system, &owner);

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
    FocusFollowsMouseOwner owner;
    FocusFollowsMouseController controller(system, &owner);

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
    FocusFollowsMouseOwner owner;
    FocusFollowsMouseController controller(system, &owner);

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
    FocusFollowsMouseOwner owner;
    FocusFollowsMouseController controller(system, &owner);

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
    FocusFollowsMouseOwner owner;
    FocusFollowsMouseController controller(system, &owner);

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
    FocusFollowsMouseOwner owner;
    {
        FocusFollowsMouseController controller(system, &owner);
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
    FocusFollowsMouseOwner owner;
    FocusFollowsMouseController controller(system, &owner);

    QVERIFY(controller.apply(true, 200, false));
    system.writes.clear();
    QVERIFY(controller.restore());
    QCOMPARE(system.writes, QStringList({QStringLiteral("tracking=0"), QStringLiteral("delay=100")}));
    system.writes.clear();
    QVERIFY(controller.restore());
    QVERIFY(system.writes.isEmpty());
}

void FocusFollowsMouseTest::overlappingGenerationsShareBaseline() {
    FakeFocusFollowsMouseSystem system;
    system.values = {false, 400, false};
    FocusFollowsMouseOwner owner;

    auto first = std::make_unique<FocusFollowsMouseController>(system, &owner);
    QVERIFY(first->apply(true, 100, false));
    QCOMPARE(system.values.tracking, true);
    QCOMPARE(system.values.delayMs, 100);

    // Quickshell loads the replacement generation before destroying the old
    // one. The replacement must not capture the old generation's applied
    // values as its baseline, and the old destructor must not restore while
    // the replacement is live.
    auto second = std::make_unique<FocusFollowsMouseController>(system, &owner);
    QVERIFY(second->apply(true, 250, true));
    QVERIFY(second->active());
    QCOMPARE(second->saved().tracking, false);
    QCOMPARE(second->saved().delayMs, 400);

    system.writes.clear();
    first.reset();
    QVERIFY(second->active());
    QCOMPARE(system.values.tracking, true);
    QCOMPARE(system.values.delayMs, 250);
    QCOMPARE(system.values.raise, true);
    QVERIFY(system.writes.isEmpty());

    second.reset();
    QCOMPARE(system.values.tracking, false);
    QCOMPARE(system.values.delayMs, 400);
    QCOMPARE(system.values.raise, false);
}

void FocusFollowsMouseTest::mostRecentUpdateWins() {
    FakeFocusFollowsMouseSystem system;
    system.values = {false, 100, false};
    FocusFollowsMouseOwner owner;

    auto first = std::make_unique<FocusFollowsMouseController>(system, &owner);
    auto second = std::make_unique<FocusFollowsMouseController>(system, &owner);
    QVERIFY(first->apply(true, 100, false));
    QVERIFY(second->apply(true, 250, false));
    QVERIFY(first->apply(true, 300, true));

    QCOMPARE(system.values.delayMs, 300);
    second.reset();
    QCOMPARE(system.values.delayMs, 300);
    QCOMPARE(system.values.raise, true);

    first.reset();
    QCOMPARE(system.values.delayMs, 100);
    QCOMPARE(system.values.tracking, false);
}

void FocusFollowsMouseTest::recoveryFileUsedWhenSystemStillMatches() {
    QTemporaryDir directory;
    QVERIFY(directory.isValid());
    const auto path = directory.filePath(QStringLiteral("focus-follows-mouse-recovery.json"));

    // A crashed session applied (true, 100, false) and left this file.
    QVERIFY(writeFile(path,
        recoveryContents({false, 400, true}, {true, 100, false})));

    FakeFocusFollowsMouseSystem system;
    // The system still holds the values that session applied.
    system.values = {true, 100, false};
    FocusFollowsMouseOwner owner;
    FocusFollowsMouseController controller(system, &owner);
    controller.setRecoveryPath(path);

    QVERIFY(controller.apply(true, 50, false));
    QCOMPARE(controller.saved().tracking, false);
    QCOMPARE(controller.saved().delayMs, 400);
    QCOMPARE(controller.saved().raise, true);
    // The recovered baseline stays, but the recorded applied values follow the
    // new delay.
    QCOMPARE(readFile(path), recoveryContents({false, 400, true}, {true, 50, false}));

    QVERIFY(controller.restore());
    QCOMPARE(system.values.tracking, false);
    QCOMPARE(system.values.delayMs, 400);
    QCOMPARE(system.values.raise, true);
    QVERIFY(!QFile::exists(path));
}

void FocusFollowsMouseTest::recoveryFileDiscardedWhenUserChangedSetting() {
    QTemporaryDir directory;
    QVERIFY(directory.isValid());
    const auto path = directory.filePath(QStringLiteral("focus-follows-mouse-recovery.json"));

    // A crashed session applied (true, 100, false) and left this file.
    QVERIFY(writeFile(path,
        recoveryContents({false, 100, false}, {true, 100, false})));

    FakeFocusFollowsMouseSystem system;
    // While the shell was down the user changed X-Mouse to these values, so
    // the stale baseline no longer describes what to restore.
    system.values = {true, 900, true};
    FocusFollowsMouseOwner owner;
    FocusFollowsMouseController controller(system, &owner);
    controller.setRecoveryPath(path);

    QVERIFY(controller.apply(true, 150, false));
    QCOMPARE(controller.saved().tracking, true);
    QCOMPARE(controller.saved().delayMs, 900);
    QCOMPARE(controller.saved().raise, true);
    QCOMPARE(system.values.tracking, true);
    QCOMPARE(system.values.delayMs, 150);
    QCOMPARE(system.values.raise, false);

    // The stale file was discarded and replaced by the fresh capture.
    QCOMPARE(readFile(path), recoveryContents({true, 900, true}, {true, 150, false}));

    QVERIFY(controller.restore());
    QCOMPARE(system.values.tracking, true);
    QCOMPARE(system.values.delayMs, 900);
    QCOMPARE(system.values.raise, true);
    QVERIFY(!QFile::exists(path));
}

void FocusFollowsMouseTest::recoveryFileWithoutAppliedValuesIsDiscarded() {
    QTemporaryDir directory;
    QVERIFY(directory.isValid());
    const auto path = directory.filePath(QStringLiteral("focus-follows-mouse-recovery.json"));

    // Older builds wrote no applied values, so the file can't be validated.
    QVERIFY(writeFile(path, QByteArray("version=1\ntracking=0\ndelay=400\nraise=1\n")));

    FakeFocusFollowsMouseSystem system;
    system.values = {true, 300, true};
    FocusFollowsMouseOwner owner;
    FocusFollowsMouseController controller(system, &owner);
    controller.setRecoveryPath(path);

    QVERIFY(controller.apply(true, 100, false));
    QCOMPARE(controller.saved().tracking, true);
    QCOMPARE(controller.saved().delayMs, 300);
    QCOMPARE(controller.saved().raise, true);

    QVERIFY(controller.restore());
    QCOMPARE(system.values.tracking, true);
    QCOMPARE(system.values.delayMs, 300);
    QCOMPARE(system.values.raise, true);
    QVERIFY(!QFile::exists(path));
}

void FocusFollowsMouseTest::liveDelayChangeRewritesAppliedValues() {
    QTemporaryDir directory;
    QVERIFY(directory.isValid());
    const auto path = directory.filePath(QStringLiteral("focus-follows-mouse-recovery.json"));

    FakeFocusFollowsMouseSystem system;
    system.values = {false, 400, false};
    FocusFollowsMouseOwner owner;
    FocusFollowsMouseController controller(system, &owner);
    controller.setRecoveryPath(path);

    QVERIFY(controller.apply(true, 100, false));
    QCOMPARE(readFile(path), recoveryContents({false, 400, false}, {true, 100, false}));

    // A live delay and raise change must rewrite the applied values while the
    // baseline stays the same.
    QVERIFY(controller.apply(true, 250, true));
    QCOMPARE(readFile(path), recoveryContents({false, 400, false}, {true, 250, true}));
    QCOMPARE(controller.saved().delayMs, 400);

    QVERIFY(controller.restore());
    QCOMPARE(system.values.tracking, false);
    QCOMPARE(system.values.delayMs, 400);
    QCOMPARE(system.values.raise, false);
    QVERIFY(!QFile::exists(path));
}

void FocusFollowsMouseTest::recoveryFileWrittenBeforeFirstChange() {
    QTemporaryDir directory;
    QVERIFY(directory.isValid());
    const auto path = directory.filePath(QStringLiteral("focus-follows-mouse-recovery.json"));

    FakeFocusFollowsMouseSystem system;
    system.values = {false, 400, false};
    // Any SET call before the baseline is persisted fails the test.
    system.recoveryFileThatMustExist = path;
    FocusFollowsMouseOwner owner;
    FocusFollowsMouseController controller(system, &owner);
    controller.setRecoveryPath(path);

    QVERIFY(controller.apply(true, 100, false));
    QCOMPARE(readFile(path), recoveryContents({false, 400, false}, {true, 100, false}));

    QVERIFY(controller.restore());
    QVERIFY(!QFile::exists(path));
}

void FocusFollowsMouseTest::disabledDoesNotWriteRecoveryFile() {
    QTemporaryDir directory;
    QVERIFY(directory.isValid());
    const auto path = directory.filePath(QStringLiteral("focus-follows-mouse-recovery.json"));

    FakeFocusFollowsMouseSystem system;
    system.values = {false, 400, false};
    FocusFollowsMouseOwner owner;
    FocusFollowsMouseController controller(system, &owner);
    controller.setRecoveryPath(path);

    QVERIFY(controller.apply(false, 100, false));
    QVERIFY(!QFile::exists(path));
    QCOMPARE(system.reads, 0);
    QVERIFY(system.writes.isEmpty());
}

QTEST_GUILESS_MAIN(FocusFollowsMouseTest)

#include "focusfollowsmouse_test.moc"
