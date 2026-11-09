#include <qdir.h>
#include <qfile.h>
#include <qfileinfo.h>
#include <qprocess.h>
#include <qregularexpression.h>
#include <qtemporarydir.h>
#include <qtest.h>
#include <quuid.h>

#ifdef Q_OS_WIN
#include <qt_windows.h>
#endif

#include "../../dragfile.hpp"

namespace {

using namespace caelestia::shell;

const QString shotName = QStringLiteral("annotate-2026-11-08_09-05-03.png");

QString newId() {
    return QUuid::createUuid().toString(QUuid::Id128);
}

bool write(const QString& path, const QByteArray& bytes = "x") {
    QFile file(path);
    if (!file.open(QIODevice::WriteOnly))
        return false;
    file.write(bytes);
    return true;
}

// A directory junction, which is a reparse point that needs no privilege.
bool junction(const QString& link, const QString& target) {
#ifdef Q_OS_WIN
    QProcess process;
    process.start(QStringLiteral("cmd.exe"),
        { QStringLiteral("/c"), QStringLiteral("mklink"), QStringLiteral("/J"), QDir::toNativeSeparators(link),
            QDir::toNativeSeparators(target) });
    return process.waitForFinished(15000) && process.exitCode() == 0 && QFileInfo::exists(link);
#else
    return QFile::link(target, link);
#endif
}

// Removes a junction without touching its target.
void dropJunction(const QString& link) {
    QDir().rmdir(link);
    QFile::remove(link);
}

#ifdef Q_OS_WIN
// What another process could do between two steps: move the directory away and put
// a junction to `target` where it was. False when the directory could not be moved.
bool swapForJunction(const QString& directory, const QString& target) {
    const auto moved = directory + QStringLiteral(".moved");
    if (!MoveFileW(QDir::toNativeSeparators(directory).toStdWString().c_str(),
            QDir::toNativeSeparators(moved).toStdWString().c_str()))
        return false;
    return junction(directory, target);
}
#endif

using Step = dragfile::testing::Step;

} // namespace

class DragFileTest : public QObject {
    Q_OBJECT

private slots:
    void init() {
        QVERIFY(temp.isValid());
        root = temp.path();
    }

    void cleanup() {
        dragfile::testing::setHook({});
        QDir(root).removeRecursively();
        QDir().mkpath(root);
    }

    // The file sits alone in a directory of its own, with the name it was given.
    void createsOneFileInADirectoryOfItsOwn() {
        const auto path = dragfile::create(root, shotName);
        QVERIFY(!path.isEmpty());
        QVERIFY2(QRegularExpression(QStringLiteral("^") + QRegularExpression::escape(root)
                     + QStringLiteral("/caelestia-drag-[0-9a-f]{32}/") + QRegularExpression::escape(shotName)
                     + QStringLiteral("\\z"))
                     .match(path)
                     .hasMatch(),
            qPrintable(path));
        QVERIFY(QFileInfo(path).isFile());
        QCOMPARE(QFileInfo(path).size(), qint64(0));
        QVERIFY(!path.contains(QLatin1Char('\\')));

        const auto directory = QFileInfo(path).absolutePath();
        QCOMPARE(QDir(directory).entryList(QDir::AllEntries | QDir::NoDotAndDotDot | QDir::Hidden | QDir::System),
            QStringList{ shotName });
        QCOMPARE(QDir(root).entryList(QDir::AllEntries | QDir::NoDotAndDotDot).size(), 1);
        QVERIFY(!dragfile::isReparsePoint(directory));
    }

    // Two drags never share a directory, even for the same name.
    void everyCallGetsANewDirectory() {
        const auto a = dragfile::create(root, shotName);
        const auto b = dragfile::create(root, shotName);
        QVERIFY(!a.isEmpty() && !b.isEmpty());
        QVERIFY(QFileInfo(a).absolutePath() != QFileInfo(b).absolutePath());
        QVERIFY(QFileInfo(a).isFile() && QFileInfo(b).isFile());
    }

    void acceptsNormalScreenshotNames() {
        for (const auto& name : { shotName, QStringLiteral("annotate-x (2).png"), QStringLiteral("shot 20261108.png"),
                 QStringLiteral("a.b.png"), QStringLiteral("console.png"), QStringLiteral("com10.png") }) {
            QVERIFY2(dragfile::validName(name), qPrintable(name));
            const auto path = dragfile::create(root, name);
            QVERIFY2(!path.isEmpty() && path.endsWith(QLatin1Char('/') + name), qPrintable(name));
        }
    }

    // A name that could leave the directory, or that Windows treats specially,
    // is refused and leaves nothing behind.
    void refusesNamesThatAreNotOneFileName() {
        const QStringList bad = { QString(), QStringLiteral("a.jpg"), QStringLiteral("a"), QStringLiteral(".png"),
            QStringLiteral("../x.png"), QStringLiteral("..\\x.png"), QStringLiteral("a/b.png"), QStringLiteral("a\\b.png"),
            QStringLiteral("C:x.png"), QStringLiteral("x:y.png"), QStringLiteral("x.png:stream"),
            QStringLiteral("x*.png"), QStringLiteral("x?.png"), QStringLiteral("x\".png"), QStringLiteral("x<y.png"),
            QStringLiteral("x>y.png"), QStringLiteral("x|y.png"), QStringLiteral(" x.png"), QStringLiteral("x .png"),
            QStringLiteral("x..png"), QStringLiteral("x.PNG"), QStringLiteral("con.png"), QStringLiteral("NUL.png"),
            QStringLiteral("com1.png"), QStringLiteral("LPT9.png"), QStringLiteral("aux.png"),
            QStringLiteral("a\nb.png"), QStringLiteral("a\tb.png"), QString(QStringLiteral("a") + QChar(0) + QStringLiteral("b.png")),
            QString(117, QLatin1Char('a')) + QStringLiteral("a.png") /* 122 characters */ };
        for (const auto& name : bad) {
            QVERIFY2(!dragfile::validName(name), qPrintable(name));
            QVERIFY2(dragfile::create(root, name).isEmpty(), qPrintable(name));
        }
        QCOMPARE(QDir(root).entryList(QDir::AllEntries | QDir::NoDotAndDotDot).size(), 0);
    }

    void failsWithoutATempDirectory() {
        QVERIFY(dragfile::create(root + QStringLiteral("/missing"), shotName).isEmpty());
        QVERIFY(dragfile::create(QString(), shotName).isEmpty());
        // A file is not a directory.
        QVERIFY(write(root + QStringLiteral("/file")));
        QVERIFY(dragfile::create(root + QStringLiteral("/file"), shotName).isEmpty());
    }

    void removesTheFileAndItsDirectory() {
        const auto path = dragfile::create(root, shotName);
        QVERIFY(write(path, "image bytes"));
        const auto directory = QFileInfo(path).absolutePath();
        QVERIFY(dragfile::remove(root, path));
        QVERIFY(!QFileInfo::exists(path));
        QVERIFY(!QFileInfo::exists(directory));
        QCOMPARE(QDir(root).entryList(QDir::AllEntries | QDir::NoDotAndDotDot).size(), 0);
        // Again: the directory is already gone, which is the state it was asked for.
        QVERIFY(dragfile::remove(root, path));
    }

    // A directory that lost its file is removed too.
    void removesAnEmptyDirectory() {
        const auto path = dragfile::create(root, shotName);
        QVERIFY(QFile::remove(path));
        QVERIFY(dragfile::remove(root, path));
        QVERIFY(!QFileInfo::exists(QFileInfo(path).absolutePath()));
    }

    // Only the exact scheme is accepted. Each of these is refused and nothing in
    // the world changes.
    void refusesPathsOutsideTheScheme() {
        const auto path = dragfile::create(root, shotName);
        const auto directory = QFileInfo(path).absolutePath();
        const auto id = QFileInfo(directory).fileName().mid(15);
        QVERIFY(id.size() == 32);

        QVERIFY(write(root + QStringLiteral("/caelestia-clipboard-") + id + QStringLiteral(".png")));
        QVERIFY(write(root + QStringLiteral("/unrelated.png")));
        QVERIFY(QDir().mkpath(root + QStringLiteral("/other/caelestia-drag-") + id));
        const auto otherFile = root + QStringLiteral("/other/caelestia-drag-") + id + QStringLiteral("/") + shotName;
        QVERIFY(write(otherFile));
        QVERIFY(QDir().mkpath(root + QStringLiteral("/caelestia-drag-") + id.toUpper()));

        const QStringList refused = {
            // not the scheme at all
            QString(), root, root + QStringLiteral("/unrelated.png"),
            root + QStringLiteral("/caelestia-clipboard-") + id + QStringLiteral(".png"),
            // the scheme in another directory
            otherFile,
            // the directory itself, with and without a slash
            directory, directory + QStringLiteral("/"),
            // the id is not 32 lower case hex digits
            root + QStringLiteral("/caelestia-drag-") + id.mid(1) + QStringLiteral("/") + shotName,
            root + QStringLiteral("/caelestia-drag-") + id + QStringLiteral("0/") + shotName,
            root + QStringLiteral("/caelestia-drag-") + id.toUpper() + QStringLiteral("/") + shotName,
            root + QStringLiteral("/caelestia-drag-") + QStringLiteral("zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz/") + shotName,
            // a name the scheme does not allow
            directory + QStringLiteral("/readme.txt"), directory + QStringLiteral("/con.png"), directory + QStringLiteral("/"),
            // other spellings of the same path
            path + QStringLiteral("\n"), path + QStringLiteral(" "), QDir::toNativeSeparators(path),
            directory + QStringLiteral("/../") + QFileInfo(directory).fileName() + QStringLiteral("/") + shotName,
            root + QStringLiteral("/./caelestia-drag-") + id + QStringLiteral("/") + shotName,
        };
        for (const auto& candidate : refused) {
            if (candidate == QDir::toNativeSeparators(path) && candidate == path)
                continue; // not a different spelling on this platform
            QVERIFY2(!dragfile::remove(root, candidate), qPrintable(candidate));
        }

        // Everything is still where it was.
        QVERIFY(QFileInfo(path).isFile());
        QVERIFY(QFileInfo(otherFile).isFile());
        QVERIFY(QFileInfo(root + QStringLiteral("/unrelated.png")).isFile());
        QVERIFY(QFileInfo(root + QStringLiteral("/caelestia-clipboard-") + id + QStringLiteral(".png")).isFile());

        // And the real path, from another root, is outside the scheme too.
        QTemporaryDir elsewhere;
        QVERIFY(elsewhere.isValid());
        QVERIFY(!dragfile::remove(elsewhere.path(), path));
        QVERIFY(QFileInfo(path).isFile());
        QVERIFY(dragfile::remove(root, path));
    }

    // A path below the drag directory is not a drag file.
    void refusesANestedPath() {
        const auto path = dragfile::create(root, shotName);
        const auto directory = QFileInfo(path).absolutePath();
        QVERIFY(QDir().mkpath(directory + QStringLiteral("/sub")));
        const auto nested = directory + QStringLiteral("/sub/") + shotName;
        QVERIFY(write(nested));
        QVERIFY(!dragfile::remove(root, nested));
        QVERIFY(!dragfile::remove(root, directory + QStringLiteral("/sub")));
        QVERIFY(!dragfile::remove(root, directory + QStringLiteral("/sub/")));
        QVERIFY(QFileInfo(nested).isFile() && QFileInfo(path).isFile());
        // Nor is the real file removable while the extra directory is there.
        QVERIFY(!dragfile::remove(root, path));
        QVERIFY(QFileInfo(path).isFile() && QFileInfo(nested).isFile());
    }

    void refusesADirectoryWithAnExtraFile() {
        const auto path = dragfile::create(root, shotName);
        const auto directory = QFileInfo(path).absolutePath();
        QVERIFY(write(path, "image"));
        QVERIFY(write(directory + QStringLiteral("/notes.txt")));
        QVERIFY(!dragfile::remove(root, path));
        QVERIFY(QFileInfo(path).isFile());
        QCOMPARE(QFile(path).size(), qint64(5));
        QVERIFY(QFileInfo(directory + QStringLiteral("/notes.txt")).isFile());
    }

    // A non-empty directory that does not hold the expected file is not emptied.
    void refusesANonEmptyDirectoryWithoutTheFile() {
        const auto path = dragfile::create(root, shotName);
        const auto directory = QFileInfo(path).absolutePath();
        QVERIFY(QFile::remove(path));
        QVERIFY(write(directory + QStringLiteral("/other.png")));
        QVERIFY(!dragfile::remove(root, path));
        QVERIFY(QFileInfo(directory + QStringLiteral("/other.png")).isFile());
        QVERIFY(QFileInfo(directory).isDir());
    }

    void refusesAHiddenExtraEntry() {
        const auto path = dragfile::create(root, shotName);
        const auto directory = QFileInfo(path).absolutePath();
        const auto hidden = directory + QStringLiteral("/.hidden");
        QVERIFY(write(hidden));
#ifdef Q_OS_WIN
        QVERIFY(SetFileAttributesW(reinterpret_cast<LPCWSTR>(QDir::toNativeSeparators(hidden).utf16()),
            FILE_ATTRIBUTE_HIDDEN | FILE_ATTRIBUTE_SYSTEM));
#endif
        QVERIFY(!dragfile::remove(root, path));
        QVERIFY(QFileInfo(path).isFile() && QFileInfo(hidden).exists());
        // (Clean up: the fixture directory is removed with the temp dir.)
    }

    // A junction in place of the drag directory: refused, and the target is
    // never entered.
    void refusesAReparsePointDirectory() {
        const auto target = root + QStringLiteral("/target");
        QVERIFY(QDir().mkpath(target));
        QVERIFY(write(target + QStringLiteral("/") + shotName, "keep"));
        QVERIFY(write(target + QStringLiteral("/keep.txt"), "keep"));

        const auto link = root + QStringLiteral("/caelestia-drag-") + newId();
        QVERIFY2(junction(link, target), "the junction could not be made");
        QVERIFY(dragfile::isReparsePoint(link));

        QVERIFY(!dragfile::remove(root, link + QStringLiteral("/") + shotName));
        QVERIFY(QFileInfo(target + QStringLiteral("/") + shotName).isFile());
        QVERIFY(QFileInfo(target + QStringLiteral("/keep.txt")).isFile());
        dropJunction(link);
        QVERIFY(QFileInfo(target + QStringLiteral("/keep.txt")).isFile());
    }

    // A junction in place of the file, inside a real drag directory.
    void refusesAReparsePointFile() {
        const auto path = dragfile::create(root, shotName);
        const auto directory = QFileInfo(path).absolutePath();
        const auto target = root + QStringLiteral("/target");
        QVERIFY(QDir().mkpath(target));
        QVERIFY(write(target + QStringLiteral("/keep.txt"), "keep"));
        QVERIFY(QFile::remove(path));
        QVERIFY2(junction(path, target), "the junction could not be made");

        QVERIFY(!dragfile::remove(root, path));
        QVERIFY(QFileInfo(target + QStringLiteral("/keep.txt")).isFile());
        QVERIFY(QFileInfo(directory).isDir());
        dropJunction(path);
        QVERIFY(QFileInfo(target + QStringLiteral("/keep.txt")).isFile());
    }

    // A directory that is not a drag directory is never reached through the
    // remover, whatever it holds.
    void leavesOtherDirectoriesAlone() {
        const auto plain = root + QStringLiteral("/caelestia-clipboard-") + newId();
        QVERIFY(QDir().mkpath(plain));
        QVERIFY(write(plain + QStringLiteral("/") + shotName));
        QVERIFY(!dragfile::remove(root, plain + QStringLiteral("/") + shotName));
        QVERIFY(!dragfile::remove(root, plain));
        QVERIFY(QFileInfo(plain + QStringLiteral("/") + shotName).isFile());
    }

#ifdef Q_OS_WIN
    // The swap tests below use the test hook to change the file system at the exact
    // step where a race would, so they do not depend on timing.

    // Another process cannot move the drag directory away and put a junction in its
    // place once remove() holds it, so the delete cannot reach the junction's target.
    void removalPinsTheDirectoryAgainstASwap() {
        const auto path = dragfile::create(root, shotName);
        const auto directory = QFileInfo(path).absolutePath();
        const auto target = root + QStringLiteral("/target");
        QVERIFY(QDir().mkpath(target));
        QVERIFY(write(target + QStringLiteral("/") + shotName, "keep"));
        QVERIFY(write(target + QStringLiteral("/keep.txt"), "keep"));

        bool ran = false;
        bool swapped = true;
        dragfile::testing::setHook([&](Step step, const QString& dir) {
            if (step == Step::BeforeFileRemoval) {
                ran = true;
                swapped = swapForJunction(dir, target);
            }
        });
        const bool removed = dragfile::remove(root, path);
        dragfile::testing::setHook({});
        if (swapped)
            dropJunction(directory);

        QVERIFY(ran);
        QVERIFY2(QFileInfo(target + QStringLiteral("/") + shotName).isFile(), "a file outside the drag directory was deleted");
        QCOMPARE(QFile(target + QStringLiteral("/") + shotName).size(), qint64(4));
        QVERIFY(QFileInfo(target + QStringLiteral("/keep.txt")).isFile());
        QVERIFY2(!swapped, "the directory could be swapped while it was supposed to be held");
        QVERIFY(removed);
        QVERIFY(!QFileInfo::exists(directory));
    }

    // The same swap, between the file delete and the directory delete.
    void removalKeepsThePinUntilTheDirectoryIsGone() {
        const auto path = dragfile::create(root, shotName);
        const auto directory = QFileInfo(path).absolutePath();
        const auto target = root + QStringLiteral("/target");
        QVERIFY(QDir().mkpath(target));
        QVERIFY(write(target + QStringLiteral("/keep.txt"), "keep"));

        bool ran = false;
        bool swapped = true;
        dragfile::testing::setHook([&](Step step, const QString& dir) {
            if (step == Step::BeforeDirectoryRemoval) {
                ran = true;
                swapped = swapForJunction(dir, target);
            }
        });
        const bool removed = dragfile::remove(root, path);
        dragfile::testing::setHook({});
        if (swapped)
            dropJunction(directory);

        QVERIFY(ran);
        QVERIFY2(!swapped, "the directory could be swapped while it was supposed to be held");
        QVERIFY(QFileInfo(target + QStringLiteral("/keep.txt")).isFile());
        QVERIFY(removed);
        QVERIFY(!QFileInfo::exists(directory));
    }

    // A hard link to a file elsewhere, put in the file's place after the directory
    // was listed: deleting it would be deleting a name of someone else's file.
    void refusesAFileSwappedForAHardLink() {
        const auto path = dragfile::create(root, shotName);
        const auto directory = QFileInfo(path).absolutePath();
        const auto outside = root + QStringLiteral("/outside.txt");
        QVERIFY(write(outside, "keep"));

        bool linked = false;
        dragfile::testing::setHook([&](Step step, const QString& dir) {
            if (step == Step::BeforeFileRemoval) {
                linked = QFile::remove(dir + QStringLiteral("/") + shotName)
                    && CreateHardLinkW(QDir::toNativeSeparators(dir + QStringLiteral("/") + shotName).toStdWString().c_str(),
                        QDir::toNativeSeparators(outside).toStdWString().c_str(), nullptr);
            }
        });
        const bool removed = dragfile::remove(root, path);
        dragfile::testing::setHook({});

        QVERIFY(linked);
        QVERIFY(!removed);
        QVERIFY(QFileInfo(path).isFile());
        QVERIFY(QFileInfo(directory).isDir());
        QCOMPARE(QFile(outside).size(), qint64(4));
    }

    // A junction put in the file's place after the directory was listed.
    void refusesAFileSwappedForAJunction() {
        const auto path = dragfile::create(root, shotName);
        const auto directory = QFileInfo(path).absolutePath();
        const auto target = root + QStringLiteral("/target");
        QVERIFY(QDir().mkpath(target));
        QVERIFY(write(target + QStringLiteral("/keep.txt"), "keep"));

        bool swapped = false;
        dragfile::testing::setHook([&](Step step, const QString& dir) {
            if (step == Step::BeforeFileRemoval)
                swapped = QFile::remove(dir + QStringLiteral("/") + shotName)
                    && junction(dir + QStringLiteral("/") + shotName, target);
        });
        const bool removed = dragfile::remove(root, path);
        dragfile::testing::setHook({});

        QVERIFY(swapped);
        QVERIFY(!removed);
        QVERIFY(dragfile::isReparsePoint(path));
        QVERIFY(QFileInfo(target + QStringLiteral("/keep.txt")).isFile());
        QVERIFY(QFileInfo(directory).isDir());
        dropJunction(path);
        QVERIFY(QFileInfo(target + QStringLiteral("/keep.txt")).isFile());
    }

    // The temp root is swapped for a junction to a decoy after its final path was
    // resolved. The decoy holds a directory of the same name, which is a plain
    // directory, but its final path is not the expected one, so nothing is deleted.
    void refusesADirectoryWhoseFinalPathIsNotTheExpectedOne() {
        const auto realRoot = root + QStringLiteral("/tmproot");
        const auto decoy = root + QStringLiteral("/decoy");
        QVERIFY(QDir().mkpath(realRoot));
        const auto path = dragfile::create(realRoot, shotName);
        QVERIFY(!path.isEmpty());
        const auto name = QFileInfo(QFileInfo(path).absolutePath()).fileName();
        QVERIFY(QDir().mkpath(decoy + QStringLiteral("/") + name));
        const auto decoyFile = decoy + QStringLiteral("/") + name + QStringLiteral("/") + shotName;
        QVERIFY(write(decoyFile, "keep"));

        bool swapped = false;
        dragfile::testing::setHook([&](Step step, const QString&) {
            if (step == Step::AfterRootResolved)
                swapped = swapForJunction(realRoot, decoy);
        });
        const bool removed = dragfile::remove(realRoot, path);
        dragfile::testing::setHook({});
        if (swapped)
            dropJunction(realRoot);

        QVERIFY(swapped);
        QVERIFY(!removed);
        QCOMPARE(QFile(decoyFile).size(), qint64(4));
        QVERIFY(QFileInfo(realRoot + QStringLiteral(".moved/") + name + QStringLiteral("/") + shotName).isFile());
    }

    // A failed directory check on a new drag directory must roll back nothing. The
    // directory was swapped for a junction right after it was made, so the path now
    // names the junction's target, which holds a file of the same name.
    void rollbackAfterAFailedDirectoryCheckDeletesNothing() {
        const auto target = root + QStringLiteral("/target");
        QVERIFY(QDir().mkpath(target));
        QVERIFY(write(target + QStringLiteral("/") + shotName, "keep"));

        QString directory;
        bool swapped = false;
        dragfile::testing::setHook([&](Step step, const QString& dir) {
            if (step == Step::AfterDirectoryCreated) {
                directory = dir;
                swapped = swapForJunction(dir, target);
            }
        });
        const auto path = dragfile::create(root, shotName);
        dragfile::testing::setHook({});

        QVERIFY(swapped);
        const bool junctionStays = dragfile::isReparsePoint(directory);
        dropJunction(directory);
        QVERIFY(path.isEmpty());
        QVERIFY(junctionStays);
        QVERIFY(QFileInfo(target + QStringLiteral("/") + shotName).isFile());
        QCOMPARE(QFile(target + QStringLiteral("/") + shotName).size(), qint64(4));
    }

    // A file already in the new directory makes the exclusive create fail. The
    // rollback must not delete that file, which this call did not create.
    void rollbackAfterAFailedNewOnlyDeletesNothing() {
        QString directory;
        dragfile::testing::setHook([&](Step step, const QString& dir) {
            if (step == Step::BeforeFileCreated) {
                directory = dir;
                write(dir + QStringLiteral("/") + shotName, "planted");
            }
        });
        const auto path = dragfile::create(root, shotName);
        dragfile::testing::setHook({});

        QVERIFY(path.isEmpty());
        QVERIFY(!directory.isEmpty());
        QCOMPARE(QFile(directory + QStringLiteral("/") + shotName).size(), qint64(7));
    }

    // The new directory is held from the moment it was checked until the file exists,
    // so it cannot be swapped for a junction and receive the file elsewhere.
    void creationPinsTheDirectoryAgainstASwap() {
        const auto target = root + QStringLiteral("/target");
        QVERIFY(QDir().mkpath(target));
        QVERIFY(write(target + QStringLiteral("/keep.txt"), "keep"));

        QString directory;
        bool swapped = true;
        dragfile::testing::setHook([&](Step step, const QString& dir) {
            if (step == Step::BeforeFileCreated) {
                directory = dir;
                swapped = swapForJunction(dir, target);
            }
        });
        const auto path = dragfile::create(root, shotName);
        dragfile::testing::setHook({});
        if (swapped)
            dropJunction(directory);

        QVERIFY2(!QFileInfo::exists(target + QStringLiteral("/") + shotName), "the file was created outside the drag directory");
        QVERIFY2(!swapped, "the directory could be swapped while it was supposed to be held");
        QVERIFY(!path.isEmpty());
        QVERIFY(QFileInfo(path).isFile());
        QVERIFY(dragfile::remove(root, path));
    }

    // A temp root that is itself a junction works: its final path is resolved once
    // and the drag directory must resolve below it.
    void worksWhenTheTempRootIsAJunction() {
        const auto real = root + QStringLiteral("/real");
        const auto link = root + QStringLiteral("/link");
        QVERIFY(QDir().mkpath(real));
        QVERIFY2(junction(link, real), "the junction could not be made");

        const auto path = dragfile::create(link, shotName);
        QVERIFY(!path.isEmpty());
        QVERIFY(path.startsWith(link + QStringLiteral("/caelestia-drag-")));
        QVERIFY(QFileInfo(path).isFile());
        QCOMPARE(QDir(real).entryList(QDir::AllEntries | QDir::NoDotAndDotDot).size(), 1);
        QVERIFY(dragfile::remove(link, path));
        QCOMPARE(QDir(real).entryList(QDir::AllEntries | QDir::NoDotAndDotDot).size(), 0);
        dropJunction(link);
    }
#endif

private:
    QTemporaryDir temp;
    QString root;
};

QTEST_MAIN(DragFileTest)
#include "dragfile_test.moc"
