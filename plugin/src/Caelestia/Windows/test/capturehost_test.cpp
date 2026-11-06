#include "../capturehost.hpp"

#include <qcoreapplication.h>
#include <qfile.h>
#include <qjsondocument.h>
#include <qpointer.h>
#include <qprocess.h>
#include <qqmlcomponent.h>
#include <qqmlcontext.h>
#include <qqmlengine.h>
#include <qsignalspy.h>
#include <qtemporarydir.h>
#include <QtTest/QtTest>

using namespace caelestia::shell::windows;

namespace {
const QString hostClass = QStringLiteral("FixtureHost");
QString image() { return QCoreApplication::applicationFilePath(); }
QString state(CaptureHostRegistry& registry) { return registry.snapshot().value(QStringLiteral("state")).toString(); }
bool owned(CaptureHostRegistry& registry) { return registry.snapshot().value(QStringLiteral("owned")).toBool(); }

class FakeHostOps final : public CaptureHostOps {
public:
    CaptureProbe::Kind kind = CaptureProbe::Verified;
    CaptureIdentity identity;
    CaptureStatus response{true, false, QStringLiteral("42-fixture"), QStringLiteral("idle")};
    bool match = true;
    bool busyWindow = false;
    bool postResult = true;
    bool launchResult = true;
    bool startupInvisible = false;
    int posts = 0;
    int launches = 0;
    int reads = 0;
    int statusDelay = 0;
    std::function<void()> exitCallback;
    QPointer<QObject> watchContext;
    FakeHostOps() {
        identity = {42, 100, 1, image(), {}, std::shared_ptr<void>(new int, [](void* p) { delete static_cast<int*>(p); })};
    }
    CaptureProbe probe(const QString&, const QString&) override { return {kind, identity}; }
    bool matches(const CaptureIdentity& candidate, const QString&) override {
        return match && candidate.pid == identity.pid && candidate.created == identity.created;
    }
    bool hasCaptureWindow(const CaptureIdentity&) override { return busyWindow; }
    bool postClose(const CaptureIdentity&) override { ++posts; return postResult; }
    bool launch(const QString&, const QStringList&, CaptureIdentity& child) override {
        ++launches;
        if (kind == CaptureProbe::Absent) {
            kind = startupInvisible ? CaptureProbe::Absent : CaptureProbe::Verified;
            ++identity.pid;
            ++identity.created;
            if (!startupInvisible)
                response = {true, false, QString::number(identity.pid) + QStringLiteral("-fixture"), QStringLiteral("idle")};
            child = identity;
        }
        return launchResult;
    }
    void status(const QString&, QObject* context, std::function<void(CaptureStatus)> complete) override {
        ++reads;
        const auto result = response;
        QTimer::singleShot(statusDelay, context, [complete, result] { complete(result); });
    }
    QObject* watch(const CaptureIdentity&, QObject* context, std::function<void()> exited) override {
        auto* token = new QObject(context);
        watchContext = token;
        exitCallback = std::move(exited);
        return token;
    }
    void exit() {
        kind = CaptureProbe::Absent;
        response = {false, true, {}, {}};
        match = true;
        if (watchContext)
            exitCallback();
    }
};

CaptureHostRegistry* qmlRegistry = nullptr;
class FixtureCaptureHost : public CaptureHost {
    Q_OBJECT
public:
    explicit FixtureCaptureHost(QObject* parent = nullptr) : CaptureHost(qmlRegistry, parent) {}
};

void write(const QString& path, const QByteArray& text) {
    QVERIFY(QDir().mkpath(QFileInfo(path).absolutePath()));
    QFile file(path);
    QVERIFY(file.open(QIODevice::WriteOnly));
    QCOMPARE(file.write(text), text.size());
}

// Only dependencies are faked. Both production singleton files are copied
// byte-for-byte and parsed/executed by the actual offscreen QQmlEngine.
void stageQml(const QString& root) {
    const auto source = QString::fromUtf8(CAPTURE_SERVICE_DIR);
    for (const auto& name : {QStringLiteral("Glazier"), QStringLiteral("Recorder")}) {
        QVERIFY(QDir().mkpath(root + QStringLiteral("/qs/services")));
        QVERIFY(QFile::copy(source + QLatin1Char('/') + name + QStringLiteral(".qml"),
            root + QStringLiteral("/qs/services/") + name + QStringLiteral(".qml")));
    }
    write(root + QStringLiteral("/qs/services/qmldir"),
        "module qs.services\nsingleton Glazier 1.0 Glazier.qml\nsingleton Recorder 1.0 Recorder.qml\n"
        "singleton Screens 1.0 Screens.qml\nsingleton ShellState 1.0 ShellState.qml\nsingleton Toaster 1.0 Toaster.qml\n");
    write(root + QStringLiteral("/qs/services/Screens.qml"),
        "pragma Singleton\nimport QtQml\nQtObject { property var screens: [] }\n");
    write(root + QStringLiteral("/qs/services/ShellState.qml"),
        "pragma Singleton\nimport QtQml\nQtObject { function forScreen(s) { return null } function componentsFor(s) { return null } }\n");
    write(root + QStringLiteral("/qs/services/Toaster.qml"),
        "pragma Singleton\nimport QtQml\nQtObject { function toast(a,b,c) {} }\n");
    write(root + QStringLiteral("/qs/utils/qmldir"), "module qs.utils\nsingleton Paths 1.0 Paths.qml\n");
    write(root + QStringLiteral("/qs/utils/Paths.qml"),
        "pragma Singleton\nimport QtQml\nQtObject { property string state: fixtureRoot }\n");
    write(root + QStringLiteral("/Quickshell/qmldir"),
        "module Quickshell\nSingleton 1.0 Singleton.qml\nsingleton Quickshell 1.0 Quickshell.qml\n");
    write(root + QStringLiteral("/Quickshell/Singleton.qml"), "import QtQuick\nItem {}\n");
    write(root + QStringLiteral("/Quickshell/Quickshell.qml"), R"(
pragma Singleton
import QtQml
QtObject {
    property string shellDir: fixtureRoot + "/shell"
    property string stateDir: fixtureRoot
    function env(name) { return name === "CAELESTIA_COMBINED_LIVE" ? "1" : "" }
}
)");
    write(root + QStringLiteral("/Quickshell/Io/qmldir"),
        "module Quickshell.Io\nFileView 1.0 FileView.qml\nProcess 1.0 Process.qml\nStdioCollector 1.0 StdioCollector.qml\nIpcHandler 1.0 IpcHandler.qml\n");
    write(root + QStringLiteral("/Quickshell/Io/FileView.qml"), R"(
import QtQuick
Item {
    property string path
    property bool printErrors
    property bool watchChanges
    property bool atomicWrites
    signal loaded()
    signal loadFailed()
    signal fileChanged()
    function text() { return "" }
    function setText(t) {}
    function reload() {}
    Component.onCompleted: loadFailed()
}
)");
    write(root + QStringLiteral("/Quickshell/Io/Process.qml"),
        "import QtQuick\nItem { property var command: []; property bool running: false; property var stdout; signal exited(int code) }\n");
    write(root + QStringLiteral("/Quickshell/Io/StdioCollector.qml"),
        "import QtQml\nQtObject { signal streamFinished(); property string text: \"\" }\n");
    write(root + QStringLiteral("/Quickshell/Io/IpcHandler.qml"),
        "import QtQml\nQtObject { property string target }\n");
    write(root + QStringLiteral("/Quickshell/Windows/qmldir"), "module Quickshell.Windows\nsingleton FsUtils 1.0 FsUtils.qml\n");
    write(root + QStringLiteral("/Quickshell/Windows/FsUtils.qml"),
        "pragma Singleton\nimport QtQml\nQtObject { function classify(p) { return p === fixtureImage ? \"file\" : \"missing\" } }\n");
    write(root + QStringLiteral("/Caelestia/qmldir"), "module Caelestia\nFixtureStub 1.0 FixtureStub.qml\n");
    write(root + QStringLiteral("/Caelestia/FixtureStub.qml"), "import QtQml\nQtObject {}\n");
    write(root + QStringLiteral("/Caelestia/Windows/qmldir"),
        "module Caelestia.Windows\nsingleton WindowsFiles 1.0 WindowsFiles.qml\n");
    write(root + QStringLiteral("/Caelestia/Windows/WindowsFiles.qml"),
        "pragma Singleton\nimport QtQml\nQtObject { function isFile(p) { return p === fixtureImage } }\n");
}
}

class CaptureHostTests : public QObject {
    Q_OBJECT
private slots:
    void falsePostRetainsOwnership() {
        auto ops = std::make_shared<FakeHostOps>();
        CaptureHostRegistry registry(ops);
        const auto lease = registry.acquire(image(), hostClass, {});
        QTRY_COMPARE(state(registry), QStringLiteral("Owned"));
        ops->postResult = false;
        QVERIFY(registry.close(lease));
        QTRY_COMPARE(state(registry), QStringLiteral("CloseFailed"));
        QVERIFY(owned(registry));
        QCOMPARE(ops->posts, 1);
        QVERIFY(!registry.prepareReload(lease));
        registry.ensure(lease);
        QCOMPARE(ops->launches, 0);
    }
    void deniedAndForeign_data() {
        QTest::addColumn<int>("kind");
        QTest::newRow("access-denied") << int(CaptureProbe::Uncertain);
        QTest::newRow("foreign-image") << int(CaptureProbe::Foreign);
    }
    void deniedAndForeign() {
        QFETCH(int, kind);
        auto ops = std::make_shared<FakeHostOps>();
        ops->kind = CaptureProbe::Kind(kind);
        CaptureHostRegistry registry(ops);
        const auto lease = registry.acquire(image(), hostClass, {});
        QTRY_VERIFY(state(registry) != QStringLiteral("Probing"));
        QVERIFY(state(registry) != QStringLiteral("Owned"));
        QVERIFY(!registry.close(lease));
        QCOMPARE(ops->posts, 0);
        QCOMPARE(ops->launches, 0);
    }
    void identityChangesNeverMessage_data() {
        QTest::addColumn<bool>("reuse");
        QTest::newRow("reused-pid") << true;
        QTest::newRow("access-lost") << false;
    }
    void identityChangesNeverMessage() {
        QFETCH(bool, reuse);
        auto ops = std::make_shared<FakeHostOps>();
        CaptureHostRegistry registry(ops);
        const auto lease = registry.acquire(image(), hostClass, {});
        QTRY_COMPARE(state(registry), QStringLiteral("Owned"));
        if (reuse) ++ops->identity.created;
        else ops->match = false;
        QVERIFY(!registry.close(lease));
        QVERIFY(!registry.command(lease, {}));
        QCOMPARE(ops->posts, 0);
        QVERIFY(owned(registry));
    }
    void activeCloseRefused_data() {
        QTest::addColumn<QString>("phase");
        for (const auto& phase : {"selecting", "ready", "recording", "paused", "finalizing", "screenshot-window"})
            QTest::newRow(phase) << QString::fromLatin1(phase);
    }
    void activeCloseRefused() {
        QFETCH(QString, phase);
        auto ops = std::make_shared<FakeHostOps>();
        CaptureHostRegistry registry(ops);
        const auto lease = registry.acquire(image(), hostClass, {});
        QTRY_COMPARE(state(registry), QStringLiteral("Owned"));
        if (phase == QStringLiteral("screenshot-window")) ops->busyWindow = true;
        else ops->response.phase = phase;
        QVERIFY(registry.close(lease, true));
        QTRY_VERIFY(!registry.snapshot().value(QStringLiteral("error")).toString().isEmpty());
        QCOMPARE(state(registry), QStringLiteral("Owned"));
        QVERIFY(owned(registry));
        QCOMPARE(ops->posts, 0);
        QCOMPARE(ops->launches, 0);
    }
    void deadlineLateExitAndNewGeneration() {
        auto ops = std::make_shared<FakeHostOps>();
        CaptureHostRegistry registry(ops);
        registry.closeTimeoutMs = 25;
        const auto old = registry.acquire(image(), hostClass, {});
        QTRY_COMPARE(state(registry), QStringLiteral("Owned"));
        QVERIFY(registry.close(old, true));
        QTRY_COMPARE(state(registry), QStringLiteral("Closing"));
        const auto newest = registry.acquire(image(), hostClass, {});
        registry.release(old);
        QVERIFY(!registry.close(old));
        QVERIFY(!registry.command(newest, {}));
        QTRY_COMPARE(state(registry), QStringLiteral("CloseFailed"));
        QVERIFY(owned(registry));
        QCOMPARE(ops->launches, 0);
        ops->exit();
        QCOMPARE(state(registry), QStringLiteral("Exited"));
        QVERIFY(!owned(registry));
        QTRY_COMPARE(state(registry), QStringLiteral("Owned"));
        QCOMPARE(ops->launches, 1);
        QCOMPARE(ops->posts, 1);
    }
    void boundedCrashRecovery() {
        auto ops = std::make_shared<FakeHostOps>();
        CaptureHostRegistry registry(ops);
        registry.recoveryDelayMs = 1;
        registry.acquire(image(), hostClass, {});
        QTRY_COMPARE(state(registry), QStringLiteral("Owned"));
        for (int i = 0; i < 3; ++i) {
            ops->exit();
            QTRY_COMPARE(state(registry), QStringLiteral("Owned"));
        }
        ops->exit();
        QTest::qWait(20);
        QCOMPARE(state(registry), QStringLiteral("Exited"));
        QCOMPARE(ops->launches, 3);
    }
    void closeCheckSuperseded() {
        auto ops = std::make_shared<FakeHostOps>();
        CaptureHostRegistry registry(ops);
        const auto old = registry.acquire(image(), hostClass, {});
        QTRY_COMPARE(state(registry), QStringLiteral("Owned"));
        ops->statusDelay = 20;
        QVERIFY(registry.close(old));
        registry.acquire(image(), hostClass, {});
        QTest::qWait(40);
        QCOMPARE(ops->posts, 0);
        QCOMPARE(state(registry), QStringLiteral("Owned"));
    }
    void unhealthyHandoff_data() {
        QTest::addColumn<bool>("wrongHost");
        QTest::newRow("unresponsive") << false;
        QTest::newRow("wrong-host-id") << true;
    }
    void unhealthyHandoff() {
        QFETCH(bool, wrongHost);
        auto ops = std::make_shared<FakeHostOps>();
        CaptureHostRegistry registry(ops);
        const auto lease = registry.acquire(image(), hostClass, {});
        QTRY_COMPARE(state(registry), QStringLiteral("Owned"));
        if (wrongHost)
            ops->response.hostId = QStringLiteral("42-other-host");
        else
            ops->response.valid = false;
        QSignalSpy ready(&registry, &CaptureHostRegistry::reloadReady);
        QVERIFY(registry.prepareReload(lease));
        QTRY_COMPARE(ready.count(), 1);
        QVERIFY(!ready.first().at(1).toBool());
        QCOMPARE(state(registry), QStringLiteral("CloseFailed"));
        QVERIFY(owned(registry));
        QCOMPARE(ops->posts, 0);
        QCOMPARE(ops->launches, 0);
    }
    void exitDuringHandoffCompletesFailureAndAllowsRetry() {
        auto ops = std::make_shared<FakeHostOps>();
        CaptureHostRegistry registry(ops);
        registry.recoveryDelayMs = 1;
        const auto lease = registry.acquire(image(), hostClass, {});
        QTRY_COMPARE(state(registry), QStringLiteral("Owned"));
        ops->statusDelay = 30;
        QSignalSpy ready(&registry, &CaptureHostRegistry::reloadReady);
        QVERIFY(registry.prepareReload(lease));
        ops->exit();
        QCOMPARE(ready.count(), 1);
        QVERIFY(!ready.first().at(1).toBool());
        QTRY_COMPARE(state(registry), QStringLiteral("Owned"));
        QVERIFY(registry.prepareReload(lease));
        QTRY_COMPARE(ready.count(), 2);
        QVERIFY(ready.last().at(1).toBool());
        QCOMPARE(ops->posts, 0);
    }
    void startupDeadlineNeverDuplicates() {
        auto ops = std::make_shared<FakeHostOps>();
        ops->kind = CaptureProbe::Absent;
        ops->response = {false, true, {}, {}};
        ops->startupInvisible = true;
        CaptureHostRegistry registry(ops);
        registry.startupTimeoutMs = 25;
        const auto first = registry.acquire(image(), hostClass, {});
        QTRY_COMPARE(state(registry), QStringLiteral("CloseFailed"));
        QVERIFY(owned(registry));
        registry.release(first);
        const auto next = registry.acquire(image(), hostClass, {});
        registry.ensure(next);
        QTest::qWait(120);
        QCOMPARE(ops->launches, 1);
        QVERIFY(!registry.prepareReload(next));
        ops->startupInvisible = false;
        ops->exit();
        QTRY_COMPARE(state(registry), QStringLiteral("Owned"));
        QCOMPARE(ops->launches, 2);
    }
    void payloadChangeNeverRecoversRetiredImage() {
        auto ops = std::make_shared<FakeHostOps>();
        CaptureHostRegistry registry(ops);
        registry.recoveryDelayMs = 1;
        registry.acquire(image(), hostClass, {});
        QTRY_COMPARE(state(registry), QStringLiteral("Owned"));
        const auto next = registry.acquire(image() + QStringLiteral(".other-payload"), hostClass, {});
        QCOMPARE(state(registry), QStringLiteral("Foreign"));
        QVERIFY(owned(registry));
        QVERIFY(!registry.close(next));
        QVERIFY(!registry.prepareReload(next));
        ops->exit();
        QTest::qWait(20);
        QCOMPARE(state(registry), QStringLiteral("Exited"));
        QCOMPARE(ops->launches, 0);
    }
    void overlappingFacadeLeaseAndFreshness() {
        auto ops = std::make_shared<FakeHostOps>();
        ops->kind = CaptureProbe::Absent;
        ops->response = {false, true, {}, {}};
        CaptureHostRegistry registry(ops);
        auto old = std::make_unique<CaptureHost>(&registry);
        old->acquire(image(), hostClass, {});
        QTRY_COMPARE(state(registry), QStringLiteral("Owned"));
        QVERIFY(old->snapshot().value(QStringLiteral("launched")).toBool());
        CaptureHost newest(&registry);
        newest.acquire(image(), hostClass, {});
        QVERIFY(!newest.snapshot().value(QStringLiteral("launched")).toBool());
        QVERIFY(!old->prepareReload());
        QVERIFY(!old->close());
        old.reset();
        ops->response.phase = QStringLiteral("recording");
        QSignalSpy ready(&newest, &CaptureHost::reloadReady);
        QVERIFY(newest.prepareReload());
        QTRY_COMPARE(ready.count(), 1);
        QVERIFY(ready.first().first().toBool());
        QCOMPARE(ops->launches, 1);
        QCOMPARE(ops->posts, 0);
        QVERIFY(owned(registry));
    }
    void repeatedQmlGenerationsAndRecorderForwarding() {
        qmlRegisterType<FixtureCaptureHost>("Caelestia.Windows", 1, 0, "CaptureHost");
        auto ops = std::make_shared<FakeHostOps>();
        CaptureHostRegistry registry(ops);
        qmlRegistry = &registry;
        QTemporaryDir files;
        QVERIFY(files.isValid());
        stageQml(files.path());
        quint32 pid = 0;
        for (int i = 0; i < 4; ++i) {
            QQmlEngine engine;
            engine.addImportPath(files.path());
            engine.rootContext()->setContextProperty(QStringLiteral("fixtureRoot"), files.path());
            engine.rootContext()->setContextProperty(QStringLiteral("fixtureImage"), image());
            QQmlComponent component(&engine);
            component.setData(R"(
import QtQuick
import qs.services
Item {
    property var service: Glazier
    property var recorder: Recorder
    property int reloads: 0
    Component.onCompleted: {
        Glazier.configure(JSON.stringify({executable: fixtureImage}))
        Glazier.ensureLifecycle(fixtureImage)
    }
    function handoff() { return Glazier.prepareReload(() => { reloads++ }) }
    function startRecording() {
        Recorder.executable = fixtureImage
        Recorder.available = true
        Recorder.baselinePending = false
        Recorder.state = "idle"
        return Recorder.start()
    }
}
)", QUrl(QStringLiteral("file:///capture-lifecycle-fixture.qml")));
            QScopedPointer<QObject> root(component.create());
            QVERIFY2(root, qPrintable(component.errorString()));
            QTRY_COMPARE(state(registry), QStringLiteral("Owned"));
            if (!pid) pid = registry.snapshot().value(QStringLiteral("pid")).toUInt();
            QCOMPARE(registry.snapshot().value(QStringLiteral("pid")).toUInt(), pid);
            QVERIFY(!registry.snapshot().value(QStringLiteral("launched")).toBool());
            ops->response.phase = QStringLiteral("recording");
            QVariant result;
            QVERIFY(QMetaObject::invokeMethod(root.data(), "handoff", Q_RETURN_ARG(QVariant, result)));
            QVERIFY(result.toBool());
            QTRY_COMPARE(root->property("reloads").toInt(), 1);
            QCOMPARE(ops->posts, 0);
            if (i == 3) {
                ops->response.phase = QStringLiteral("idle");
                QVERIFY(QMetaObject::invokeMethod(root.data(), "startRecording", Q_RETURN_ARG(QVariant, result)));
                QVERIFY(result.toBool());
                QVERIFY(!registry.snapshot().value(QStringLiteral("launched")).toBool());
                QCOMPARE(ops->launches, 1); // Forwarding client only.
            } else {
                QCOMPARE(ops->launches, 0);
            }
        }
        QCOMPARE(ops->posts, 0);
        qmlRegistry = nullptr;
    }
    void realNativeLaunchAndHandoff() {
        const auto fixtureClass = QStringLiteral("CaelestiaCaptureFixture.launch.%1").arg(QCoreApplication::applicationPid());
        qputenv("CAELESTIA_CAPTURE_FIXTURE_CLASS", fixtureClass.toUtf8());
        qputenv("CAELESTIA_CAPTURE_FIXTURE_CLOSE_DELAY", "1");
        const auto childPath = QCoreApplication::applicationDirPath() + QStringLiteral("/capture-host-child.exe");
        auto ops = makeCaptureHostOps();
        struct Cleanup {
            std::shared_ptr<CaptureHostOps> ops;
            QString path, name;
            ~Cleanup() {
                const auto probe = ops->probe(path, name);
                if (probe.kind == CaptureProbe::Verified)
                    ops->postClose(probe.identity);
                qunsetenv("CAELESTIA_CAPTURE_FIXTURE_CLASS");
                qunsetenv("CAELESTIA_CAPTURE_FIXTURE_CLOSE_DELAY");
            }
        } cleanup{ops, childPath, fixtureClass};
        CaptureHostRegistry registry(ops);
        CaptureHost original(&registry);
        original.acquire(childPath, fixtureClass, {});
        QTRY_COMPARE(state(registry), QStringLiteral("Owned"));
        QVERIFY(original.snapshot().value(QStringLiteral("launched")).toBool());
        const auto identity = ops->probe(childPath, fixtureClass).identity;
        QVERIFY(identity.handle);
        QVERIFY(identity.created != 0);
        QSignalSpy ready(&original, &CaptureHost::reloadReady);
        QVERIFY(original.prepareReload());
        QTRY_COMPARE(ready.count(), 1);
        QVERIFY(ready.first().first().toBool());
        CaptureHost next(&registry);
        next.acquire(childPath, fixtureClass, {});
        QVERIFY(!next.snapshot().value(QStringLiteral("launched")).toBool());
        QCOMPARE(next.snapshot().value(QStringLiteral("pid")).toUInt(), identity.pid);
        QVERIFY(!original.close());
        QVERIFY(next.close());
        QTRY_COMPARE(state(registry), QStringLiteral("Exited"));
        QCOMPARE(ops->probe(childPath, fixtureClass).kind, CaptureProbe::Absent);
    }
    void realHiddenChildLateExitAndResponsiveness() {
        const auto fixtureClass = QStringLiteral("CaelestiaCaptureFixture.%1").arg(QCoreApplication::applicationPid());
        qputenv("CAELESTIA_CAPTURE_FIXTURE_CLASS", fixtureClass.toUtf8());
        qputenv("CAELESTIA_CAPTURE_FIXTURE_CLOSE_DELAY", "180");
        const auto childPath = QCoreApplication::applicationDirPath() + QStringLiteral("/capture-host-child.exe");
        QProcess child;
        child.setProgram(childPath);
        child.start();
        QVERIFY(child.waitForStarted(2000)); // Test setup, not production GUI close.
        auto ops = makeCaptureHostOps();
        QTRY_COMPARE(ops->probe(childPath, fixtureClass).kind, CaptureProbe::Verified);
        CaptureHostRegistry registry(ops);
        registry.closeTimeoutMs = 35;
        const auto old = registry.acquire(childPath, fixtureClass, {});
        QTRY_COMPARE(state(registry), QStringLiteral("Owned"));
        QVERIFY(!registry.snapshot().value(QStringLiteral("launched")).toBool());
        const auto original = ops->probe(childPath, fixtureClass).identity;
        QCOMPARE(ops->probe(image(), fixtureClass).kind, CaptureProbe::Foreign);
        auto reused = original;
        ++reused.created;
        QVERIFY(!ops->matches(reused, fixtureClass));
        QVERIFY(registry.command(old, {QStringLiteral("--fixture-forward")}));
        QVERIFY(!registry.snapshot().value(QStringLiteral("launched")).toBool());
        QCOMPARE(ops->probe(childPath, fixtureClass).identity.pid, original.pid);
        int ticks = 0;
        QTimer heartbeat;
        heartbeat.setInterval(2);
        connect(&heartbeat, &QTimer::timeout, this, [&] { ++ticks; });
        heartbeat.start();
        QVERIFY(registry.close(old));
        QTRY_COMPARE(state(registry), QStringLiteral("Closing"));
        registry.acquire(childPath, fixtureClass, {});
        registry.release(old);
        QTRY_COMPARE(state(registry), QStringLiteral("CloseFailed"));
        QVERIFY(owned(registry));
        QVERIFY(ticks >= 3);
        QTRY_COMPARE(state(registry), QStringLiteral("Exited"));
        QVERIFY(!owned(registry));
        QTRY_COMPARE(child.state(), QProcess::NotRunning);
        QCOMPARE(child.exitCode(), 0);
        QVERIFY(ticks >= 10);
        qunsetenv("CAELESTIA_CAPTURE_FIXTURE_CLASS");
        qunsetenv("CAELESTIA_CAPTURE_FIXTURE_CLOSE_DELAY");
    }
};

QTEST_MAIN(CaptureHostTests)
#include "capturehost_test.moc"
