// Light logic tests for the clipboard worker helpers. These cover the
// decisions that previously failed silently: a non-Success
// SetHistoryItemAsContent status, a picker close that must invalidate a
// blocking history read or a queued snapshot, the per-instance cache delete
// boundary (including NTFS junctions swapped in before and after validation)
// and strict cache-root validation.

#include <qcoreapplication.h>
#include <qdir.h>
#include <qfile.h>
#include <qfileinfo.h>
#include <qprocess.h>
#include <qtemporarydir.h>

#include <QtTest/QtTest>
#include <string>

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

// mklink /J needs no elevation and creates a real NTFS junction. The cleanup
// must treat the reparse point itself as unsafe instead of resolving it.
bool makeJunction(const QString& link, const QString& target) {
    QProcess process;
    process.setProgram(QStringLiteral("cmd.exe"));
    process.setArguments({ QStringLiteral("/c"), QStringLiteral("mklink"), QStringLiteral("/J"),
        QDir::toNativeSeparators(link), QDir::toNativeSeparators(target) });
    process.setProcessChannelMode(QProcess::MergedChannels);
    process.start();
    if (!process.waitForFinished(15000))
        return false;
    if (process.exitStatus() != QProcess::NormalExit || process.exitCode() != 0)
        return false;
    return QFileInfo(link).isDir();
}

bool removeJunction(const QString& path) {
    // QDir::rmdir is RemoveDirectoryW: it removes the link, not the target.
    return QDir().rmdir(path);
}

} // namespace

class ClipboardLogicTest : public QObject {
    Q_OBJECT

private slots:
    void setContentStatus();
    void sessionStaysClosed();
    void sessionDeactivationIsImmediate();
    void sessionReopenInvalidatesStaleRead();
    void queuedSnapshotIsRejectedAfterClose();
    void invalidRootsAreRejected();
    void shutdownBeforeCacheRootDeletesNothing();
    void cleanupIsConfinedToTheInstanceDirectory();
    void liveSiblingCacheDirectorySurvives();
    void junctionInstanceDirectoryIsRefused();
    void junctionNestedDirectoryIsNotFollowed();
    void junctionClipboardParentIsRefused();
    void junctionSwappedForCacheEntryIsNotFollowed();
    void heldDeletionDoesNotFollowSwappedJunction();
    void heldDeletionRefusesReplacedEntry();
    void freshFilesNeverWriteThroughLinks();
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
    QVERIFY(session.acceptsSnapshot(read));

    // The GUI-side close updates the shared state directly; no queued
    // setActive(false) is needed before a late completion is rejected.
    session.deactivate();
    QVERIFY(!session.active());
    QVERIFY(!session.accepts(read));
    QVERIFY(!session.acceptsSnapshot(read));
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
    QVERIFY(!session.acceptsSnapshot(firstSession));

    const auto secondSession = session.nextRead();
    QVERIFY(session.accepts(secondSession));

    // A newer explicit refresh invalidates the older completion too.
    const auto newer = session.nextRead();
    QVERIFY(!session.accepts(secondSession));
    QVERIFY(session.accepts(newer));
}

void ClipboardLogicTest::queuedSnapshotIsRejectedAfterClose() {
    ClipboardSessionState session;
    int applied = 0;

    // Model the GUI connection: snapshotReady is queued and the facade applies
    // it only when the session still accepts its generation.
    const auto emitSnapshot = [this, &session, &applied](quint64 generation) {
        QMetaObject::invokeMethod(
            this,
            [&session, &applied, generation]() {
                if (session.acceptsSnapshot(generation))
                    ++applied;
            },
            Qt::QueuedConnection);
    };

    session.activate();
    const auto firstSession = session.nextRead();

    // Emitted while the picker is open, delivered after the close. Nothing may
    // be applied even though the signal was already queued.
    emitSnapshot(firstSession);
    session.deactivate();
    QCoreApplication::processEvents();
    QCOMPARE(applied, 0);

    // Reopening must not revive a snapshot from the previous session.
    session.activate();
    emitSnapshot(firstSession);
    QCoreApplication::processEvents();
    QCOMPARE(applied, 0);

    // The current session's snapshot is applied.
    const auto secondSession = session.nextRead();
    emitSnapshot(secondSession);
    QCoreApplication::processEvents();
    QCOMPARE(applied, 1);

    // A stop request rejects even the current generation.
    session.requestStop();
    emitSnapshot(secondSession);
    QCoreApplication::processEvents();
    QCOMPARE(applied, 1);
}

void ClipboardLogicTest::invalidRootsAreRejected() {
    QVERIFY(ClipboardCacheDirectory::validRoot(QStringLiteral("C:\\cache")));
    QVERIFY(ClipboardCacheDirectory::validRoot(QStringLiteral("C:/cache")));
    QVERIFY(ClipboardCacheDirectory::validRoot(QStringLiteral("C:/cache/nested")));
    QVERIFY(ClipboardCacheDirectory::validRoot(QStringLiteral("C:/cache/../cache")));
    QVERIFY(ClipboardCacheDirectory::validRoot(QStringLiteral("D:\\A B")));

    // Drive-relative, bare drive roots, UNC, device paths and relative paths.
    QVERIFY(!ClipboardCacheDirectory::validRoot(QStringLiteral("C:relative")));
    QVERIFY(!ClipboardCacheDirectory::validRoot(QStringLiteral("C:")));
    QVERIFY(!ClipboardCacheDirectory::validRoot(QStringLiteral("C:\\")));
    QVERIFY(!ClipboardCacheDirectory::validRoot(QStringLiteral("C:/")));
    QVERIFY(!ClipboardCacheDirectory::validRoot(QStringLiteral("C:\\cache\\..\\..")));
    QVERIFY(!ClipboardCacheDirectory::validRoot(QStringLiteral("\\\\server\\share")));
    QVERIFY(!ClipboardCacheDirectory::validRoot(QStringLiteral("\\\\?\\C:\\cache")));
    QVERIFY(!ClipboardCacheDirectory::validRoot(QStringLiteral("\\\\.\\C:\\cache")));
    QVERIFY(!ClipboardCacheDirectory::validRoot(QStringLiteral("relative/cache")));
    QVERIFY(!ClipboardCacheDirectory::validRoot(QStringLiteral("/cache")));
    QVERIFY(!ClipboardCacheDirectory::validRoot(QString()));

    QVERIFY(ClipboardCacheDirectory::normalizedRoot(QStringLiteral("C:relative")).isEmpty());
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
    for (const auto& name : { ownName, liveName, deadName, bogusName }) {
        QVERIFY(QDir().mkpath(base + QLatin1Char('/') + name));
        QVERIFY(writeSentinel(base + QLatin1Char('/') + name + QStringLiteral("/sentinel.txt")));
    }

    const auto removed = ClipboardCacheDirectory::removeDeadSiblings(root.path(), ownName, [](quint32 pid) {
        return pid == 1001;
    });
    QCOMPARE(removed, 1);

    QVERIFY(QFileInfo::exists(base + QLatin1Char('/') + ownName));
    QVERIFY(QFileInfo::exists(base + QLatin1Char('/') + liveName));
    QVERIFY(!QFileInfo::exists(base + QLatin1Char('/') + deadName));
    QVERIFY(QFileInfo::exists(base + QLatin1Char('/') + bogusName));
}

void ClipboardLogicTest::junctionInstanceDirectoryIsRefused() {
    QTemporaryDir root;
    QTemporaryDir outside;
    QVERIFY(root.isValid());
    QVERIFY(outside.isValid());
    QVERIFY(QDir().mkpath(root.filePath(QStringLiteral("clipboard"))));
    QVERIFY(writeSentinel(root.filePath(QStringLiteral("root-sentinel.txt"))));
    const auto outsideSentinel = outside.filePath(QStringLiteral("outside-sentinel.txt"));
    QVERIFY(writeSentinel(outsideSentinel));

    ClipboardCacheDirectory cache;
    QVERIFY(cache.configure(root.path(), 4242, 0x1234567890abcdefULL));
    QVERIFY(makeJunction(cache.path(), outside.path()));
    // Prove the link really is a junction/reparse point, independent of how Qt
    // classifies it.
    const auto junctionWide = QDir::toNativeSeparators(cache.path()).toStdWString();
    QVERIFY((GetFileAttributesW(junctionWide.c_str()) & FILE_ATTRIBUTE_REPARSE_POINT) != 0);

    QString error;
    QVERIFY(!cache.ensure(&error));
    QVERIFY(!error.isEmpty());
    QVERIFY(!error.contains(root.path()));
    QVERIFY(!cache.remove());
    QVERIFY(!cache.removeFile(cache.filePath(QStringLiteral("missing.txt"))));

    QVERIFY(QFileInfo::exists(outsideSentinel));
    QVERIFY(QFileInfo::exists(root.filePath(QStringLiteral("root-sentinel.txt"))));
    QVERIFY(removeJunction(cache.path()));
}

void ClipboardLogicTest::junctionNestedDirectoryIsNotFollowed() {
    QTemporaryDir root;
    QTemporaryDir outside;
    QVERIFY(root.isValid());
    QVERIFY(outside.isValid());
    QVERIFY(QDir().mkpath(root.filePath(QStringLiteral("clipboard"))));
    QVERIFY(QDir().mkpath(outside.filePath(QStringLiteral("deep"))));
    const auto outsideSentinel = outside.filePath(QStringLiteral("outside-sentinel.txt"));
    const auto deepSentinel = outside.filePath(QStringLiteral("deep/keep.txt"));
    QVERIFY(writeSentinel(outsideSentinel));
    QVERIFY(writeSentinel(deepSentinel));

    ClipboardCacheDirectory cache;
    QVERIFY(cache.configure(root.path(), 4242, 0x1234567890abcdefULL));
    QVERIFY(cache.ensure());
    QVERIFY(writeSentinel(cache.filePath(QStringLiteral("preview.png"))));
    QVERIFY(makeJunction(cache.path() + QStringLiteral("/nested"), outside.path()));

    // The flat file is deleted, but the junction is skipped and the non-empty
    // instance directory is refused rather than recursively removed.
    QVERIFY(!cache.remove());
    QVERIFY(!QFileInfo::exists(cache.filePath(QStringLiteral("preview.png"))));
    QVERIFY(QFileInfo::exists(cache.path() + QStringLiteral("/nested")));
    QVERIFY(QFileInfo::exists(outsideSentinel));
    QVERIFY(QFileInfo::exists(deepSentinel));

    QVERIFY(removeJunction(cache.path() + QStringLiteral("/nested")));
}

void ClipboardLogicTest::junctionClipboardParentIsRefused() {
    QTemporaryDir root;
    QTemporaryDir outside;
    QVERIFY(root.isValid());
    QVERIFY(outside.isValid());
    const auto outsideSentinel = outside.filePath(QStringLiteral("outside-sentinel.txt"));
    const auto deadName = QStringLiteral("1002-0000000000000003");
    QVERIFY(writeSentinel(outsideSentinel));
    QVERIFY(QDir().mkpath(outside.filePath(deadName)));
    const auto deadSentinel = outside.filePath(deadName + QStringLiteral("/sibling.txt"));
    QVERIFY(writeSentinel(deadSentinel));

    QVERIFY(makeJunction(root.filePath(QStringLiteral("clipboard")), outside.path()));

    ClipboardCacheDirectory cache;
    QVERIFY(cache.configure(root.path(), 4242, 0x1234567890abcdefULL));
    QString error;
    QVERIFY(!cache.ensure(&error));
    QVERIFY(!error.isEmpty());
    QVERIFY(!error.contains(root.path()));
    QVERIFY(!QFileInfo::exists(outside.filePath(cache.name())));
    QVERIFY(!cache.remove());

    // Dead-pid collection must apply the same parent check, so the junction's
    // target is never enumerated or deleted.
    const auto removed = ClipboardCacheDirectory::removeDeadSiblings(root.path(), cache.name(), [](quint32) {
        return false;
    });
    QCOMPARE(removed, 0);
    QVERIFY(QFileInfo::exists(outsideSentinel));
    QVERIFY(QFileInfo::exists(deadSentinel));

    QVERIFY(removeJunction(root.filePath(QStringLiteral("clipboard"))));
}

void ClipboardLogicTest::junctionSwappedForCacheEntryIsNotFollowed() {
    QTemporaryDir root;
    QTemporaryDir outside;
    QVERIFY(root.isValid());
    QVERIFY(outside.isValid());
    QVERIFY(QDir().mkpath(root.filePath(QStringLiteral("clipboard"))));
    QVERIFY(writeSentinel(root.filePath(QStringLiteral("root-sentinel.txt"))));
    const auto outsideSentinel = outside.filePath(QStringLiteral("outside-sentinel.txt"));
    QVERIFY(writeSentinel(outsideSentinel));

    ClipboardCacheDirectory cache;
    QVERIFY(cache.configure(root.path(), 4242, 0x1234567890abcdefULL));
    QVERIFY(cache.ensure());
    QVERIFY(writeSentinel(cache.filePath(QStringLiteral("preview.png"))));

    // Replace the already-validated instance directory with a junction to a
    // sibling target. Deletion must refuse it and leave the target untouched.
    QVERIFY(QDir(cache.path()).removeRecursively());
    QVERIFY(makeJunction(cache.path(), outside.path()));

    QVERIFY(!cache.remove());
    QVERIFY(!cache.removeFile(cache.filePath(QStringLiteral("outside-sentinel.txt"))));
    QVERIFY(QFileInfo::exists(outsideSentinel));
    QVERIFY(QFileInfo::exists(root.filePath(QStringLiteral("root-sentinel.txt"))));
    QVERIFY(QFileInfo::exists(cache.path()));

    QVERIFY(removeJunction(cache.path()));
}

void ClipboardLogicTest::heldDeletionDoesNotFollowSwappedJunction() {
    QTemporaryDir root;
    QTemporaryDir outside;
    QVERIFY(root.isValid());
    QVERIFY(outside.isValid());
    QVERIFY(QDir().mkpath(root.filePath(QStringLiteral("clipboard"))));
    const auto outsideSentinel = outside.filePath(QStringLiteral("outside-sentinel.txt"));
    QVERIFY(writeSentinel(outsideSentinel));

    ClipboardCacheDirectory cache;
    QVERIFY(cache.configure(root.path(), 4242, 0x1234567890abcdefULL));
    QVERIFY(cache.ensure());

    const auto moved = cache.path() + QStringLiteral("-moved");
    {
        // Validation happens here and holds the identity of the original
        // instance directory. A swap after this point must not redirect the
        // deletion.
        ClipboardCacheDeletion deletion;
        QCOMPARE(deletion.open(root.path(), cache.path()), ClipboardCacheDeletion::OpenResult::Opened);
        QVERIFY(QDir().rename(cache.path(), moved));
        QVERIFY(makeJunction(cache.path(), outside.path()));

        // The held directory object is deleted by handle, not the junction
        // target. The name may disappear immediately or when the last handle
        // closes; both are safe.
        QVERIFY(deletion.removeContents());
        QVERIFY(deletion.removeSelf());
        QVERIFY(QFileInfo::exists(cache.path()));
        QVERIFY(QFileInfo::exists(outsideSentinel));
    }
    QVERIFY(!QFileInfo::exists(moved));
    QVERIFY(QFileInfo::exists(cache.path()));
    QVERIFY(QFileInfo::exists(outsideSentinel));

    QVERIFY(removeJunction(cache.path()));
}

void ClipboardLogicTest::heldDeletionRefusesReplacedEntry() {
    QTemporaryDir root;
    QTemporaryDir outside;
    QVERIFY(root.isValid());
    QVERIFY(outside.isValid());
    QVERIFY(QDir().mkpath(root.filePath(QStringLiteral("clipboard"))));
    const auto outsideSentinel = outside.filePath(QStringLiteral("outside-sentinel.txt"));
    QVERIFY(writeSentinel(outsideSentinel));

    ClipboardCacheDirectory cache;
    QVERIFY(cache.configure(root.path(), 4242, 0x1234567890abcdefULL));
    QVERIFY(cache.ensure());
    QVERIFY(writeSentinel(cache.filePath(QStringLiteral("preview.png"))));

    ClipboardCacheDeletion deletion;
    QCOMPARE(deletion.open(root.path(), cache.path()), ClipboardCacheDeletion::OpenResult::Opened);

    const auto moved = cache.path() + QStringLiteral("-moved");
    QVERIFY(QDir().rename(cache.path(), moved));
    QVERIFY(makeJunction(cache.path(), outside.path()));
    // A same-named decoy in the junction target has a different file identity.
    QVERIFY(writeSentinel(outside.filePath(QStringLiteral("preview.png"))));

    QVERIFY(!deletion.removeContents());
    QVERIFY(!deletion.removeSelf());
    QVERIFY(QFileInfo::exists(outside.filePath(QStringLiteral("preview.png"))));
    QVERIFY(QFileInfo::exists(outsideSentinel));
    QVERIFY(QFileInfo::exists(moved + QStringLiteral("/preview.png")));

    QVERIFY(removeJunction(cache.path()));
    QVERIFY(QDir(moved).removeRecursively());
}

void ClipboardLogicTest::freshFilesNeverWriteThroughLinks() {
    QTemporaryDir root;
    QTemporaryDir outside;
    QVERIFY(root.isValid());
    QVERIFY(outside.isValid());
    const auto sentinel = outside.filePath(QStringLiteral("outside.txt"));
    QVERIFY(writeSentinel(sentinel));

    ClipboardCacheDirectory cache;
    QVERIFY(cache.configure(root.path(), 4242, 0x1234567890abcdefULL));
    QVERIFY(cache.ensure());

    // Hard links need no elevation and carry no reparse-point attribute. Plant
    // them at the predictable names the writers used before (stem.ext), so a
    // truncating open would have rewritten the outside file.
    const auto stem = QStringLiteral("clipboard-0123456789abcdef");
    for (const auto& name : { stem + QStringLiteral(".txt"), stem + QStringLiteral(".png") }) {
        const auto link = QDir::toNativeSeparators(cache.filePath(name)).toStdWString();
        QVERIFY(CreateHardLinkW(link.c_str(), QDir::toNativeSeparators(sentinel).toStdWString().c_str(), nullptr));
    }

    const QByteArray payload("synthetic content");
    const auto first = cache.writeFreshFile(stem, QStringLiteral("txt"), payload);
    const auto second = cache.writeFreshFile(stem, QStringLiteral("txt"), payload);
    QVERIFY(!first.isEmpty());
    QVERIFY(!second.isEmpty());
    QVERIFY(first != second);
    QVERIFY(first != cache.filePath(stem + QStringLiteral(".txt")));

    QFile written(first);
    QVERIFY(written.open(QIODevice::ReadOnly));
    QCOMPARE(written.readAll(), payload);
    written.close();

    QFile outsideFile(sentinel);
    QVERIFY(outsideFile.open(QIODevice::ReadOnly));
    QCOMPARE(outsideFile.readAll(), QByteArray("sentinel"));
    outsideFile.close();

    // Shutdown deletes the links (directory entries) but never the target.
    QVERIFY(cache.remove());
    QVERIFY(QFileInfo::exists(sentinel));
}

QTEST_GUILESS_MAIN(ClipboardLogicTest)

#include "clipboardlogic_test.moc"
