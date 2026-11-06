pragma ComponentBehavior: Bound
import QtQuick
import Quickshell
import Quickshell.Io
import Caelestia.Config
import StagedFixture
import qs.services as Services
import "./windows/services/apps" as Apps

QtObject {
    id: test
    property int assertions: 0
    property var cases: []
    property int phase: 0
    property var first: null
    property var replacement: null
    property var firstBackend: null
    property var replacementBackend: null
    property int staleItemsJob: -1
    property int stalePasteJob: -1
    property int staleImageJob: -1
    property int completedBeforeDisable: 0
    property int shutdownsBeforeDisable: 0
    property int pasteSignals: 0
    property int imageSignals: 0
    property string lastPaste: ""
    property string lastImage: ""

    component Entry: QtObject {
        property string id: "synthetic.app"
        property string name: "Synthetic app"
        property bool runInTerminal: false
        property int executions: 0
        function execute(): void { executions++; }
    }
    component Notification: QtObject {
        property int id: 633
        property bool tracked: false
        property string summary: "Synthetic notification"
        property string body: "No user content"
        property var hints: ({})
        property var actions: []
        signal closed(int reason)
    }
    component CountingStore: QtObject {
        property var frequencies: ({})
        property int increments: 0
        function increment(id): void { increments++; }
    }
    readonly property Component entryComponent: Component { Entry {} }
    readonly property Component notificationComponent: Component { Notification {} }
    readonly property Component countingStoreComponent: Component { CountingStore {} }
    readonly property Component appComponent: Component { Apps.AppsService {} }
    readonly property Component catalogComponent: Component { Apps.NativeAppCatalog {} }
    readonly property Component storeComponent: Component { Apps.FileAppFrequencyStore {} }
    readonly property Component backendComponent: Component { Services.NativeNotificationBackend {} }
    readonly property Component serviceComponent: Component { Services.NotificationsService {} }

    readonly property Connections clipboardSignals: Connections {
        target: Services.ClipboardHistory
        function onPasteReady(id): void { test.pasteSignals++; test.lastPaste = id; }
        function onImageReady(id, url): void { test.imageSignals++; test.lastImage = id; }
    }

    function check(id, condition, detail): void {
        if (!condition)
            throw new Error(id + (detail === undefined ? "" : ": " + JSON.stringify(detail)));
        assertions++;
    }
    function finishCase(name): void { cases.push(name); }

    function apps(): void {
        const oldEntry = entryComponent.createObject(test);
        const newEntry = entryComponent.createObject(test, {name: "Refreshed app"});
        const catalog = catalogComponent.createObject(test);
        DesktopEntries.completeScan([oldEntry]);
        const store = countingStoreComponent.createObject(test);
        const app = appComponent.createObject(test, {
            catalog: catalog, enabled: true, launchEnabled: true, frequencyStore: store
        });
        check("apps.initial-ready", app.ready && app.search("")[0] === oldEntry);
        DesktopEntries.completeScan([newEntry]);
        check("apps.refreshed-binding", app.search("")[0] === newEntry && oldEntry !== newEntry);
        check("apps.same-id-stale", !app.canLaunch(oldEntry) && !app.launch(oldEntry));
        check("apps.no-stale-side-effects", oldEntry.executions === 0 && store.increments === 0);
        check("apps.current-instance-launches", app.launch(newEntry) && newEntry.executions === 1 && store.increments === 1);
        check("apps.lookup-current-instance", app.entryForAppId("synthetic.app") === newEntry);
        app.destroy(); catalog.destroy(); oldEntry.destroy(); newEntry.destroy(); store.destroy();
        finishCase("apps-same-id-refresh");
    }

    function frequencyPersistence(): void {
        const state = Driver.profile + "/state";
        const path = state.replace(/\//g, "\\") + "\\apps-frequencies.json";
        Driver.files[path] = '{"version":1,"frequencies":{"synthetic.app":4}}';
        const store = storeComponent.createObject(test, {stateDir: state});
        check("persistence.real-file-adapter-read", store.loaded && store.frequencyFor("synthetic.app") === 4 && Driver.readPaths.includes(path));
        const writes = Driver.writes.length;
        store.increment("synthetic.app");
        check("persistence.write-is-pending", store.writes === 0 && store.writesPending === 1);
        check("persistence.atomic-confined-document", Driver.writes.length === writes + 1
            && Driver.writes[writes].path === path && Driver.writes[writes].atomic
            && JSON.parse(Driver.writes[writes].text).frequencies["synthetic.app"] === 5);
        store.fileView.saveFailed(FileViewError.AccessDenied);
        check("persistence.adapter-write-failure", store.writes === 0 && store.writesPending === 0 && store.lastError.length > 0);
        check("persistence.failed-write-retains-memory", store.frequencyFor("synthetic.app") === 5
            && JSON.parse(Driver.files[path]).frequencies["synthetic.app"] === 4);
        store.increment("synthetic.app");
        store.fileView.saved();
        check("persistence.adapter-recovery", store.writes === 1 && store.writesPending === 0 && store.lastError === "");
        store.destroy();
        finishCase("app-file-adapter-write-failure-recovery");
    }

    function historyPersistence(): void {
        const facade = Services.Notifs;
        const storage = facade._storage;
        check("persistence.notification-confined", facade.pathConfined && storage.path === Driver.profile + "/state/notifs.json");
        Driver.files[storage.path] = "preserve unreadable synthetic bytes";
        storage.loadFailed(FileViewError.AccessDenied);
        const writes = Driver.writes.length;
        const notification = notificationComponent.createObject(test);
        // Exercise the actual wrapper signal route, not handleNotification().
        facade.backend.nativeServer.notification(notification);
        check("persistence.arrival-survives-read-failure", facade.list.length === 1 && notification.tracked && facade.service.historyLoadFailed,
            {count: facade.list.length, tracked: notification.tracked, failed: facade.service.historyLoadFailed, status: facade.status, ready: facade.backend.ready});
        // Drive the real debounced handler deterministically after an arrival.
        facade._saveTimer.stop();
        facade._saveTimer.triggered();
        check("persistence.unreadable-preserved", Driver.writes.length === writes
            && Driver.files[storage.path] === "preserve unreadable synthetic bytes");
        Driver.files[storage.path] = "[]";
        storage.loaded();
        facade._saveTimer.stop();
        facade._saveTimer.triggered();
        check("persistence.read-recovery-merges-live", !facade.service.historyLoadFailed && facade.list.length === 1
            && Driver.writes.length === writes + 1 && JSON.parse(Driver.writes[writes].text)[0].notificationId === "633");
        // A missing file schedules a write with callLater. Revoke read access
        // before that completion: both the queued and debounced writers must gate.
        storage.loadFailed(FileViewError.FileNotFound);
        storage.loadFailed(FileViewError.AccessDenied);
        facade._saveTimer.stop();
        facade._saveTimer.triggered();
        completedBeforeDisable = Driver.writes.length;
    }

    function startObservation(): void {
        firstBackend = backendComponent.createObject(test);
        replacementBackend = backendComponent.createObject(test);
    }
    function observation(): void {
        first = serviceComponent.createObject(test, {
            enabled: true, mirrorOptIn: true, useExistingAccess: true, backend: firstBackend
        });
        const firstToken = first.observationToken;
        replacement = serviceComponent.createObject(test, {
            enabled: true, mirrorOptIn: true, useExistingAccess: true, backend: replacementBackend
        });
        check("notifications.wrapper-token", Driver.observing && replacement.observationToken > firstToken
            && replacement.observationToken === Driver.observationGeneration);
        const refused = Driver.refusedObservationWrites;
        first.releaseObservation();
        check("notifications.stale-release-refused", Driver.observing && Driver.refusedObservationWrites === refused + 1);
        first.destroy();
        check("notifications.initial-mirror", replacement.systemMirrorActive && replacement.bannerSuppressionAllowed);
        Driver.access = 3;
        check("notifications.signal-revocation", replacement.accessState === "Denied"
            && !replacementBackend.mirrorSystemNotifications && !replacement.bannerSuppressionAllowed && Driver.observing);
        Driver.access = 4;
        check("notifications.signal-unavailable", replacement.mirrorStatus === "unavailable" && Driver.observing);
        Driver.access = 2;
        check("notifications.signal-regrant", replacement.systemMirrorActive && replacement.bannerSuppressionAllowed);
        check("notifications.no-consent-prompt", Driver.accessRequests === 0);
        replacement.destroy();
        finishCase("notification-wrapper-ownership-revocation");
    }

    function clipboardStart(): void {
        check("clipboard.disabled-no-instance", !Services.ClipboardHistory.available && Driver.clipboardGeneration === 0);
        GlobalConfig.windows = {clipboard: {enabled: true}};
    }
    function clipboardQueue(): void {
        const history = Services.ClipboardHistory;
        check("clipboard.wrapper-loaded", history.available && history.status === "ready" && Driver.clipboardGeneration === 1);
        history.refresh();
        Driver.complete(Driver.jobs.length - 1);
        check("clipboard.live-snapshot-propagates", history.count === 1 && history.items[0].id === "synthetic");
        history.paste("synthetic");
        Driver.complete(Driver.jobs.length - 1);
        history.preview("synthetic");
        Driver.complete(Driver.jobs.length - 1);
        check("clipboard.live-result-propagates", pasteSignals === 1 && imageSignals === 1
            && lastPaste === "synthetic" && lastImage === "synthetic");
        history.refresh(); staleItemsJob = Driver.jobs.length - 1;
        history.paste("old"); stalePasteJob = Driver.jobs.length - 1;
        history.preview("old"); staleImageJob = Driver.jobs.length - 1;
        completedBeforeDisable = Driver.completions;
        shutdownsBeforeDisable = Driver.shutdowns;
        GlobalConfig.windows = {clipboard: {enabled: false}};
    }
    function clipboardDisabled(): void {
        check("clipboard.shutdown-on-unload", Driver.shutdowns === shutdownsBeforeDisable + 1);
        check("clipboard.disable-clears-projection", !Services.ClipboardHistory.available
            && Services.ClipboardHistory.status === "disabled" && Services.ClipboardHistory.count === 0);
        GlobalConfig.windows = {clipboard: {enabled: true}};
    }
    function clipboardDelayed(): void {
        check("clipboard.replacement-generation", Services.ClipboardHistory.available && Driver.clipboardGeneration === 2);
        Driver.complete(staleItemsJob); Driver.complete(stalePasteJob); Driver.complete(staleImageJob);
        check("clipboard.delayed-old-work-cancelled", Driver.completions === completedBeforeDisable
            && Driver.suppressed === 3 && Services.ClipboardHistory.count === 0 && pasteSignals === 1 && imageSignals === 1);
        Services.ClipboardHistory.refresh();
        Driver.complete(Driver.jobs.length - 1);
        Services.ClipboardHistory.paste("new");
        Driver.complete(Driver.jobs.length - 1);
        check("clipboard.replacement-still-works", Services.ClipboardHistory.count === 1 && pasteSignals === 2 && lastPaste === "new");
        GlobalConfig.windows = {clipboard: {enabled: false}};
        finishCase("clipboard-loader-delayed-results");
    }

    readonly property Timer steps: Timer {
        interval: 10
        repeat: true
        running: true
        onTriggered: {
            try {
                switch (test.phase++) {
                case 0:
                    Driver.profile = decodeURIComponent(Qt.resolvedUrl("profile").toString().replace(/^file:\/\/\//, ""));
                    test.apps();
                    test.frequencyPersistence();
                    // Lazy singleton construction, then allow wrapper ready timers.
                    test.check("notifications.facade-constructed", Services.Notifs.enabled);
                    break;
                case 1:
                    if (!Services.Notifs.backend?.ready) { test.phase--; break; }
                    test.historyPersistence();
                    break;
                case 2:
                    test.check("persistence.queued-write-rechecks-read-failure", Driver.writes.length === test.completedBeforeDisable);
                    test.finishCase("notification-facade-read-failure-races");
                    test.startObservation();
                    break;
                case 3:
                    if (!test.firstBackend.ready || !test.replacementBackend.ready) { test.phase--; break; }
                    test.observation();
                    break;
                case 4:
                    test.check("notifications.current-destruction-releases", !Driver.observing);
                    test.firstBackend.destroy(); test.replacementBackend.destroy();
                    test.clipboardStart();
                    break;
                case 5: test.clipboardQueue(); break;
                case 6: test.clipboardDisabled(); break;
                case 7: test.clipboardDelayed(); break;
                case 8:
                    test.check("fixture.no-external-actions", Driver.forbiddenCalls === 0);
                    console.log("CAELESTIA_STAGED_MODELS_PASS " + JSON.stringify({assertions: test.assertions, cases: test.cases}));
                    stop();
                    Qt.exit(0);
                }
            } catch (error) {
                console.error("CAELESTIA_STAGED_MODELS_FAIL " + String(error));
                stop();
                Qt.exit(1);
            }
        }
    }
}
