#include <atomic>
#include <chrono>
#include <condition_variable>
#include <memory>
#include <mutex>

#include <qcoreapplication.h>
#include <qdir.h>
#include <qelapsedtimer.h>
#include <qfile.h>
#include <qfileinfo.h>
#include <qhash.h>
#include <qsignalspy.h>
#include <qstring.h>
#include <qtemporarydir.h>
#include <qtest.h>
#include <qthread.h>
#include <qtimer.h>

#include <shlobj.h>

#include "../knownfolders.hpp"

namespace {

using namespace Qt::StringLiterals;
using caelestia::shell::windows::folderContainsImages;

// A probe the test controls: it blocks until released, like an enumeration of
// an unavailable network share. Shared with the detached worker, which can
// outlive the test function.
struct Gate {
    std::mutex mutex;
    std::condition_variable changed;
    bool entered = false;
    bool released = false;

    // Called by the probe: announces itself, then waits for release().
    bool block() {
        std::unique_lock lock(mutex);
        entered = true;
        changed.notify_all();
        changed.wait(lock, [&] { return released; });
        return true;
    }

    bool waitEntered() {
        std::unique_lock lock(mutex);
        return changed.wait_for(lock, std::chrono::seconds(10), [&] { return entered; });
    }

    void release() {
        {
            std::lock_guard lock(mutex);
            released = true;
        }
        changed.notify_all();
    }
};

bool writeFile(const QString& path) {
    QFile file(path);
    return file.open(QIODevice::WriteOnly) && file.write("x") == 1;
}

QString apiPath(REFKNOWNFOLDERID id) {
    // The caller must free the shell buffer, including when the call fails.
    struct CoTaskMemBuffer {
        PWSTR value = nullptr;

        ~CoTaskMemBuffer() { CoTaskMemFree(value); }
    } buffer;

    if (FAILED(SHGetKnownFolderPath(id, KF_FLAG_DONT_VERIFY, nullptr, &buffer.value)) || buffer.value == nullptr) {
        return {};
    }
    return QDir::fromNativeSeparators(QString::fromWCharArray(buffer.value));
}

} // namespace

class KnownFoldersTest : public QObject {
    Q_OBJECT

private slots:

    void picturesAndVideosMatchKnownFolderApi() {
        const auto pictures = apiPath(FOLDERID_Pictures);
        const auto videos = apiPath(FOLDERID_Videos);
        QVERIFY2(!pictures.isEmpty(), "Pictures Known Folder did not resolve");
        QVERIFY2(!videos.isEmpty(), "Videos Known Folder did not resolve");

        caelestia::shell::windows::KnownFolders folders;
        QVERIFY2(folders.pictures() == pictures, "Pictures does not come from SHGetKnownFolderPath");
        QVERIFY2(folders.videos() == videos, "Videos does not come from SHGetKnownFolderPath");
        QVERIFY2(QFileInfo(folders.pictures()).isAbsolute(), "Pictures is not an absolute path");
        QVERIFY2(QFileInfo(folders.videos()).isAbsolute(), "Videos is not an absolute path");
    }

    void startMenuMatchesKnownFolderApi() {
        const auto programs = apiPath(FOLDERID_Programs);
        const auto commonPrograms = apiPath(FOLDERID_CommonPrograms);
        QVERIFY2(!programs.isEmpty(), "Programs Known Folder did not resolve");
        QVERIFY2(!commonPrograms.isEmpty(), "CommonPrograms Known Folder did not resolve");

        caelestia::shell::windows::KnownFolders folders;
        QVERIFY2(folders.programs() == programs, "Programs does not come from SHGetKnownFolderPath");
        QVERIFY2(folders.commonPrograms() == commonPrograms, "CommonPrograms does not come from SHGetKnownFolderPath");
    }

    void auditedFoldersMatchKnownFolderApi() {
        caelestia::shell::windows::KnownFolders folders;
        QVERIFY2(folders.desktop() == apiPath(FOLDERID_Desktop), "Desktop does not come from SHGetKnownFolderPath");
        QVERIFY2(
            folders.documents() == apiPath(FOLDERID_Documents), "Documents does not come from SHGetKnownFolderPath");
        QVERIFY2(
            folders.downloads() == apiPath(FOLDERID_Downloads), "Downloads does not come from SHGetKnownFolderPath");
        QVERIFY2(folders.music() == apiPath(FOLDERID_Music), "Music does not come from SHGetKnownFolderPath");
    }

    void everyWallpaperExtensionCountsInAnyCase_data() {
        QTest::addColumn<QString>("name");
        for (const char* name : { "a.png", "a.PNG", "a.jpg", "a.JpG", "a.jpeg", "a.JPEG", "a.bmp", "a.BMP", "a.webp",
                 "a.WebP", "a.tar.png", "UPPER.Png" }) {
            QTest::newRow(name) << QString::fromLatin1(name);
        }
    }

    void everyWallpaperExtensionCountsInAnyCase() {
        QFETCH(QString, name);
        QTemporaryDir dir;
        QVERIFY(dir.isValid());
        QVERIFY(writeFile(dir.filePath(name)));
        QVERIFY2(folderContainsImages(dir.path()), qPrintable(name + u" was not detected"_s));
    }

    void otherFilesAndFoldersDoNotCount_data() {
        QTest::addColumn<QString>("name");
        for (const char* name : { "notes.txt", "png", "a.gif", "a.pngx", "a.png.txt", "a.jpg~", "noextension" })
            QTest::newRow(name) << QString::fromLatin1(name);
    }

    void otherFilesAndFoldersDoNotCount() {
        QFETCH(QString, name);
        QTemporaryDir dir;
        QVERIFY(dir.isValid());
        QVERIFY(writeFile(dir.filePath(name)));
        QVERIFY2(!folderContainsImages(dir.path()), qPrintable(name + u" was detected"_s));
    }

    void nestedAndImageNamedFoldersDoNotCount() {
        QTemporaryDir dir;
        QVERIFY(dir.isValid());
        // The scan is not recursive.
        QVERIFY(QDir(dir.path()).mkpath(QStringLiteral("nested")));
        QVERIFY(writeFile(dir.filePath(QStringLiteral("nested/deep.png"))));
        // A folder whose name looks like an image is not an image.
        QVERIFY(QDir(dir.path()).mkpath(QStringLiteral("a.png")));
        QVERIFY(QDir(dir.path()).mkpath(QStringLiteral("b.JPEG")));
        QVERIFY2(!folderContainsImages(dir.path()), "a nested image or an image-named folder was counted");

        QVERIFY(writeFile(dir.filePath(QStringLiteral("real.webp"))));
        QVERIFY2(folderContainsImages(dir.path()), "an image next to folders was not detected");
    }

    void missingEmptyAndUnusualFoldersAreFalse() {
        QTemporaryDir dir;
        QVERIFY(dir.isValid());
        QVERIFY(!folderContainsImages(dir.path()));
        QVERIFY(!folderContainsImages(dir.filePath(QStringLiteral("missing"))));
        QVERIFY(!folderContainsImages({}));
        QVERIFY(!folderContainsImages(QStringLiteral("   ")));

        // Trailing separators of either kind and native separators all work.
        QVERIFY(writeFile(dir.filePath(QStringLiteral("x.png"))));
        QVERIFY(folderContainsImages(dir.path() + u'/'));
        QVERIFY(folderContainsImages(QDir::toNativeSeparators(dir.path())));
        QVERIFY(folderContainsImages(QDir::toNativeSeparators(dir.path()) + u'\\'));
        // A file is not a folder.
        QVERIFY(!folderContainsImages(dir.filePath(QStringLiteral("x.png"))));
    }

    void normalizeKeepsDriveAndShareRoots_data() {
        QTest::addColumn<QString>("input");
        QTest::addColumn<QString>("expected");
        QTest::newRow("drive root") << u"D:/"_s << u"D:/"_s;
        QTest::newRow("drive root native") << u"D:\\"_s << u"D:/"_s;
        QTest::newRow("drive root repeated") << u"D://"_s << u"D:/"_s;
        QTest::newRow("drive root repeated native") << u"d:\\\\"_s << u"d:/"_s;
        QTest::newRow("drive root padded") << u"  E:/ "_s << u"E:/"_s;
        QTest::newRow("drive relative stays relative") << u"D:"_s << u"D:"_s;
        QTest::newRow("drive folder") << u"D:/Pictures/"_s << u"D:/Pictures"_s;
        QTest::newRow("drive folder native") << u"D:\\Pictures\\\\"_s << u"D:/Pictures"_s;
        QTest::newRow("share root") << u"//server/share/"_s << u"//server/share/"_s;
        QTest::newRow("share root native") << u"\\\\server\\share\\"_s << u"//server/share/"_s;
        QTest::newRow("share root repeated") << u"//server/share//"_s << u"//server/share/"_s;
        QTest::newRow("share folder") << u"//server/share/Pictures/"_s << u"//server/share/Pictures"_s;
        QTest::newRow("share folder native") << u"\\\\server\\share\\Pictures\\"_s << u"//server/share/Pictures"_s;
        // Qt drops the extended-length prefix; the root keeps its separator.
        QTest::newRow("extended drive root") << u"\\\\?\\C:\\"_s << u"C:/"_s;
        QTest::newRow("bare separator") << u"/"_s << u"/"_s;
        QTest::newRow("bare native separator") << u"\\"_s << u"/"_s;
        QTest::newRow("repeated bare separators") << u"///"_s << u"/"_s;
        QTest::newRow("rooted folder") << u"/Users/x/"_s << u"/Users/x"_s;
        QTest::newRow("plain folder") << u"C:/Users/x/"_s << u"C:/Users/x"_s;
        QTest::newRow("no separator") << u"C:/Users/x"_s << u"C:/Users/x"_s;
    }

    void normalizeKeepsDriveAndShareRoots() {
        QFETCH(QString, input);
        QFETCH(QString, expected);
        QCOMPARE(caelestia::shell::windows::normalizeFolderPath(input), expected);
        // A configured override is normalised the same way.
        QCOMPARE(caelestia::shell::windows::resolveKnownFolder(FOLDERID_Pictures, input.trimmed().isEmpty() ? u"x"_s : input),
            expected);
        // And the QML-facing entry point agrees.
        QCOMPARE(caelestia::shell::windows::KnownFolders::normalizePath(input), expected);
    }

    void knownFoldersResolveOnce() {
        caelestia::shell::windows::KnownFolders first;
        const auto pictures = first.pictures();
        const auto downloads = first.downloads();
        QVERIFY(!pictures.isEmpty());

        // Probing, or any other activity, never re-resolves a folder.
        first.setImageProbe([](const QString&) { return true; });
        QSignalSpy spy(&first, &caelestia::shell::windows::KnownFolders::imagesProbed);
        first.probeImages(u"C:/anything"_s);
        QVERIFY(spy.wait(10000));
        QCOMPARE(first.pictures(), pictures);
        QCOMPARE(first.downloads(), downloads);

        caelestia::shell::windows::KnownFolders second;
        QCOMPARE(second.pictures(), pictures);
    }

    void probeRunsOffTheGuiThreadAndAnswersAsynchronously() {
        caelestia::shell::windows::KnownFolders folders;

        // A probe the test controls: it blocks until released, like an
        // enumeration of an unavailable network share.
        std::mutex mutex;
        std::condition_variable gate;
        bool released = false;
        std::atomic<int> calls = 0;
        std::atomic<bool> onGuiThread = true;
        const auto guiThread = QThread::currentThread();
        folders.setImageProbe([&](const QString& path) {
            ++calls;
            onGuiThread = QThread::currentThread() == guiThread;
            std::unique_lock lock(mutex);
            gate.wait(lock, [&] { return released; });
            return path.endsWith(u"yes"_s);
        });

        QSignalSpy spy(&folders, &caelestia::shell::windows::KnownFolders::imagesProbed);

        QElapsedTimer timer;
        timer.start();
        folders.probeImages(u"//offline/share/yes"_s);
        folders.probeImages(u"//offline/share/no"_s);
        QVERIFY2(timer.elapsed() < 1000, "probeImages blocked the GUI thread");

        // The GUI thread keeps running its event loop while the probes block.
        int ticks = 0;
        QTimer ticker;
        ticker.setInterval(10);
        connect(&ticker, &QTimer::timeout, this, [&] { ++ticks; });
        ticker.start();
        QTest::qWait(300);
        QVERIFY2(ticks >= 5, "the event loop was starved while probing");
        QCOMPARE(spy.count(), 0);

        {
            std::lock_guard lock(mutex);
            released = true;
        }
        gate.notify_all();

        QTRY_COMPARE_WITH_TIMEOUT(spy.count(), 2, 10000);
        QCOMPARE(calls.load(), 2);
        QVERIFY2(!onGuiThread, "the probe ran on the GUI thread");

        QHash<QString, bool> answers;
        for (const auto& args : spy)
            answers.insert(args.at(0).toString(), args.at(1).toBool());
        QCOMPARE(answers.value(u"//offline/share/yes"_s), true);
        QCOMPARE(answers.value(u"//offline/share/no"_s), false);
    }

    void probeResultAfterDestructionIsDropped() {
        // The worker outlives this function, so its state is shared with it.
        struct State {
            std::mutex mutex;
            std::condition_variable gate;
            bool released = false;
            bool entered = false;
        };
        const auto state = std::make_shared<State>();
        {
            auto folders = std::make_unique<caelestia::shell::windows::KnownFolders>();
            folders->setImageProbe([state](const QString&) {
                std::unique_lock lock(state->mutex);
                state->entered = true;
                state->gate.notify_all();
                state->gate.wait(lock, [&] { return state->released; });
                return true;
            });
            folders->probeImages(u"//offline/share"_s);
            std::unique_lock lock(state->mutex);
            QVERIFY(state->gate.wait_for(lock, std::chrono::seconds(10), [&] { return state->entered; }));
        }
        // The object is gone while its probe is still blocked: destroying it
        // did not wait for the probe, and the late answer is discarded.
        {
            std::lock_guard lock(state->mutex);
            state->released = true;
        }
        state->gate.notify_all();
        QTest::qWait(200);
        QCoreApplication::processEvents();
    }

    void probeAfterApplicationShutdownBeginsIsNotDelivered() {
        // The backend deletes the application right after aboutToQuit. A probe
        // still blocked at that point must neither be waited for nor deliver
        // anything when it finally completes.
        const auto gate = std::make_shared<Gate>();
        caelestia::shell::windows::KnownFolders folders;
        folders.setImageProbe([gate](const QString&) { return gate->block(); });
        QSignalSpy spy(&folders, &caelestia::shell::windows::KnownFolders::imagesProbed);

        folders.probeImages(u"//offline/shutdown"_s);
        QVERIFY(gate->waitEntered());

        // The signal is private to Qt, so emit it by name.
        QVERIFY(QMetaObject::invokeMethod(QCoreApplication::instance(), "aboutToQuit", Qt::DirectConnection));

        QElapsedTimer timer;
        timer.start();
        gate->release();
        QTest::qWait(300);
        QCoreApplication::processEvents();
        QCOMPARE(spy.count(), 0);
        QVERIFY2(timer.elapsed() < 5000, "shutdown waited for the probe");
    }

    void probeThatCompletesDuringTeardownNeverTouchesFreedMemory() {
        // Race the worker's post against destruction of the receiver. Every
        // round uses its own path, so no round joins another's probe.
        for (int i = 0; i < 300; ++i) {
            auto folders = std::make_unique<caelestia::shell::windows::KnownFolders>();
            folders->setImageProbe([](const QString&) { return true; });
            folders->probeImages(u"//race/%1"_s.arg(i));
            if (i % 3 == 0)
                QCoreApplication::processEvents();
            if (i % 7 == 0)
                QThread::yieldCurrentThread();
            folders.reset();
        }
        QTest::qWait(200);
        QCoreApplication::processEvents();
    }

    void requestsForOneFolderShareASingleProbe() {
        const auto gate = std::make_shared<Gate>();
        const auto calls = std::make_shared<std::atomic<int>>(0);
        const auto probe = [gate, calls](const QString&) {
            ++*calls;
            return gate->block();
        };

        caelestia::shell::windows::KnownFolders first;
        caelestia::shell::windows::KnownFolders second;
        first.setImageProbe(probe);
        second.setImageProbe(probe);
        QSignalSpy firstSpy(&first, &caelestia::shell::windows::KnownFolders::imagesProbed);
        QSignalSpy secondSpy(&second, &caelestia::shell::windows::KnownFolders::imagesProbed);

        // Repeated requests, case and trailing separator differences, and
        // another instance all join the pending probe.
        first.probeImages(u"//offline/hung/Walls"_s);
        QVERIFY(gate->waitEntered());
        for (int i = 0; i < 50; ++i)
            first.probeImages(u"//offline/hung/Walls"_s);
        first.probeImages(u"//OFFLINE/hung/walls/"_s);
        second.probeImages(u"//offline/hung/Walls"_s);

        QTest::qWait(100);
        QCOMPARE(calls->load(), 1);
        QCOMPARE(firstSpy.count(), 0);

        gate->release();
        QTRY_COMPARE_WITH_TIMEOUT(firstSpy.count(), 52, 10000);
        QTRY_COMPARE_WITH_TIMEOUT(secondSpy.count(), 1, 10000);
        QCOMPARE(calls->load(), 1);
        // Each requester gets the path it asked with.
        QCOMPARE(firstSpy.last().at(0).toString(), u"//OFFLINE/hung/walls/"_s);
        QCOMPARE(firstSpy.last().at(1).toBool(), true);

        // Once answered, the folder can be probed again.
        first.probeImages(u"//offline/hung/Walls"_s);
        QTRY_COMPARE_WITH_TIMEOUT(firstSpy.count(), 53, 10000);
        QCOMPARE(calls->load(), 2);
    }

    void explicitOverrideWins() {
        QTemporaryDir dir;
        QVERIFY(dir.isValid());
        const auto configured = QDir::fromNativeSeparators(dir.path());
        QVERIFY2(configured != apiPath(FOLDERID_Pictures), "the override does not differ from the system default");

        using caelestia::shell::windows::resolveKnownFolder;
        QVERIFY2(resolveKnownFolder(FOLDERID_Pictures, configured) == configured,
            "a configured path did not win over the Known Folder");
        QVERIFY2(resolveKnownFolder(FOLDERID_Pictures, QDir::toNativeSeparators(dir.path())) == configured,
            "a native configured path did not win over the Known Folder");
        QVERIFY2(resolveKnownFolder(FOLDERID_Pictures, configured + u'/') == configured,
            "a trailing slash was not normalized");
        QVERIFY2(resolveKnownFolder(FOLDERID_Pictures) == apiPath(FOLDERID_Pictures),
            "an absent override did not fall back to the Known Folder");
    }
};

QTEST_GUILESS_MAIN(KnownFoldersTest)

#include "knownfolders_test.moc"
