pragma ComponentBehavior: Bound

import QtQuick

// Standalone lifecycle fixture. Imports no Quickshell/native notification
// module or configuration object, creates no NotificationServer, reads no
// environment or hardware, and never constructs Notifs.qml.
// Intended runner:
//   powershell -NoProfile -File windows/scripts/Test-NotificationService.ps1 -QtPrefix <Windows Qt prefix>
// The runner uses Qt qml.exe offscreen with only this file and
// NotificationsService.qml.
QtObject {
    id: test

    component FakeAction: QtObject {
        property string identifier: ""
        property string text: ""
        property int invokeCalls: 0

        function invoke(): void {
            invokeCalls++;
        }
    }

    component FakeNotification: QtObject {
        id: fake

        property int id: 1
        property string appName: "Fixture"
        property string appIcon: ""
        property string summary: "Fixture summary"
        property string body: "Fixture body"
        property string image: ""
        property var hints: ({})
        property real expireTimeout: 5000
        property int urgency: 1
        property bool resident: false
        property bool hasActionIcons: false
        property var actions: []
        property string desktopEntry: ""

        property int dismissCalls: 0
        property int expireCalls: 0
        signal closed(int reason)

        function dismiss(): void {
            dismissCalls++;
            closed(2);
        }

        function expire(): void {
            expireCalls++;
            closed(1);
        }
    }

    component FakeBackend: QtObject {
        property bool ready: true
        property string ownership: "owner"
        property bool mirrorSystemNotifications: false
        property bool systemMirrorActive: false
        property int systemNotificationAccess: 0
        signal notificationReceived(var notification)
    }

    readonly property FakeBackend fixture: FakeBackend {}

    readonly property NotificationsService service: NotificationsService {
        enabled: false
        profileRoot: "C:/fixtures/profile"
        stateDirectory: "C:/fixtures/profile/state"
        cacheDirectory: "C:/fixtures/profile/cache"
        defaultExpireTimeout: 5000
        fullscreenExpireTimeout: 2000
        expirePopups: true
    }

    readonly property NotificationsService restoredService: NotificationsService {
        enabled: true
        profileRoot: "C:/fixtures/profile"
        stateDirectory: "C:/fixtures/profile/state"
        cacheDirectory: "C:/fixtures/profile/cache"
        defaultExpireTimeout: 5000
    }

    readonly property FakeAction actionOne: FakeAction {
        identifier: "default"
        text: "Open"
    }
    readonly property FakeAction actionTwo: FakeAction {
        identifier: "reply"
        text: "Reply"
    }

    property int assertions: 0
    property var asyncRecord: null

    function check(condition, message): void {
        assertions++;
        if (!condition)
            throw new Error(message);
    }

    function close(actual, expected, message): void {
        check(Math.abs(actual - expected) < 0.000001, message + ": " + actual + " != " + expected);
    }

    function expectStatus(expected, message): void {
        check(service.status === expected,
            message + ": status " + service.status + " != " + expected + " (" + service.reason + ")");
    }

    function makeNotification(id, summary, hints): FakeNotification {
        return notificationComponent.createObject(test, {
            id: id,
            summary: summary,
            hints: hints ?? ({})
        });
    }

    readonly property Component notificationComponent: Component {
        FakeNotification {}
    }

    function run(): void {
        // --- Safe construction and preserved defaults -------------------------
        check(service.enabled === false && service.backend === null
            && service.backendError === "", "safe construction defaults");
        expectStatus("disabled", "explicit disabled state");
        check(service.reason.indexOf("disabled") >= 0, "disabled reason");
        check(!service.ready && !service.backendPresent && service.list.length === 0
            && service.popups.length === 0 && service.notClosed.length === 0,
            "disabled has no records");
        check(service.mirroringOff && !service.mirroringRequested
            && !service.systemMirrorActive, "disabled never mirrors");
        check(service.ownership === "unknown" && !service.ownershipKnown
            && service.ownershipNote.length > 0, "ownership is unknown without a backend");
        check(service.localDismissals === 0 && service.protectedDismissals === 0,
            "dismiss counters start at zero");

        const ignored = makeNotification(900, "Ignored while disabled");
        check(service.handleNotification(ignored) === false, "disabled refuses delivery");
        check(service.list.length === 0, "disabled delivery left no record");
        ignored.destroy();

        // --- Confined history and image-cache paths ---------------------------
        check(service.pathConfined, "declared profile paths are confined");
        check(service.pathError === "", "confined paths have no error");
        check(service.historyPath === "C:/fixtures/profile/state/notifs.json",
            "history path is under the isolated state directory: " + service.historyPath);
        check(service.imageCacheDirectory === "C:/fixtures/profile/cache/notifs",
            "image cache is under the isolated cache directory");
        check(service.historyPath.toLowerCase().indexOf("home") < 0
            && service.historyPath.toLowerCase().indexOf("xdg") < 0,
            "history path does not use HOME/XDG");

        service.profileRoot = "C:/fixtures/other";
        check(!service.pathConfined, "state outside the profile is rejected");
        check(service.pathError.indexOf("outside") >= 0, "outside path error names the boundary");
        check(service.historyPath === "" && service.imageCacheDirectory === "",
            "invalid paths expose no write target");
        check(service.restoreHistory("[]") === false, "restore refuses an unconfined path");
        check(service.historyError.length > 0 && service.historyLoaded,
            "unconfined restore reports an error");
        service.profileRoot = "C:/fixtures/profile";

        service.stateDirectory = "";
        check(!service.pathConfined, "empty state directory is rejected");
        check(service.pathError.indexOf("missing") >= 0, "missing directory error");
        service.stateDirectory = "C:/fixtures/profile/state";

        service.cacheDirectory = "C:/fixtures/profile/state";
        check(!service.pathConfined, "state and cache must be distinct");
        check(service.pathError.indexOf("distinct") >= 0, "distinct directory error");
        service.cacheDirectory = "C:/fixtures/profile/cache";

        service.profileRoot = "C:/fixtures/$HOME/profile";
        service.stateDirectory = "C:/fixtures/$HOME/profile/state";
        service.cacheDirectory = "C:/fixtures/$HOME/profile/cache";
        check(!service.pathConfined, "HOME fallback is rejected");
        check(service.pathError.indexOf("HOME/XDG") >= 0, "HOME fallback error");
        service.profileRoot = "C:/fixtures/profile";
        service.stateDirectory = "C:/fixtures/profile/state";
        service.cacheDirectory = "C:/fixtures/profile/cache";
        check(service.pathConfined, "paths recover after validation");

        // --- Enabled lifecycle ------------------------------------------------
        service.enabled = true;
        expectStatus("initializing", "missing backend is initializing");
        check(service.reason.indexOf("notification server") >= 0, "initializing reason");
        check(service.handleNotification(makeNotification(901, "No backend")) === false,
            "no backend refuses delivery");
        service.list = [];
        service.enabled = true;

        service.backendError = "Fixture backend component failed";
        expectStatus("unavailable", "component failure is unavailable");
        check(service.reason === service.backendError, "component failure reason verbatim");
        check(service.handleNotification(makeNotification(902, "Failed backend")) === false,
            "failed backend refuses delivery");
        service.backendError = "";

        service.backend = fixture;
        fixture.ready = false;
        expectStatus("initializing", "unready backend is initializing");
        check(service.handleNotification(makeNotification(903, "Unready backend")) === false,
            "unready backend refuses delivery");
        fixture.ready = true;
        expectStatus("local", "ready owner backend delivers locally");
        check(service.mirroringOff && service.ownership === "owner"
            && service.ownershipKnown, "owner backend is observable");

        // --- Mirroring refusal -----------------------------------------------
        fixture.mirrorSystemNotifications = true;
        expectStatus("mirroring-blocked", "mirroring must be refused");
        check(service.reason.indexOf("mirroring") >= 0, "mirroring refusal reason");
        check(!service.mirroringOff && !service.deliveryAllowed()
            && service.handleNotification(makeNotification(904, "Mirrored")) === false,
            "mirroring backend cannot deliver through the local UI");
        fixture.mirrorSystemNotifications = false;
        expectStatus("local", "mirroring-off recovers");

        // --- Ownership states -------------------------------------------------
        fixture.ownership = "contended";
        expectStatus("contended", "competing owner state");
        check(service.reason.indexOf("Another notification owner is active") >= 0,
            "competing owner reason is explicit");
        check(service.ownershipKnown && !service.deliveryAllowed()
            && service.handleNotification(makeNotification(905, "Contended")) === false,
            "competing owner refuses local delivery rather than fighting");
        fixture.ownership = "unknown";
        expectStatus("local", "unknown ownership still permits local delivery");
        check(!service.ownershipKnown && service.ownershipNote.length > 0,
            "unknown ownership is stated");
        fixture.ownership = "owner";

        // --- Local arrival and the original NotifData contract ----------------
        const local = makeNotification(101, "Local summary");
        local.appName = "Caelestia Windows";
        local.body = "Local body";
        local.appIcon = "dialog-information-symbolic";
        local.image = "file:///fixtures/notification.png";
        local.expireTimeout = 60000;
        local.urgency = 2;
        local.resident = false;
        local.hasActionIcons = true;
        local.actions = [actionOne, actionTwo];
        local.hints = ({});
        local.desktopEntry = "";

        fixture.notificationReceived(local);
        check(service.list.length === 1 && service.notClosed.length === 1
            && service.popups.length === 1, "local arrival is tracked and popped up");
        const record = service.list[0];
        check(record.notification === local && record.notificationId === "101",
            "record keeps the native notification and id");
        check(record.summary === "Local summary" && record.body === "Local body"
            && record.appName === "Caelestia Windows"
            && record.appIcon === "dialog-information-symbolic",
            "record copies the original notification fields");
        check(record.urgency === 2 && record.resident === false
            && record.hasActionIcons === true, "urgency, resident and action icons");
        check(record.local === true && !record.closed && record.popup,
            "local record is dismissible and popped up");
        check(record.actions.length === 2 && record.actions[0].identifier === "default"
            && record.actions[0].text === "Open" && record.actions[1].text === "Reply",
            "action contract preserves identifier/text");
        record.actions[0].invoke();
        record.actions[1].invoke();
        check(actionOne.invokeCalls === 1 && actionTwo.invokeCalls === 1,
            "actions invoke the native action");
        check(record.time instanceof Date && Number.isFinite(record.time.getTime()),
            "record arrival time");        check(record.timer.interval === 60000, "explicit expiry interval");
        close(record.expireTimeout, 60000, "expire timeout copied");
        check(record.hints && record.hints["x-windows-toast-id"] === undefined,
            "local notification has no Windows toast identity");
        check(record.imageCachePending === true, "remote image requests a cache copy");
        check(record.image === "file:///fixtures/notification.png", "source image preserved");

        // --- Image-cache confinement -----------------------------------------
        const cachePath = service.imageCachePath(record);
        check(cachePath.startsWith("C:/fixtures/profile/cache/notifs/"),
            "image cache path is confined: " + cachePath);
        check(/[0-9a-f]{16}\.png$/.test(cachePath), "image cache path uses the upstream hash");
        check(service.applyCachedImage(record, "C:/fixtures/profile/cache/notifs/escape.png") === true,
            "image cache accepts a confined notifs path");
        check(service.applyCachedImage(record, "C:/fixtures/profile/cache/other/escape.png") === false,
            "image cache refuses a path outside notifs");
        check(service.applyCachedImage(record, "C:/elsewhere/escape.png") === false,
            "image cache refuses an external path");
        check(record.image === "C:/fixtures/profile/cache/notifs/escape.png",
            "rejected cache paths do not rewrite the image");
        const accepted = "C:/fixtures/profile/cache/notifs/1234567890abcdef.png";
        check(service.applyCachedImage(record, accepted) === true, "confined cache path accepted");
        check(record.image === accepted && record.imageCachePending === false,
            "accepted cache path updates the record");
        record.image = "file:///fixtures/notification.png";
        record.imageCachePending = true;
        service.markImageCacheFailed(record);
        check(record.imageCachePending === false && service.imageCacheErrors === 1,
            "failed image cache is counted and cleared");
        record.imageCachePending = false;

        // --- Expiry -----------------------------------------------------------
        record.expireTimeout = 40;
        check(record.timer.interval === 40, "timer follows expireTimeout");
        service.handleExpiry(record);
        check(record.popup === false && service.popups.length === 0
            && service.notClosed.length === 1, "expired popup leaves the list entry");
        record.popup = true;

        // --- Local dismiss ----------------------------------------------------
        record.close();
        check(service.list.length === 0, "local close removes the record");
        check(local.dismissCalls === 1, "local close dismisses the native notification");
        check(service.localDismissals === 1 && service.protectedDismissals === 0,
            "local dismiss counters");

        // --- A system/toast-backed record is never dismissed -------------------
        const system = makeNotification(102, "System toast", {
            "x-windows-toast-id": 7,
            "x-windows-aumid": "Microsoft.WindowsTerminal_8wekyb3d8bbwe!App"
        });
        fixture.notificationReceived(system);
        const systemRecord = service.list[0];
        check(systemRecord.local === false, "toast hints mark a system notification");
        systemRecord.close();
        check(system.dismissCalls === 0, "system notification is never dismissed");
        check(service.protectedDismissals === 1, "protected dismiss counter");
        check(service.list.length === 0, "system record removed only from the local UI");

        // --- A backend close removes the local record without dismissing ------
        const closedElsewhere = makeNotification(103, "Closed elsewhere");
        fixture.notificationReceived(closedElsewhere);
        check(service.list.length === 1, "record before native close");
        closedElsewhere.expire();
        check(service.list.length === 0, "native close removes the record");
        check(closedElsewhere.dismissCalls === 0, "native close does not dismiss again");

        // --- The original lock/unlock hover contract ---------------------------
        const locked = makeNotification(104, "Locked card");
        fixture.notificationReceived(locked);
        const lockedRecord = service.list[0];
        const lockKey = {};
        lockedRecord.lock(lockKey);
        lockedRecord.close();
        check(service.list.length === 1 && lockedRecord.closed,
            "locked card stays while closed");
        check(locked.dismissCalls === 0, "locked card does not dismiss yet");
        lockedRecord.unlock(lockKey);
        check(service.list.length === 0, "unlocked closed card is removed");
        check(locked.dismissCalls === 1, "unlocked card dismisses its local notification");
        check(service.localDismissals === 2, "unlock increments the local dismiss count");

        // --- Progressive property updates -------------------------------------
        const progressive = makeNotification(105, "First summary");
        progressive.actions = [actionOne];
        fixture.notificationReceived(progressive);
        const progressiveRecord = service.list[0];
        check(progressiveRecord.summary === "First summary", "initial summary");
        progressive.summary = "Second summary";
        progressive.body = "Updated body";
        progressive.appName = "Updated app";
        progressive.appIcon = "updated-icon";
        progressive.expireTimeout = 1200;
        progressive.urgency = 0;
        progressive.resident = true;
        progressive.hasActionIcons = true;
        progressive.actions = [actionTwo];
        check(progressiveRecord.summary === "Second summary"
            && progressiveRecord.body === "Updated body"
            && progressiveRecord.appName === "Updated app"
            && progressiveRecord.appIcon === "updated-icon",
            "progressive text updates are observed");
        check(progressiveRecord.expireTimeout === 1200 && progressiveRecord.urgency === 0
            && progressiveRecord.resident === true
            && progressiveRecord.hasActionIcons === true,
            "progressive metadata updates are observed");
        check(progressiveRecord.actions.length === 1
            && progressiveRecord.actions[0].identifier === "reply",
            "progressive action replacement is observed");
        progressiveRecord.close();
        check(progressive.dismissCalls === 1, "progressive local dismiss");

        // --- History serialization and round-trip -----------------------------
        const persistOne = makeNotification(201, "Persisted one");
        persistOne.appName = "Caelestia Windows";
        persistOne.body = "Persisted body";
        persistOne.expireTimeout = 60000;
        persistOne.actions = [actionOne];
        fixture.notificationReceived(persistOne);
        const persistRecord = service.recordForNotificationId(201);
        check(persistRecord !== null, "record lookup by id");
        persistRecord.time = new Date(1000);

        const persistTwo = makeNotification(202, "Persisted two");
        fixture.notificationReceived(persistTwo);
        const persistTwoRecord = service.recordForNotificationId(202);
        persistTwoRecord.time = new Date(3000);

        const json = service.serializeHistory();
        let parsed;
        try {
            parsed = JSON.parse(json);
        } catch (error) {
            check(false, "serialized history is valid JSON");
        }
        check(Array.isArray(parsed) && parsed.length === 2, "history contains both open records");
        const entryOne = parsed.find(entry => entry.notificationId === "201");
        check(!!entryOne && entryOne.summary === "Persisted one"
            && entryOne.body === "Persisted body"
            && entryOne.appName === "Caelestia Windows"
            && entryOne.expireTimeout === 60000
            && entryOne.actions.length === 1
            && entryOne.actions[0].identifier === "default"
            && entryOne.local === true,
            "serialized fields preserve the original contract");
        check(entryOne.time === 1000, "serialized time is epoch milliseconds");
        check(Object.keys(entryOne.actions[0]).sort().join(",") === "identifier,text",
            "actions are serialized without function values");

        check(restoredService.restoreHistory(json), "history restore succeeds");
        check(restoredService.historyLoaded && restoredService.historyError === "",
            "restore marks history loaded");
        check(restoredService.list.length === 2, "restore returns both records");
        check(restoredService.list[0].notificationId === "202"
            && restoredService.list[1].notificationId === "201",
            "restore sorts newest first");
        const restored = restoredService.list[1];
        check(restored.notification === null && restored.closed === false
            && restored.popup === false, "restored record has no native notification");
        check(restored.summary === "Persisted one" && restored.actions.length === 1
            && restored.actions[0].text === "Open", "restored action shape");
        restored.actions[0].invoke();
        check(true, "restored actions are safely invokable without a backend");
        check(Number.isFinite(new Date(restored.time).getTime())
            && new Date(restored.time).getTime() === 1000,
            "restored time is a Date");

        // --- Corrupt and missing history --------------------------------------
        check(restoredService.restoreHistory("{not json") === false,
            "corrupt history is rejected");
        check(restoredService.historyLoaded && restoredService.historyError.indexOf("valid JSON") >= 0,
            "corrupt history reports a clear error");
        check(restoredService.list.length === 0, "corrupt history leaves no records");

        check(restoredService.restoreHistory("") === true,
            "missing history is an empty success");
        check(restoredService.historyLoaded && restoredService.historyError === ""
            && restoredService.list.length === 0, "missing history leaves a clean state");

        check(restoredService.restoreHistory("{}") === false,
            "non-list history is rejected");
        check(restoredService.historyError.indexOf("not a list") >= 0,
            "non-list history error");

        const mixed = JSON.stringify([
            null,
            {},
            {time: 1000, id: "old-format", summary: "Old", body: "Old body"},
            {time: 2000, notificationId: "new-format", summary: "New", body: "New body", actions: [null, {identifier: "x", text: "X"}]},
            {time: "invalid", notificationId: "invalid-time", summary: "Time"}
        ]);
        check(restoredService.restoreHistory(mixed) === true, "mixed history restore");
        check(restoredService.list.length === 4, "invalid entries are filtered but objects survive");
        const mixedNew = restoredService.recordForNotificationId("new-format");
        const mixedOld = restoredService.recordForNotificationId("old-format");
        check(mixedNew !== null && mixedOld !== null,
            "backwards id field is accepted");
        check(new Date(mixedNew.time).getTime() === 2000
            && new Date(mixedOld.time).getTime() === 1000,
            "restored times are preserved");
        check(mixedOld.actions.length === 0, "missing actions are empty");
        check(mixedNew.actions.length === 1, "invalid actions are filtered");

        restoredService.failHistory("Fixture read failure");
        check(restoredService.historyError === "Fixture read failure"
            && restoredService.historyLoaded, "explicit history failure is exposed");

        // Clear the open records before the delivery-confirmation tests.
        for (const open of service.list.slice())
            open.close();
        check(service.list.length === 0, "all local records can be closed");

        // --- Bounded delivery confirmation ------------------------------------
        service.expectDelivery(999);
        check(service.pendingDeliveryId === 999, "delivery expectation recorded");
        service.checkPendingDelivery();
        check(service.deliveryUnconfirmed === true, "missing local delivery is unconfirmed");
        expectStatus("unconfirmed", "unconfirmed delivery state");
        check(service.reason.indexOf("Another notification owner") >= 0,
            "unconfirmed delivery names the likely competing owner");
        check(service.unconfirmedDeliveries === 1, "unconfirmed counter");

        const confirm = makeNotification(1000, "Confirmed delivery");
        fixture.notificationReceived(confirm);
        expectStatus("local", "matching delivery clears the unconfirmed state");
        check(!service.deliveryUnconfirmed && service.list.length === 1,
            "confirmed delivery is tracked");
        service.list[0].close();

        // --- Disable clears every observation ---------------------------------
        service.enabled = false;
        expectStatus("disabled", "disable returns to disabled");
        check(service.list.length === 0 && service.popups.length === 0
            && !service.ready && !service.backendPresent,
            "disable clears records and readiness");
        check(!service.historyLoaded, "disable clears the loaded flag");

        // --- Real Timer expiry (asynchronous phase) ---------------------------
        service.enabled = true;
        service.backend = fixture;
        fixture.ready = true;
        fixture.ownership = "owner";
        fixture.mirrorSystemNotifications = false;
        expectStatus("local", "re-enabled service settles");

        const asyncNotification = makeNotification(300, "Async expiry");
        asyncNotification.expireTimeout = 40;
        fixture.notificationReceived(asyncNotification);
        test.asyncRecord = service.list[0];
        check(test.asyncRecord.popup === true, "async record starts popped up");
        check(test.asyncRecord.timer.interval === 40, "async timer interval");
        check(test.asyncRecord.timer.running, "async timer is running");
        realExpiry.start();
        guard.start();
    }

    function finishAsync(): void {
        check(test.asyncRecord !== null && !test.asyncRecord.closed,
            "async record remains in the list");
        check(test.asyncRecord.popup === false, "real Timer expired the popup");
        check(service.popups.length === 0 && service.notClosed.length === 1,
            "expired popup remains a list notification");
        test.asyncRecord.close();
        check(service.list.length === 0, "async record can be dismissed after expiry");
        check(service.localDismissals >= 3, "async dismissal counted");
        guard.stop();
        console.log("CAELESTIA_NOTIFICATIONS_FIXTURE_PASS " + JSON.stringify({assertions: assertions}));
        Qt.quit();
    }

    readonly property Timer realExpiry: Timer {
        id: realExpiry
        interval: 150
        onTriggered: {
            try {
                test.finishAsync();
            } catch (error) {
                console.error("CAELESTIA_NOTIFICATIONS_FIXTURE_FAIL " + error.message);
                Qt.exit(1);
            }
        }
    }

    readonly property Timer guard: Timer {
        id: guard
        interval: 5000
        onTriggered: {
            console.error("CAELESTIA_NOTIFICATIONS_FIXTURE_FAIL timeout waiting for Timer expiry");
            Qt.exit(1);
        }
    }

    Component.onCompleted: Qt.callLater(() => {
        try {
            test.run();
        } catch (error) {
            console.error("CAELESTIA_NOTIFICATIONS_FIXTURE_FAIL " + error.message);
            Qt.exit(1);
        }
    })
}
