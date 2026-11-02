// Legacy per-monitor settings stay reachable when two identical monitors gain
// a collision suffix. The old monitors/<label> layer is copied, never moved or
// overwritten, and the new layer then owns its own file. The copy is driven
// only by explicit backend reservation metadata, never by string inference.

#include <qdir.h>
#include <qfile.h>
#include <qfileinfo.h>
#include <qjsondocument.h>
#include <qjsonobject.h>
#include <qtest.h>
#include <qtemporarydir.h>

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

bool copiedStateLayer(const QString& path, const QString& name) {
    const auto reservations = readReservations(path);
    for (auto it = reservations.begin(); it != reservations.end(); ++it) {
        const auto object = it.value().toObject();
        if (object.value(QStringLiteral("name")).toString().compare(name, Qt::CaseInsensitive) != 0)
            continue;
        for (const auto& entry : object.value(QStringLiteral("legacyCopied")).toArray())
            if (entry.toString() == QStringLiteral("state.json"))
                return true;
    }
    return false;
}

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
            LayerRegistry<TestRoot> layers(monitors, QStringLiteral("state.json"), &owner, metadata);
            auto* plain = layers.get(QStringLiteral("Generic Monitor"), nullptr);
            plain->load();
            QCOMPARE(plain->wallpaperPlaying(), false);

            auto* suffixed = layers.get(QStringLiteral("Generic Monitor (2)"), nullptr);
            suffixed->load();
            QCOMPARE(suffixed->wallpaperPlaying(), false);
            QCOMPARE(layers.nameFor(suffixed), QStringLiteral("Generic Monitor (2)"));
            QVERIFY(QFileInfo::exists(monitors + QStringLiteral("/Generic Monitor (2)/state.json")));
            QVERIFY(copiedStateLayer(metadata, QStringLiteral("Generic Monitor (2)")));
        }

        // Deleting the destination must not restore a copy on the next start:
        // the completed copy is recorded in the reservation.
        QVERIFY(QFile::remove(monitors + QStringLiteral("/Generic Monitor (2)/state.json")));
        {
            QObject owner;
            LayerRegistry<TestRoot> layers(monitors, QStringLiteral("state.json"), &owner, metadata);
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
        LayerRegistry<TestRoot> layers(monitors, QStringLiteral("state.json"), &owner, metadata);
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
        LayerRegistry<TestRoot> layers(monitors, QStringLiteral("state.json"), &owner, metadata);
        auto* suffixed = layers.get(QStringLiteral("Generic Monitor (2)"), nullptr);
        suffixed->load();
        QVERIFY(!copiedStateLayer(metadata, QStringLiteral("Generic Monitor (2)")));
    }
};

QTEST_GUILESS_MAIN(LayerRegistryTest)

#include "layerregistry_test.moc"
