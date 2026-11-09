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

} // namespace

class DragFileTest : public QObject {
    Q_OBJECT

private slots:
    void init() {
        QVERIFY(temp.isValid());
        root = temp.path();
    }

    void cleanup() { QDir(root).removeRecursively(); QDir().mkpath(root); }

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

private:
    QTemporaryDir temp;
    QString root;
};

QTEST_MAIN(DragFileTest)
#include "dragfile_test.moc"
