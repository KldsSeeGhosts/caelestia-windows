#include "../capturehost.hpp"

#include <windows.h>
#include <qcoreapplication.h>
#include <qfile.h>
#include <qjsondocument.h>
#include <qjsonobject.h>
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
    quint32 code = 1;
    QString windowClass = hostClass;
    struct Waits {
        QHash<void*, int> active;
        int unsafeReleases = 0;
    };
    std::shared_ptr<Waits> waits = std::make_shared<Waits>();
    std::function<void()> exitCallback;
    QPointer<QObject> watchContext;
    FakeHostOps() {
        identity = {42, 100, 1, image(), {}, newHandle()};
    }
    std::shared_ptr<void> newHandle() {
        return std::shared_ptr<void>(new int, [tracking = waits](void* p) {
            if (tracking->active.value(p))
                ++tracking->unsafeReleases;
            delete static_cast<int*>(p);
        });
    }
    CaptureProbe probe(const QString& expected, const QString& name) override {
        if (name != windowClass)
            return {CaptureProbe::Absent, {}};
        if (kind == CaptureProbe::Absent || kind == CaptureProbe::Uncertain)
            return {kind, {}};
        return {expected == identity.image ? kind : CaptureProbe::Foreign, identity};
    }
    bool matches(const CaptureIdentity& candidate, const QString& name) override {
        return match && name == windowClass && candidate.pid == identity.pid
            && candidate.created == identity.created && candidate.window == identity.window
            && candidate.image == identity.image && bool(candidate.handle);
    }
    bool hasCaptureWindow(const CaptureIdentity&) override { return busyWindow; }
    bool postClose(const CaptureIdentity&) override { ++posts; return postResult; }
    bool launch(const QString& executable, const QStringList&, CaptureIdentity& child) override {
        ++launches;
        if (kind == CaptureProbe::Absent) {
            kind = startupInvisible ? CaptureProbe::Absent : CaptureProbe::Verified;
            ++identity.pid;
            ++identity.created;
            identity.image = executable;
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
    QObject* watch(const CaptureIdentity& observed, QObject* context, std::function<void()> exited) override {
        auto* token = new QObject(context);
        auto* key = observed.handle.get();
        ++waits->active[key];
        QObject::connect(token, &QObject::destroyed, [tracking = waits, key] { --tracking->active[key]; });
        watchContext = token;
        exitCallback = std::move(exited);
        return token;
    }
    std::optional<quint32> exitCode(const CaptureIdentity&) override { return code; }
    void exit(quint32 result = 1) {
        code = result;
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
    property int reloads: 0
    function reload(hard) { reloads++ }
    function env(name) {
        return name === "CAELESTIA_COMBINED_LIVE" || name === "CAELESTIA_SHELL_LIVE" ? "1" : ""
    }
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

    // Execute the actual shell quit/restart/state IPC functions, without the
    // desktop graph. The surrounding root/IPC transport alone is a fixture.
    QFile shell(source + QStringLiteral("/../../shell.qml"));
    QVERIFY(shell.open(QIODevice::ReadOnly));
    auto text = shell.readAll().replace("\r\n", "\n");
    const auto start = text.indexOf("    IpcHandler {\n        target: \"shell\"");
    const auto end = text.indexOf("        function state():", start);
    QVERIFY(start >= 0 && end > start);
    write(root + QStringLiteral("/ShellIpc.qml"),
        "import QtQuick\nimport Quickshell\nimport Quickshell.Io\nimport qs.services\n"
        "Item {\n id: root\n property string generation: \"fixture-generation\"\n"
        " property var service: Glazier\n property int reloads: Quickshell.reloads\n"
        " Component.onCompleted: Glazier.configure(JSON.stringify({executable: fixtureImage}))\n"
        " function quitIpc() { return shellIpc.quit() }\n"
        " function restartIpc() { return shellIpc.restart() }\n"
        " function captureStateIpc() { return shellIpc.captureHostState() }\n"
        + text.mid(start, end - start).replace("IpcHandler {", "IpcHandler {\n id: shellIpc")
        + "    }\n}\n");
}
}

class CaptureHostTests : public QObject {
    Q_OBJECT
private slots:
    void initTestCase() {
        qmlRegisterType<FixtureCaptureHost>("Caelestia.Windows", 1, 0, "CaptureHost");
    }
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
        QVERIFY(!registry.snapshot().value(QStringLiteral("closeAttempted")).toBool());
        QVERIFY(registry.prepareReload(lease));
        registry.ensure(lease);
        QTRY_COMPARE(state(registry), QStringLiteral("Owned"));
        ops->postResult = true;
        QVERIFY(registry.close(lease));
        QTRY_COMPARE(state(registry), QStringLiteral("Closing"));
        QVERIFY(!registry.prepareReload(lease));
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
        if (kind == CaptureProbe::Foreign)
            ops->identity.image = QCoreApplication::applicationDirPath() + QStringLiteral("/capture-host-child.exe");
        CaptureHostRegistry registry(ops);
        const auto lease = registry.acquire(image(), hostClass, {});
        QTRY_VERIFY(state(registry) != QStringLiteral("Probing"));
        QVERIFY(state(registry) != QStringLiteral("Owned"));
        QVERIFY(!owned(registry));
        QVERIFY(!registry.close(lease));
        QVERIFY(registry.prepareReload(lease));
        if (kind == CaptureProbe::Foreign) {
            QVERIFY(ops->watchContext);
            ops->exit(0);
            QCOMPARE(state(registry), QStringLiteral("Exited"));
        } else {
            ops->kind = CaptureProbe::Verified;
            registry.ensure(lease);
            QTRY_COMPARE(state(registry), QStringLiteral("Owned"));
        }
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
        QVERIFY(registry.close(lease));
        QTRY_COMPARE(state(registry), QStringLiteral("CloseFailed"));
        QVERIFY(!registry.command(lease, {}));
        QTRY_VERIFY(!registry.snapshot().value(QStringLiteral("checking")).toBool());
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
        ops->kind = CaptureProbe::Absent;
        ops->response = {false, true, {}, {}};
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
        QCOMPARE(ops->launches, 4); // Cold launch plus three crash recoveries.
        registry.acquire(image(), hostClass, {}); // Reload cannot bypass the budget.
        QTest::qWait(20);
        QCOMPARE(state(registry), QStringLiteral("Exited"));
        QCOMPARE(ops->launches, 4);
    }
    void cleanExitAndStableRecoveryWindow() {
        auto ops = std::make_shared<FakeHostOps>();
        CaptureHostRegistry registry(ops);
        registry.recoveryDelayMs = 1;
        registry.stableWindowMs = 25;
        const auto lease = registry.acquire(image(), hostClass, {});
        QTRY_COMPARE(state(registry), QStringLiteral("Owned"));
        ops->exit(0);
        QTest::qWait(20);
        QCOMPARE(state(registry), QStringLiteral("Exited"));
        registry.acquire(image(), hostClass, {}); // Reload is not a cold Start.
        QTest::qWait(20);
        QCOMPARE(ops->launches, 0);
        QVERIFY(!registry.command(lease, {})); // Retired writer.
        CaptureHost active(&registry);
        active.acquire(image(), hostClass, {});
        QVERIFY(active.command({}));
        QTRY_COMPARE(state(registry), QStringLiteral("Owned"));
        ops->exit();
        QTRY_COMPARE(state(registry), QStringLiteral("Owned"));
        QCOMPARE(registry.snapshot().value(QStringLiteral("recoveries")).toInt(), 1);
        QTest::qWait(30);
        ops->exit();
        QTRY_COMPARE(state(registry), QStringLiteral("Owned"));
        QCOMPARE(registry.snapshot().value(QStringLiteral("recoveries")).toInt(), 1);
        QCOMPARE(ops->launches, 3);
    }
    void notifierDestroyedBeforeHandleReplacementAndDestruction() {
        auto ops = std::make_shared<FakeHostOps>();
        auto registry = std::make_unique<CaptureHostRegistry>(ops);
        const auto lease = registry->acquire(image(), hostClass, {});
        QTRY_COMPARE(state(*registry), QStringLiteral("Owned"));
        ops->identity.handle = ops->newHandle();
        ops->response.valid = false;
        QVERIFY(registry->close(lease));
        QTRY_COMPARE(state(*registry), QStringLiteral("CloseFailed"));
        QCOMPARE(ops->waits->unsafeReleases, 0);
        ops->identity.handle.reset(); // Registry holds the last reference.
        registry.reset();
        QCOMPARE(ops->waits->unsafeReleases, 0);
        for (const auto active : ops->waits->active)
            QCOMPARE(active, 0);
    }
    void imageWindowAndClassArePartOfIdentity() {
        auto ops = std::make_shared<FakeHostOps>();
        CaptureHostRegistry registry(ops);
        const auto lease = registry.acquire(image(), hostClass, {});
        QTRY_COMPARE(state(registry), QStringLiteral("Owned"));
        auto different = ops->identity;
        different.image += QStringLiteral(".foreign");
        QVERIFY(!ops->matches(different, hostClass));
        different = ops->identity;
        ++different.window;
        QVERIFY(!ops->matches(different, hostClass));
        QVERIFY(!ops->matches(ops->identity, QStringLiteral("OtherClass")));
        QCOMPARE(ops->probe(image() + QStringLiteral(".other"), hostClass).kind, CaptureProbe::Foreign);
        ++ops->identity.window;
        QVERIFY(registry.close(lease));
        QTRY_COMPARE(state(registry), QStringLiteral("CloseFailed"));
        QCOMPARE(ops->posts, 0);
    }
    void slowHealthyStartupPastFiveSeconds_data() {
        QTest::addColumn<bool>("afterDeadline");
        QTest::newRow("status-longer-than-startup-bound") << true;
        QTest::newRow("healthy-after-five-seconds") << false;
    }
    void slowHealthyStartupPastFiveSeconds() {
        QFETCH(bool, afterDeadline);
        auto ops = std::make_shared<FakeHostOps>();
        ops->kind = CaptureProbe::Absent;
        ops->response = {false, true, {}, {}};
        ops->startupInvisible = true;
        CaptureHostRegistry registry(ops);
        registry.startupTimeoutMs = afterDeadline ? 200 : 20000;
        const auto lease = registry.acquire(image(), hostClass, {});
        QTRY_COMPARE(state(registry), QStringLiteral("Starting"));
        // One genuinely slow asynchronous response. The deadline must not
        // invalidate it or authorize a duplicate launch.
        ops->statusDelay = afterDeadline ? 300 : 5400;
        ops->kind = CaptureProbe::Verified;
        ops->response = {true, false, QString::number(ops->identity.pid) + QStringLiteral("-fixture"), QStringLiteral("idle")};
        if (afterDeadline)
            QTRY_COMPARE(state(registry), QStringLiteral("CloseFailed"));
        QTRY_COMPARE_WITH_TIMEOUT(state(registry), QStringLiteral("Owned"), 7000);
        QCOMPARE(ops->launches, 1);
        QVERIFY(registry.prepareReload(lease));
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
    void unhealthyStatusCanRetry_data() {
        QTest::addColumn<bool>("wrongHost");
        QTest::newRow("unresponsive") << false;
        QTest::newRow("wrong-host-id") << true;
    }
    void unhealthyStatusCanRetry() {
        QFETCH(bool, wrongHost);
        auto ops = std::make_shared<FakeHostOps>();
        CaptureHostRegistry registry(ops);
        const auto lease = registry.acquire(image(), hostClass, {});
        QTRY_COMPARE(state(registry), QStringLiteral("Owned"));
        if (wrongHost)
            ops->response.hostId = QStringLiteral("42-other-host");
        else
            ops->response.valid = false;
        QVERIFY(registry.close(lease));
        QTRY_VERIFY(!registry.snapshot().value(QStringLiteral("checking")).toBool());
        QCOMPARE(state(registry), QStringLiteral("CloseFailed"));
        QVERIFY(registry.prepareReload(lease));
        QVERIFY(owned(registry));
        QCOMPARE(ops->posts, 0);
        QCOMPARE(ops->launches, 0);
        ops->response = {true, false, QStringLiteral("42-fixture"), QStringLiteral("idle")};
        QVERIFY(!registry.command(lease, {})); // Recheck, never queue a false-ack command.
        QTRY_COMPARE(state(registry), QStringLiteral("Owned"));
        QCOMPARE(ops->launches, 0);
        QVERIFY(registry.command(lease, {}));
        QCOMPARE(ops->launches, 1);
    }
    void exitDuringHandoffDoesNotBlockReload() {
        auto ops = std::make_shared<FakeHostOps>();
        CaptureHostRegistry registry(ops);
        registry.recoveryDelayMs = 1;
        const auto lease = registry.acquire(image(), hostClass, {});
        QTRY_COMPARE(state(registry), QStringLiteral("Owned"));
        ops->statusDelay = 30;
        QSignalSpy ready(&registry, &CaptureHostRegistry::reloadReady);
        QVERIFY(registry.prepareReload(lease));
        ops->exit();
        QTRY_COMPARE(ready.count(), 1);
        QVERIFY(ready.first().at(1).toBool());
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
        QVERIFY(registry.prepareReload(next));
        ops->startupInvisible = false;
        ops->exit();
        QTRY_COMPARE(state(registry), QStringLiteral("Owned"));
        QCOMPARE(ops->launches, 2);
    }
    void startupDeadlineCanReverifyWithoutExit() {
        auto ops = std::make_shared<FakeHostOps>();
        ops->kind = CaptureProbe::Absent;
        ops->response = {false, true, {}, {}};
        ops->startupInvisible = true;
        CaptureHostRegistry registry(ops);
        registry.startupTimeoutMs = 25;
        const auto lease = registry.acquire(image(), hostClass, {});
        QTRY_COMPARE(state(registry), QStringLiteral("CloseFailed"));
        QTest::qWait(150);
        const auto reads = ops->reads;
        QTest::qWait(150);
        QCOMPARE(ops->reads, reads); // No unbounded polling after timeout.
        ops->kind = CaptureProbe::Verified;
        ops->response = {true, false, QString::number(ops->identity.pid) + QStringLiteral("-fixture"), QStringLiteral("idle")};
        QVERIFY(!registry.command(lease, {}));
        QTRY_COMPARE(state(registry), QStringLiteral("Owned"));
        QCOMPARE(ops->launches, 1);
    }
    void payloadChangeCancelsQueuedStartupRetry() {
        auto ops = std::make_shared<FakeHostOps>();
        ops->kind = CaptureProbe::Absent;
        ops->response = {false, true, {}, {}};
        ops->startupInvisible = true;
        CaptureHostRegistry registry(ops);
        registry.startupTimeoutMs = 500;
        registry.acquire(image(), hostClass, {});
        QTRY_VERIFY(ops->reads > 0 && !registry.snapshot().value(QStringLiteral("checking")).toBool());
        const auto replacement = QCoreApplication::applicationDirPath() + QStringLiteral("/capture-host-child.exe");
        registry.acquire(replacement, hostClass, {});
        QCOMPARE(state(registry), QStringLiteral("Foreign"));
        const auto reads = ops->reads;
        QTest::qWait(160);
        QCOMPARE(ops->reads, reads);
        QCOMPARE(ops->launches, 1);
    }
    void quitWhileDiscoveryPendingCannotLaunchAfterward() {
        auto ops = std::make_shared<FakeHostOps>();
        ops->kind = CaptureProbe::Absent;
        ops->response = {false, true, {}, {}};
        ops->statusDelay = 40;
        CaptureHostRegistry registry(ops);
        const auto lease = registry.acquire(image(), hostClass, {});
        QVERIFY(registry.quit(lease));
        QTest::qWait(80);
        QCOMPARE(ops->launches, 0);
        QCOMPARE(ops->posts, 0);
    }
    void crashDuringQuitCheckDoesNotRecover() {
        auto ops = std::make_shared<FakeHostOps>();
        CaptureHostRegistry registry(ops);
        registry.recoveryDelayMs = 1;
        const auto lease = registry.acquire(image(), hostClass, {});
        QTRY_COMPARE(state(registry), QStringLiteral("Owned"));
        ops->statusDelay = 40;
        QSignalSpy ready(&registry, &CaptureHostRegistry::quitReady);
        QVERIFY(registry.quit(lease));
        ops->exit();
        QCOMPARE(ready.count(), 1);
        QVERIFY(ready.first().at(1).toBool());
        QTest::qWait(80);
        QCOMPARE(state(registry), QStringLiteral("Exited"));
        QCOMPARE(ops->launches, 0);
    }
    void payloadChangeNeverRecoversRetiredImage_data() {
        QTest::addColumn<bool>("posted");
        QTest::newRow("retained-live-identity") << false;
        QTest::newRow("posted-unresolved-close") << true;
    }
    void payloadChangeNeverRecoversRetiredImage() {
        QFETCH(bool, posted);
        auto ops = std::make_shared<FakeHostOps>();
        CaptureHostRegistry registry(ops);
        registry.recoveryDelayMs = 1;
        const auto old = registry.acquire(image(), hostClass, {});
        QTRY_COMPARE(state(registry), QStringLiteral("Owned"));
        if (posted) {
            QVERIFY(registry.close(old, true));
            QTRY_COMPARE(state(registry), QStringLiteral("Closing"));
        }
        // Two actual distinct executable files, not a non-existent path alias.
        const auto replacement = QCoreApplication::applicationDirPath() + QStringLiteral("/capture-host-child.exe");
        const auto next = registry.acquire(replacement, hostClass, {});
        QCOMPARE(state(registry), posted ? QStringLiteral("Closing") : QStringLiteral("Foreign"));
        QVERIFY(!owned(registry));
        QVERIFY(!registry.close(next));
        QCOMPARE(registry.prepareReload(next), !posted);
        QVERIFY(!registry.command(next, {}));
        ops->exit();
        QTest::qWait(20);
        QCOMPARE(state(registry), QStringLiteral("Exited"));
        QCOMPARE(ops->launches, 0);
        QVERIFY(registry.command(next, {}));
        QTRY_COMPARE(state(registry), QStringLiteral("Owned"));
        QCOMPARE(ops->identity.image, replacement);
        QCOMPARE(ops->launches, 1); // Explicit current payload, not retired image.
    }
    void payloadPathReversionCanReverifyRetainedIdentity() {
        auto ops = std::make_shared<FakeHostOps>();
        CaptureHostRegistry registry(ops);
        registry.acquire(image(), hostClass, {});
        QTRY_COMPARE(state(registry), QStringLiteral("Owned"));
        registry.acquire(QCoreApplication::applicationDirPath() + QStringLiteral("/capture-host-child.exe"), hostClass, {});
        QCOMPARE(state(registry), QStringLiteral("Foreign"));
        const auto restored = registry.acquire(image(), hostClass, {});
        QVERIFY(!registry.command(restored, {}));
        QTRY_COMPARE(state(registry), QStringLiteral("Owned"));
        QVERIFY(owned(registry));
        QCOMPARE(ops->launches, 0);
        QCOMPARE(ops->posts, 0);
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
        auto ops = std::make_shared<FakeHostOps>();
        ops->windowClass = QStringLiteral("GlazierHost");
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
    void shellQuitAndRestartIpc_data() {
        QTest::addColumn<QString>("scenario");
        for (const auto* scenario : {"Owned", "Foreign", "Starting", "CloseFailed", "AccessDenied", "FailedPost", "LateExit", "Recording"})
            QTest::newRow(scenario) << QString::fromLatin1(scenario);
    }
    void shellQuitAndRestartIpc() {
        QFETCH(QString, scenario);
        auto ops = std::make_shared<FakeHostOps>();
        ops->windowClass = QStringLiteral("GlazierHost");
        if (scenario == QStringLiteral("Foreign"))
            ops->identity.image = QCoreApplication::applicationDirPath() + QStringLiteral("/capture-host-child.exe");
        if (scenario == QStringLiteral("AccessDenied"))
            ops->kind = CaptureProbe::Uncertain;
        if (scenario == QStringLiteral("CloseFailed"))
            ops->response.valid = false;
        if (scenario == QStringLiteral("Recording"))
            ops->response.phase = QStringLiteral("recording");
        if (scenario == QStringLiteral("Starting")) {
            ops->kind = CaptureProbe::Absent;
            ops->response = {false, true, {}, {}};
            ops->startupInvisible = true;
        }
        CaptureHostRegistry registry(ops);
        registry.closeTimeoutMs = 25;
        qmlRegistry = &registry;
        QTemporaryDir files;
        QVERIFY(files.isValid());
        stageQml(files.path());
        QQmlEngine engine;
        engine.addImportPath(files.path());
        engine.rootContext()->setContextProperty(QStringLiteral("fixtureRoot"), files.path());
        engine.rootContext()->setContextProperty(QStringLiteral("fixtureImage"), image());
        QSignalSpy quit(&engine, &QQmlEngine::quit);
        QQmlComponent component(&engine, QUrl::fromLocalFile(files.path() + QStringLiteral("/ShellIpc.qml")));
        QScopedPointer<QObject> root(component.create());
        QVERIFY2(root, qPrintable(component.errorString()));
        const auto expected = scenario == QStringLiteral("AccessDenied") ? QStringLiteral("CloseFailed")
            : scenario == QStringLiteral("FailedPost") || scenario == QStringLiteral("LateExit")
                || scenario == QStringLiteral("Recording") ? QStringLiteral("Owned") : scenario;
        QTRY_COMPARE(state(registry), expected);
        QVariant result;
        QVERIFY(QMetaObject::invokeMethod(root.data(), "restartIpc", Q_RETURN_ARG(QVariant, result)));
        QCOMPARE(result.toString(), QStringLiteral("fixture-generation"));
        QTRY_COMPARE(root->property("reloads").toInt(), 1);
        QCOMPARE(ops->posts, 0);
        if (scenario == QStringLiteral("FailedPost"))
            ops->postResult = false;
        if (scenario == QStringLiteral("Starting")) {
            ops->statusDelay = 300;
            QTRY_VERIFY(registry.snapshot().value(QStringLiteral("checking")).toBool());
        }
        QVERIFY(QMetaObject::invokeMethod(root.data(), "quitIpc", Q_RETURN_ARG(QVariant, result)));
        if (scenario == QStringLiteral("Foreign") || scenario == QStringLiteral("AccessDenied")) {
            QVERIFY(result.toBool());
            QCOMPARE(quit.count(), 1);
            QCOMPARE(ops->posts, 0);
            QCOMPARE(ops->launches, 0);
        } else if (scenario == QStringLiteral("Starting")) {
            QVERIFY(!result.toBool());
            QVERIFY(!registry.snapshot().value(QStringLiteral("error")).toString().isEmpty());
            QCOMPARE(quit.count(), 0);
        } else if (scenario == QStringLiteral("CloseFailed") || scenario == QStringLiteral("FailedPost") || scenario == QStringLiteral("Recording")) {
            QVERIFY(result.toBool()); // Accepted asynchronous check, not quit success.
            QTRY_VERIFY(!registry.snapshot().value(QStringLiteral("checking")).toBool());
            QCOMPARE(state(registry), scenario == QStringLiteral("Recording") ? QStringLiteral("Owned") : QStringLiteral("CloseFailed"));
            QCOMPARE(quit.count(), 0);
            QVERIFY(QMetaObject::invokeMethod(root.data(), "captureStateIpc", Q_RETURN_ARG(QVariant, result)));
            QVERIFY(!QJsonDocument::fromJson(result.toString().toUtf8()).object().value(QStringLiteral("error")).toString().isEmpty());
            QVERIFY(QMetaObject::invokeMethod(root.data(), "restartIpc", Q_RETURN_ARG(QVariant, result)));
            QCOMPARE(result.toString(), QStringLiteral("fixture-generation"));
            QTRY_COMPARE(root->property("reloads").toInt(), 2);
        } else {
            QVERIFY(result.toBool());
            // Repeating quit cannot cancel the already accepted request.
            QVERIFY(QMetaObject::invokeMethod(root.data(), "quitIpc", Q_RETURN_ARG(QVariant, result)));
            QVERIFY(result.toBool());
            // Refuse immediately, while the asynchronous status check is
            // pending, not only after its close message has been posted.
            QVERIFY(QMetaObject::invokeMethod(root.data(), "restartIpc", Q_RETURN_ARG(QVariant, result)));
            QCOMPARE(root->property("reloads").toInt(), 1);
            QVERIFY(!registry.snapshot().value(QStringLiteral("error")).toString().isEmpty());
            QTRY_COMPARE(state(registry), QStringLiteral("Closing"));
            QVERIFY(QMetaObject::invokeMethod(root.data(), "restartIpc", Q_RETURN_ARG(QVariant, result)));
            QCOMPARE(result.toString(), QStringLiteral("fixture-generation")); // Not a success claim.
            QVERIFY(!registry.snapshot().value(QStringLiteral("error")).toString().isEmpty());
            QCOMPARE(root->property("reloads").toInt(), 1);
            if (scenario == QStringLiteral("LateExit"))
                QTRY_COMPARE(state(registry), QStringLiteral("CloseFailed"));
            ops->exit(0);
            QCOMPARE(state(registry), QStringLiteral("Exited"));
            QCOMPARE(quit.count(), scenario == QStringLiteral("LateExit") ? 0 : 1);
        }
        qmlRegistry = nullptr;
    }
    void immediateRepeatReloadBeforeStartupTimer() {
        auto ops = std::make_shared<FakeHostOps>();
        ops->windowClass = QStringLiteral("GlazierHost");
        CaptureHostRegistry registry(ops);
        registry.acquire(image(), ops->windowClass, {});
        QTRY_COMPARE(state(registry), QStringLiteral("Owned"));
        qmlRegistry = &registry;
        QTemporaryDir files;
        QVERIFY(files.isValid());
        stageQml(files.path());
        for (int generation = 0; generation < 3; ++generation) {
            QQmlEngine engine;
            engine.addImportPath(files.path());
            engine.rootContext()->setContextProperty(QStringLiteral("fixtureRoot"), files.path());
            engine.rootContext()->setContextProperty(QStringLiteral("fixtureImage"), image());
            QQmlComponent component(&engine, QUrl::fromLocalFile(files.path() + QStringLiteral("/ShellIpc.qml")));
            QScopedPointer<QObject> root(component.create());
            QVERIFY2(root, qPrintable(component.errorString()));
            QVariant result;
            // No event-loop spin between graph creation and the IPC call.
            QVERIFY(QMetaObject::invokeMethod(root.data(), "restartIpc", Q_RETURN_ARG(QVariant, result)));
            QCOMPARE(result.toString(), QStringLiteral("fixture-generation"));
            QTRY_COMPARE(root->property("reloads").toInt(), 1);
        }
        QCOMPARE(ops->posts, 0);
        QCOMPARE(ops->launches, 0);
        qmlRegistry = nullptr;
    }
    void realNativeLaunchAndHandoff() {
        QTemporaryDir cwdLogs;
        QVERIFY(cwdLogs.isValid());
        const auto cwdLog = cwdLogs.path() + QStringLiteral("/cwd");
        const auto fixtureClass = QStringLiteral("CaelestiaCaptureFixture.launch.%1").arg(QCoreApplication::applicationPid());
        qputenv("CAELESTIA_CAPTURE_FIXTURE_CLASS", fixtureClass.toUtf8());
        qputenv("CAELESTIA_CAPTURE_FIXTURE_CLOSE_DELAY", "1");
        qputenv("CAELESTIA_CAPTURE_FIXTURE_CWD_LOG", cwdLog.toUtf8());
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
                qunsetenv("CAELESTIA_CAPTURE_FIXTURE_CWD_LOG");
            }
        } cleanup{ops, childPath, fixtureClass};
        CaptureHostRegistry registry(ops);
        CaptureHost original(&registry);
        original.acquire(childPath, fixtureClass, {});
        QTRY_COMPARE(state(registry), QStringLiteral("Owned"));
        for (const auto& suffix : {QStringLiteral(".host"), QStringLiteral(".status")}) {
            QFile cwdFile(cwdLog + suffix);
            QVERIFY(cwdFile.open(QIODevice::ReadOnly));
            QCOMPARE(QString::fromUtf8(cwdFile.readAll()), QDir::homePath());
            QVERIFY(QDir::homePath() != QFileInfo(childPath).absolutePath());
        }
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
        const auto gateName = QStringLiteral("Local\\CaelestiaCaptureFixture.Exit.%1")
            .arg(QCoreApplication::applicationPid());
        struct ExitGate {
            HANDLE handle;
            ~ExitGate() {
                if (handle) {
                    SetEvent(handle);
                    CloseHandle(handle);
                }
                qunsetenv("CAELESTIA_CAPTURE_FIXTURE_EXIT_GATE");
                qunsetenv("CAELESTIA_CAPTURE_FIXTURE_CLASS");
                qunsetenv("CAELESTIA_CAPTURE_FIXTURE_CLOSE_DELAY");
            }
        } gate{CreateEventW(nullptr, TRUE, FALSE, reinterpret_cast<LPCWSTR>(gateName.utf16()))};
        QVERIFY(gate.handle);
        qputenv("CAELESTIA_CAPTURE_FIXTURE_EXIT_GATE", gateName.toUtf8());
        const auto childPath = QCoreApplication::applicationDirPath() + QStringLiteral("/capture-host-child.exe");
        QProcess child;
        child.setProgram(childPath);
        child.start();
        QVERIFY(child.waitForStarted(2000)); // Test setup, not production GUI close.
        auto ops = makeCaptureHostOps();
        QTRY_COMPARE(ops->probe(childPath, fixtureClass).kind, CaptureProbe::Verified);
        QStringList transitions;
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
        connect(&registry, &CaptureHostRegistry::changed, this, [&] {
            transitions.append(state(registry));
        });
        QVERIFY(registry.close(old));
        // Closing may be shorter than QTRY's sampling interval. Observe the
        // real transition, and hold only this fixture child until the deadline
        // and responsiveness checks complete.
        QTRY_VERIFY(transitions.contains(QStringLiteral("Closing")));
        registry.acquire(childPath, fixtureClass, {});
        registry.release(old);
        QTRY_COMPARE(state(registry), QStringLiteral("CloseFailed"));
        QVERIFY(owned(registry));
        QTRY_VERIFY(ticks >= 10);
        QVERIFY(SetEvent(gate.handle));
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
