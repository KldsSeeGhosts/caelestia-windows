// Legacy per-monitor settings stay reachable when two identical monitors gain
// a collision suffix. The old monitors/<label> layer is copied, never moved or
// overwritten, and the new layer then owns its own file. The copy is driven
// only by explicit backend reservation metadata, never by string inference.

#include <qdir.h>
#include <qfile.h>
#include <qfileinfo.h>
#include <qjsonarray.h>
#include <qjsondocument.h>
#include <qjsonobject.h>
#include <qtest.h>
#include <qtemporarydir.h>
#ifdef Q_OS_WIN
#include <qt_windows.h>
#endif

#include "layerregistry.hpp"
#include "rootnode.hpp"

using namespace caelestia::shell::settings;

class TestRoot: public RootNode {
    Q_OBJECT
    Q_PROPERTY(bool wallpaperPlaying READ wallpaperPlaying WRITE setWallpaperPlaying NOTIFY wallpaperPlayingChanged)

public:
    explicit TestRoot(const QString& path, TestRoot* fallback = nullptr, QObject* parent = nullptr)
        : RootNode(true, path, fallback, parent) {}

    [[nodiscard]] const Schema& schema() const override {
        static const auto annotated = [] {
            Schema::annotate(&TestRoot::staticMetaObject, QStringLiteral("wallpaperPlaying"),
                {.defaultValue = true});
            return true;
        }();
        Q_UNUSED(annotated);
        static const auto schema = Schema::build(&staticMetaObject, RootNode::staticMetaObject.propertyCount());
        return schema;
    }

    [[nodiscard]] bool wallpaperPlaying() const { return m_wallpaperPlaying; }
    void setWallpaperPlaying(bool value) {
        if (value == m_wallpaperPlaying)
            return;
        m_wallpaperPlaying = value;
        emit wallpaperPlayingChanged();
    }

signals:
    void wallpaperPlayingChanged();

private:
    bool m_wallpaperPlaying = true;
};

namespace {

void writeText(const QString& path, const QByteArray& content) {
    QDir().mkpath(QFileInfo(path).absolutePath());
    QFile file(path);
    QVERIFY(file.open(QIODevice::WriteOnly | QIODevice::Truncate));
    file.write(content);
    file.close();
}

void writeState(const QString& path, bool wallpaperPlaying) {
    writeText(path, QStringLiteral("{\"wallpaperPlaying\": %1}")
                        .arg(wallpaperPlaying ? QStringLiteral("true") : QStringLiteral("false"))
                        .toUtf8());
}

void writeReservation(
    const QString& path,
    const QString& id,
    const QString& name,
    const QString& legacyLabel = {}
) {
    auto reservation = QJsonObject();
    reservation.insert(QStringLiteral("name"), name);
    reservation.insert(QStringLiteral("label"), legacyLabel.isEmpty() ? name : legacyLabel);
    if (!legacyLabel.isEmpty())
        reservation.insert(QStringLiteral("legacyLabel"), legacyLabel);
    auto reservations = QJsonObject();
    reservations.insert(id, reservation);
    auto root = QJsonObject();
    root.insert(QStringLiteral("version"), 1);
    root.insert(QStringLiteral("reservations"), reservations);
    writeText(path, QJsonDocument(root).toJson(QJsonDocument::Indented));
}

// The real storage areas, as the singletons declare them.
const QString kPersistentArea = QStringLiteral("state/persistent");
const QString kRuntimeArea = QStringLiteral("state/runtime");
const QString kPersistentKey = QStringLiteral("state/persistent/state.json");
const QString kRuntimeKey = QStringLiteral("state/runtime/state.json");

bool copiedLayer(const QString& path, const QString& name, const QString& key = kPersistentKey) {
    const auto reservations = readReservations(path);
    for (auto it = reservations.begin(); it != reservations.end(); ++it) {
        const auto object = it.value().toObject();
        if (object.value(QStringLiteral("name")).toString().compare(name, Qt::CaseInsensitive) != 0)
            continue;
        for (const auto& entry : object.value(QStringLiteral("legacyCopied")).toArray())
            if (entry.toString() == key)
                return true;
    }
    return false;
}

#ifdef Q_OS_WIN
// Holds a file open for reading without sharing delete or write access, so
// replacing it (what a QSaveFile commit does) is refused while it is held.
class FileLock {
public:
    explicit FileLock(const QString& path)
        : m_handle(CreateFileW(
              reinterpret_cast<LPCWSTR>(path.utf16()),
              GENERIC_READ,
              FILE_SHARE_READ,
              nullptr,
              OPEN_EXISTING,
              FILE_ATTRIBUTE_NORMAL,
              nullptr
          )) {}
    ~FileLock() { release(); }
    [[nodiscard]] bool locked() const { return m_handle != INVALID_HANDLE_VALUE; }
    void release() {
        if (m_handle != INVALID_HANDLE_VALUE)
            CloseHandle(m_handle);
        m_handle = INVALID_HANDLE_VALUE;
    }

private:
    HANDLE m_handle;
};
#endif

} // namespace

class LayerRegistryTest: public QObject {
    Q_OBJECT

private slots:
    void suffixedScreenCopiesLegacyLayerOnce() {
        QTemporaryDir temp;
        QVERIFY(temp.isValid());
        const auto monitors = temp.path() + QStringLiteral("/monitors");
        const auto metadata = temp.path() + QStringLiteral("/screen-names.json");
        const auto legacyFile = monitors + QStringLiteral("/Generic Monitor/state.json");
        writeState(legacyFile, false);
        writeReservation(metadata, QStringLiteral("path:generic-b"), QStringLiteral("Generic Monitor (2)"),
            QStringLiteral("Generic Monitor"));

        {
            QObject owner;
            LayerRegistry<TestRoot> layers(monitors, kPersistentArea, QStringLiteral("state.json"), &owner, metadata);
            auto* plain = layers.get(QStringLiteral("Generic Monitor"), nullptr);
            plain->load();
            QCOMPARE(plain->wallpaperPlaying(), false);

            auto* suffixed = layers.get(QStringLiteral("Generic Monitor (2)"), nullptr);
            suffixed->load();
            QCOMPARE(suffixed->wallpaperPlaying(), false);
            QCOMPARE(layers.nameFor(suffixed), QStringLiteral("Generic Monitor (2)"));
            QVERIFY(QFileInfo::exists(monitors + QStringLiteral("/Generic Monitor (2)/state.json")));
            QVERIFY(copiedLayer(metadata, QStringLiteral("Generic Monitor (2)")));
        }

        // Deleting the destination must not restore a copy on the next start:
        // the completed copy is recorded in the reservation.
        QVERIFY(QFile::remove(monitors + QStringLiteral("/Generic Monitor (2)/state.json")));
        {
            QObject owner;
            LayerRegistry<TestRoot> layers(monitors, kPersistentArea, QStringLiteral("state.json"), &owner, metadata);
            auto* suffixed = layers.get(QStringLiteral("Generic Monitor (2)"), nullptr);
            suffixed->load();
            QVERIFY(!QFileInfo::exists(monitors + QStringLiteral("/Generic Monitor (2)/state.json")));
            QCOMPARE(suffixed->wallpaperPlaying(), true);
        }

        // The legacy file is untouched.
        QFile legacy(legacyFile);
        QVERIFY(legacy.open(QIODevice::ReadOnly));
        const auto content = QString::fromUtf8(legacy.readAll());
        QVERIFY(content.contains(QStringLiteral("\"wallpaperPlaying\": false")));
    }

    void genuineSuffixLabelNeverCopies() {
        QTemporaryDir temp;
        QVERIFY(temp.isValid());
        const auto monitors = temp.path() + QStringLiteral("/monitors");
        const auto metadata = temp.path() + QStringLiteral("/screen-names.json");
        writeState(monitors + QStringLiteral("/Other Monitor/state.json"), false);
        // A genuine label that merely looks like a generated suffix carries no
        // legacyLabel.
        writeReservation(metadata, QStringLiteral("path:other"), QStringLiteral("Other Monitor (2)"));

        QObject owner;
        LayerRegistry<TestRoot> layers(monitors, kPersistentArea, QStringLiteral("state.json"), &owner, metadata);
        auto* plain = layers.get(QStringLiteral("Other Monitor (2)"), nullptr);
        plain->load();
        QVERIFY(!QFileInfo::exists(monitors + QStringLiteral("/Other Monitor (2)/state.json")));
        QCOMPARE(plain->wallpaperPlaying(), true);
    }

    void missingLegacyLayerDoesNotFailOrMarkCopied() {
        QTemporaryDir temp;
        QVERIFY(temp.isValid());
        const auto monitors = temp.path() + QStringLiteral("/monitors");
        const auto metadata = temp.path() + QStringLiteral("/screen-names.json");
        writeReservation(metadata, QStringLiteral("path:generic-b"), QStringLiteral("Generic Monitor (2)"),
            QStringLiteral("Generic Monitor"));

        QObject owner;
        LayerRegistry<TestRoot> layers(monitors, kPersistentArea, QStringLiteral("state.json"), &owner, metadata);
        auto* suffixed = layers.get(QStringLiteral("Generic Monitor (2)"), nullptr);
        suffixed->load();
        QVERIFY(!copiedLayer(metadata, QStringLiteral("Generic Monitor (2)")));
    }

    void layersSharingAFileNameMigrateIndependently() {
        QTemporaryDir temp;
        QVERIFY(temp.isValid());
        // Persistent and runtime state both call their file state.json.
        const auto persistent = temp.path() + QStringLiteral("/state/monitors");
        const auto runtime = temp.path() + QStringLiteral("/runtime/monitors");
        const auto metadata = temp.path() + QStringLiteral("/screen-names.json");
        writeState(persistent + QStringLiteral("/Generic Monitor/state.json"), false);
        writeState(runtime + QStringLiteral("/Generic Monitor/state.json"), false);
        writeReservation(metadata, QStringLiteral("path:generic-b"), QStringLiteral("Generic Monitor (2)"),
            QStringLiteral("Generic Monitor"));
        const auto name = QStringLiteral("Generic Monitor (2)");

        QObject owner;
        {
            LayerRegistry<TestRoot> layers(persistent, kPersistentArea, QStringLiteral("state.json"), &owner, metadata);
            layers.get(name, nullptr);
        }
        QVERIFY(QFileInfo::exists(persistent + QStringLiteral("/Generic Monitor (2)/state.json")));
        QVERIFY(copiedLayer(metadata, name, kPersistentKey));
        QVERIFY(!copiedLayer(metadata, name, kRuntimeKey));

        // The completed persistent copy must not stop the runtime layer.
        {
            LayerRegistry<TestRoot> layers(runtime, kRuntimeArea, QStringLiteral("state.json"), &owner, metadata);
            layers.get(name, nullptr);
        }
        QVERIFY(QFileInfo::exists(runtime + QStringLiteral("/Generic Monitor (2)/state.json")));
        QVERIFY(copiedLayer(metadata, name, kPersistentKey));
        QVERIFY(copiedLayer(metadata, name, kRuntimeKey));

        // Each recorded copy is its own: deleting the destination does not bring it back.
        QVERIFY(QFile::remove(runtime + QStringLiteral("/Generic Monitor (2)/state.json")));
        {
            LayerRegistry<TestRoot> layers(runtime, kRuntimeArea, QStringLiteral("state.json"), &owner, metadata);
            layers.get(name, nullptr);
        }
        QVERIFY(!QFileInfo::exists(runtime + QStringLiteral("/Generic Monitor (2)/state.json")));
    }

    void unreadableMetadataIsNeverOverwrittenOrCopiedFrom() {
        QTemporaryDir temp;
        QVERIFY(temp.isValid());
        const auto monitors = temp.path() + QStringLiteral("/monitors");
        const auto metadata = temp.path() + QStringLiteral("/screen-names.json");
        writeState(monitors + QStringLiteral("/Generic Monitor/state.json"), false);
        const auto garbage = QByteArray("{ not json");
        writeText(metadata, garbage);

        QObject owner;
        LayerRegistry<TestRoot> layers(monitors, kPersistentArea, QStringLiteral("state.json"), &owner, metadata);
        layers.get(QStringLiteral("Generic Monitor (2)"), nullptr);

        QVERIFY(!QFileInfo::exists(monitors + QStringLiteral("/Generic Monitor (2)/state.json")));
        QFile file(metadata);
        QVERIFY(file.open(QIODevice::ReadOnly));
        QCOMPARE(file.readAll(), garbage);
    }

    void failedCompletionWriteKeepsTheCopyAndIsNotRetried() {
#ifndef Q_OS_WIN
        QSKIP("The legacy layer copy is a Windows migration.");
#else
        QTemporaryDir temp;
        QVERIFY(temp.isValid());
        const auto monitors = temp.path() + QStringLiteral("/monitors");
        const auto metadata = temp.path() + QStringLiteral("/screen-names.json");
        const auto legacyFile = monitors + QStringLiteral("/Generic Monitor/state.json");
        const auto copy = monitors + QStringLiteral("/Generic Monitor (2)/state.json");
        const auto name = QStringLiteral("Generic Monitor (2)");
        writeState(legacyFile, false);
        writeReservation(metadata, QStringLiteral("path:generic-b"), name, QStringLiteral("Generic Monitor"));
        QFile original(metadata);
        QVERIFY(original.open(QIODevice::ReadOnly));
        const auto before = original.readAll();
        original.close();

        QObject owner;
        {
            // The metadata file can be read, but not replaced.
            FileLock lock(metadata);
            QVERIFY(lock.locked());
            LayerRegistry<TestRoot> layers(monitors, kPersistentArea, QStringLiteral("state.json"), &owner, metadata);
            auto* suffixed = layers.get(name, nullptr);
            suffixed->load();
            // The copied settings stay in place and the layer uses them...
            QVERIFY(QFileInfo::exists(copy));
            QCOMPARE(suffixed->wallpaperPlaying(), false);
        }
        // ...nothing was half-recorded, and no temporary file was left behind.
        QVERIFY(!copiedLayer(metadata, name));
        QFile after(metadata);
        QVERIFY(after.open(QIODevice::ReadOnly));
        QCOMPARE(after.readAll(), before);
        after.close();
        QCOMPARE(QDir(temp.path()).entryList(QDir::Files), QStringList({QStringLiteral("screen-names.json")}));

        // The unrecorded copy is not repeated this session, even once the
        // destination is gone and the metadata is writable again.
        QVERIFY(QFile::remove(copy));
        {
            LayerRegistry<TestRoot> layers(monitors, kPersistentArea, QStringLiteral("state.json"), &owner, metadata);
            layers.get(name, nullptr);
        }
        QVERIFY(!QFileInfo::exists(copy));
        QVERIFY(!copiedLayer(metadata, name));
#endif
    }
};

QTEST_GUILESS_MAIN(LayerRegistryTest)

#include "layerregistry_test.moc"
