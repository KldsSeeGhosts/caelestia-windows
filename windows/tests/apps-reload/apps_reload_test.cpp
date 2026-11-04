#include <memory>

#include <QGuiApplication>
#include <QPointer>
#include <QQmlComponent>
#include <QQmlEngine>
#include <QQmlExpression>
#include <QSignalSpy>
#include <QTest>

// Only the native boundary is fake. Both engines load the unmodified production
// NativeAppCatalog and AppsService, sharing a process-owned model just like
// DesktopEntryManager. Nothing scans installed apps, launches or uses the desktop.
class AppModel : public QObject {
    Q_OBJECT
    Q_PROPERTY(QVariantList values MEMBER values NOTIFY valuesChanged)

public:
    QVariantList values;

signals:
    void valuesChanged();
};

class AppProvider : public QObject {
    Q_OBJECT

public:
    AppModel model;
    int scans = 0;

    void completeScan(const QVariantList& values) {
        ++scans;
        model.values = values;
        emit model.valuesChanged();
        emit applicationsChanged();
    }

    int subscribers() const { return receivers(SIGNAL(applicationsChanged())); }

signals:
    void applicationsChanged();
};

class DesktopEntries : public QObject {
    Q_OBJECT
    Q_PROPERTY(QObject* applications READ applications CONSTANT)

public:
    explicit DesktopEntries(AppProvider* provider) : provider(provider) {
        connect(provider, &AppProvider::applicationsChanged,
                this, &DesktopEntries::applicationsChanged);
    }

    QObject* applications() const { return &provider->model; }
    AppProvider* provider;

signals:
    void applicationsChanged();
};

static AppProvider* provider = nullptr;
static QList<QPointer<DesktopEntries>> facades;

class AppsReloadTest : public QObject {
    Q_OBJECT

private slots:
    void initTestCase() {
        qmlRegisterSingletonType<DesktopEntries>(
            "Quickshell", 1, 0, "DesktopEntries",
            [](QQmlEngine*, QJSEngine*) -> QObject* {
                auto* facade = new DesktopEntries(provider);
                facades.append(facade);
                return facade;
            });
    }

    void overlappingGenerations() {
        AppProvider shared;
        provider = &shared;
        QQmlEngine::setObjectOwnership(&shared.model, QQmlEngine::CppOwnership);
        const QVariantList apps {
            QVariantMap {{"id", "alpha"}, {"name", "Alpha"}},
            QVariantMap {{"id", "beta"}, {"name", "Beta"}},
            QVariantMap {{"id", "gamma"}, {"name", "Gamma"}},
        };

        auto firstEngine = std::make_unique<QQmlEngine>();
        auto first = createService(firstEngine.get());
        QVERIFY(first);
        QCOMPARE(first->property("status").toString(), "scanning");
        QCOMPARE(first->property("count").toInt(), 0);
        shared.completeScan(apps);
        QCOMPARE(first->property("status").toString(), "ready");
        QCOMPARE(first->property("count").toInt(), 3);
        QCOMPARE(searchIds(firstEngine.get(), first.get()), "alpha,beta,gamma");

        // EngineGeneration::onReload constructs the replacement before destroying
        // the old root and engine. No scan or event-loop turn is allowed here.
        auto secondEngine = std::make_unique<QQmlEngine>();
        auto second = createService(secondEngine.get());
        QVERIFY(second);
        QCOMPARE(shared.scans, 1);
        QCOMPARE(shared.subscribers(), 2);
        QCOMPARE(second->property("count").toInt(), 3);
        QCOMPARE(second->property("status").toString(), "ready");
        QCOMPARE(searchIds(secondEngine.get(), second.get()), "alpha,beta,gamma");

        QPointer<QObject> retiredRoot = first.get();
        first.reset();
        firstEngine.reset();
        QVERIFY(retiredRoot.isNull());
        QVERIFY(facades.at(0).isNull());
        QCOMPARE(shared.subscribers(), 1);
        QCOMPARE(second->property("count").toInt(), 3);

        // Only the surviving engine receives subsequent changes. Empty scans
        // must still complete, rather than leaving the adapter in scanning.
        QSignalSpy changes(second.get(), SIGNAL(countChanged()));
        shared.completeScan({});
        QCOMPARE(changes.count(), 1);
        QCOMPARE(second->property("status").toString(), "empty");
        shared.completeScan(apps);
        QCOMPARE(second->property("count").toInt(), 3);
        QCOMPARE(changes.count(), 2);

        second.reset();
        secondEngine.reset();
        QVERIFY(facades.at(1).isNull());
        QCOMPARE(shared.subscribers(), 0);
        QCOMPARE(shared.model.values, apps);
        provider = nullptr;
    }

private:
    static std::unique_ptr<QObject> createService(QQmlEngine* engine) {
        QQmlComponent component(engine);
        const auto directory = QUrl::fromLocalFile(QStringLiteral(APPS_QML_DIR)).toString();
        component.setData(
            QString("import QtQuick\nimport \"%1\" as Apps\n"
                    "Apps.AppsService { enabled: true; catalog: Apps.NativeAppCatalog {} }")
                .arg(directory).toUtf8(),
            QUrl());
        std::unique_ptr<QObject> root(component.create());
        if (!root) qWarning() << component.errors();
        return root;
    }

    static QString searchIds(QQmlEngine* engine, QObject* service) {
        QQmlExpression expression(engine->rootContext(), service,
                                 "search('').map(entry => entry.id).join(',')");
        const auto result = expression.evaluate();
        if (expression.hasError()) qWarning() << expression.error();
        return result.toString();
    }
};

QTEST_MAIN(AppsReloadTest)
#include "apps_reload_test.moc"
