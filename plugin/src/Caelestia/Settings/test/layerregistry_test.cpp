// Legacy per-monitor settings stay reachable when two identical monitors gain
// a collision suffix. The old monitors/<label> layer is copied, never moved or
// overwritten, and the new layer then owns its own file.

#include <qdir.h>
#include <qfile.h>
#include <qfileinfo.h>
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

void writeState(const QString& path, bool wallpaperPlaying) {
    QDir().mkpath(QFileInfo(path).absolutePath());
    QFile file(path);
    QVERIFY(file.open(QIODevice::WriteOnly | QIODevice::Truncate));
    file.write(QStringLiteral("{\"wallpaperPlaying\": %1}")
                   .arg(wallpaperPlaying ? QStringLiteral("true") : QStringLiteral("false"))
                   .toUtf8());
    file.close();
}

} // namespace

class LayerRegistryTest: public QObject {
    Q_OBJECT

private slots:
    void suffixedScreenCopiesLegacyLayerOnce() {
        QTemporaryDir temp;
        QVERIFY(temp.isValid());
        const auto monitors = temp.path() + QStringLiteral("/monitors");
        const auto legacyDir = monitors + QStringLiteral("/Generic Monitor");
        const auto legacyFile = legacyDir + QStringLiteral("/state.json");
        writeState(legacyFile, false);

        QObject owner;
        LayerRegistry<TestRoot> layers(monitors, QStringLiteral("state.json"), &owner);
        auto* plain = layers.get(QStringLiteral("Generic Monitor"), nullptr);
        plain->load();
        QCOMPARE(plain->wallpaperPlaying(), false);

        // The second identical monitor used to share the plain label's layer.
        auto* suffixed = layers.get(QStringLiteral("Generic Monitor (2)"), nullptr);
        suffixed->load();
        QCOMPARE(suffixed->wallpaperPlaying(), false);
        QCOMPARE(layers.nameFor(suffixed), QStringLiteral("Generic Monitor (2)"));
        QVERIFY(QFileInfo::exists(monitors + QStringLiteral("/Generic Monitor (2)/state.json")));

        // The legacy file is untouched and the plain layer keeps its identity.
        QFile legacy(legacyFile);
        QVERIFY(legacy.open(QIODevice::ReadOnly));
        const auto content = QString::fromUtf8(legacy.readAll());
        QVERIFY(content.contains(QStringLiteral("\"wallpaperPlaying\": false")));
        QCOMPARE(layers.get(QStringLiteral("Generic Monitor"), nullptr), plain);
    }

    void realSuffixOrMissingLegacyDoesNotCopy() {
        QTemporaryDir temp;
        QVERIFY(temp.isValid());
        const auto monitors = temp.path() + QStringLiteral("/monitors");
        QObject owner;
        LayerRegistry<TestRoot> layers(monitors, QStringLiteral("state.json"), &owner);

        auto* plain = layers.get(QStringLiteral("Other Monitor (2)"), nullptr);
        plain->load();
        QVERIFY(QFileInfo(monitors + QStringLiteral("/Other Monitor (2)")).isDir());
        QVERIFY(!QFileInfo::exists(monitors + QStringLiteral("/Other Monitor/state.json")));
        QCOMPARE(plain->wallpaperPlaying(), true);
    }
};

QTEST_GUILESS_MAIN(LayerRegistryTest)

#include "layerregistry_test.moc"
