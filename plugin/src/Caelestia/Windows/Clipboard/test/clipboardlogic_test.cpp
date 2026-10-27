// Light logic tests for the clipboard worker helpers. These cover the
// decisions that previously failed silently: a non-Success
// SetHistoryItemAsContent status, a picker close that must invalidate a
// blocking history read, and the per-instance cache delete boundary.

#include <QtTest/QtTest>

#include <qdir.h>
#include <qfile.h>
#include <qfileinfo.h>
#include <qtemporarydir.h>

#include "clipboardcache.hpp"
#include "clipboardlogic.hpp"
#include "clipboardstate.hpp"

using namespace caelestia::shell::windows;

namespace {

bool writeSentinel(const QString& path) {
    QFile file(path);
    if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate))
        return false;
    const QByteArray content("sentinel");
    return file.write(content) == content.size();
}

} // namespace

class ClipboardLogicTest: public QObject {
    Q_OBJECT

private slots:
    void setContentStatus();
    void sessionStaysClosed();
    void sessionDeactivationIsImmediate();
    void sessionReopenInvalidatesStaleRead();
    void shutdownBeforeCacheRootDeletesNothing();
    void cleanupIsConfinedToTheInstanceDirectory();
    void liveSiblingCacheDirectorySurvives();
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

void ClipboardLogicTest::sessionStaysClosed() {
    ClipboardSessionState session;
    QVERIFY(!session.active());
    QVERIFY(!session.accepts(session.nextRead()));

    session.deactivate();
    QVERIFY(!session.active());
    QVERIFY(!session.accepts(session.nextRead()));
    QVERIFY(!session.stopping());

    session.requestStop();
    QVERIFY(session.stopping());
}

void ClipboardLogicTest::sessionDeactivationIsImmediate() {
    ClipboardSessionState session;
    session.activate();
    const auto read = session.nextRead();
    QVERIFY(session.active());
    QVERIFY(session.accepts(read));

    // The GUI-side close updates the shared state directly; no queued
    // setActive(false) is needed before a late completion is rejected.
    session.deactivate();
    QVERIFY(!session.active());
    QVERIFY(!session.accepts(read));
}

void ClipboardLogicTest::sessionReopenInvalidatesStaleRead() {
    ClipboardSessionState session;
    session.activate();
    const auto firstSession = session.nextRead();

    session.deactivate();
    session.activate();
    // A completion from the previous session must not publish into the
    // reopened picker.
    QVERIFY(!session.accepts(firstSession));

    const auto secondSession = session.nextRead();
    QVERIFY(session.accepts(secondSession));

    // A newer explicit refresh invalidates the older completion too.
    const auto newer = session.nextRead();
    QVERIFY(!session.accepts(secondSession));
    QVERIFY(session.accepts(newer));
}

void ClipboardLogicTest::shutdownBeforeCacheRootDeletesNothing() {
    QTemporaryDir working;
    QVERIFY(working.isValid());
    QTemporaryDir elsewhere;
    QVERIFY(elsewhere.isValid());

    const auto cwdSentinel = working.filePath(QStringLiteral("cwd-sentinel.txt"));
    const auto tempSentinel = elsewhere.filePath(QStringLiteral("temp-sentinel.txt"));
    QVERIFY(writeSentinel(cwdSentinel));
    QVERIFY(writeSentinel(tempSentinel));

    const auto previous = QDir::currentPath();
    QVERIFY(QDir::setCurrent(working.path()));
    {
        // Shutdown before the queued cache setter: the instance was never
        // configured. This is the P0 regression: no QDir("") and no delete in
        // the process working directory or any temp directory.
        ClipboardCacheDirectory cache;
        QVERIFY(!cache.configured());
        QVERIFY(cache.remove());
        QVERIFY(!cache.configure(QString(), 4242, 1));
        QVERIFY(!cache.configure(QStringLiteral("relative/cache"), 4242, 1));
        QVERIFY(cache.remove());
    }
    QVERIFY(QDir::setCurrent(previous));

    QVERIFY(QFileInfo::exists(cwdSentinel));
    QVERIFY(QFileInfo::exists(tempSentinel));
}

void ClipboardLogicTest::cleanupIsConfinedToTheInstanceDirectory() {
    QTemporaryDir root;
    QVERIFY(root.isValid());
    QVERIFY(writeSentinel(root.filePath(QStringLiteral("root-sentinel.txt"))));
    QVERIFY(QDir().mkpath(root.filePath(QStringLiteral("clipboard"))));
    QVERIFY(writeSentinel(root.filePath(QStringLiteral("clipboard/keep.txt"))));

    ClipboardCacheDirectory cache;
    QVERIFY(cache.configure(root.path(), 4242, 0x1234567890abcdefULL));
    QVERIFY(ClipboardCacheDirectory::validInstanceName(cache.name()));
    QVERIFY(cache.ensure());
    QVERIFY(writeSentinel(cache.filePath(QStringLiteral("preview.png"))));
    QVERIFY(writeSentinel(cache.filePath(QStringLiteral("clipboard-opened.txt"))));

    // A valid sibling is not this instance's directory; remove() must leave it
    // alone.
    const auto siblingName = QStringLiteral("4243-00000000deadbeef");
    const auto siblingPath = root.filePath(QStringLiteral("clipboard/") + siblingName);
    QVERIFY(QDir().mkpath(siblingPath));
    QVERIFY(writeSentinel(siblingPath + QStringLiteral("/sibling.txt")));

    QVERIFY(cache.remove());
    QVERIFY(!QFileInfo::exists(cache.path()));
    QVERIFY(QFileInfo::exists(root.filePath(QStringLiteral("root-sentinel.txt"))));
    QVERIFY(QFileInfo::exists(root.filePath(QStringLiteral("clipboard/keep.txt"))));
    QVERIFY(QFileInfo::exists(siblingPath + QStringLiteral("/sibling.txt")));
}

void ClipboardLogicTest::liveSiblingCacheDirectorySurvives() {
    QTemporaryDir root;
    QVERIFY(root.isValid());
    const auto base = root.filePath(QStringLiteral("clipboard"));
    QVERIFY(QDir().mkpath(base));

    const auto ownName = QStringLiteral("1000-0000000000000001");
    const auto liveName = QStringLiteral("1001-0000000000000002");
    const auto deadName = QStringLiteral("1002-0000000000000003");
    const auto bogusName = QStringLiteral("keep-me");
    for (const auto& name: {ownName, liveName, deadName, bogusName}) {
        QVERIFY(QDir().mkpath(base + QLatin1Char('/') + name));
        QVERIFY(writeSentinel(base + QLatin1Char('/') + name + QStringLiteral("/sentinel.txt")));
    }

    const auto removed = ClipboardCacheDirectory::removeDeadSiblings(
        root.path(), ownName, [](quint32 pid) { return pid == 1001; });
    QCOMPARE(removed, 1);

    QVERIFY(QFileInfo::exists(base + QLatin1Char('/') + ownName));
    QVERIFY(QFileInfo::exists(base + QLatin1Char('/') + liveName));
    QVERIFY(!QFileInfo::exists(base + QLatin1Char('/') + deadName));
    QVERIFY(QFileInfo::exists(base + QLatin1Char('/') + bogusName));
}

QTEST_GUILESS_MAIN(ClipboardLogicTest)

#include "clipboardlogic_test.moc"
