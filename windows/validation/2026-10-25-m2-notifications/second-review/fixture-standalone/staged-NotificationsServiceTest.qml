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
        shellAssetsDirectory: "C:/fixtures/shell/assets"
        defaultExpireTimeout: 5000
        fullscreenExpireTimeout: 2000
        expirePopups: true
    }

    readonly property NotificationsService restoredService: NotificationsService {
        enabled: true
        profileRoot: "C:/fixtures/profile"
        stateDirectory: "C:/fixtures/profile/state"
        shellAssetsDirectory: "C:/fixtures/shell/assets"
        defaultExpireTimeout: 5000
    }

    // Third isolated instance used only for the startup-history merge case: it
    // is enabled per test and delivered to directly, so the shared fixture
    // signal cannot leak records into it.
    readonly property NotificationsService mergeService: NotificationsService {
        enabled: false
        profileRoot: "C:/fixtures/profile"
        stateDirectory: "C:/fixtures/profile/state"
        shellAssetsDirectory: "C:/fixtures/shell/assets"
        defaultExpireTimeout: 5000
        backend: fixture
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
    property int dismissalsBeforeImages: 0
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

        // --- Confined history path -------------------------------------------
        check(service.pathConfined, "declared profile paths are confined");
        check(service.pathError === "", "confined paths have no error");
        check(service.historyPath === "C:/fixtures/profile/state/notifs.json",
            "history path is under the isolated state directory: " + service.historyPath);
        check(service.historyPath.toLowerCase().indexOf("home") < 0
            && service.historyPath.toLowerCase().indexOf("xdg") < 0,
            "history path does not use HOME/XDG");

        service.profileRoot = "C:/fixtures/other";
        check(!service.pathConfined, "state outside the profile is rejected");
        check(service.pathError.indexOf("outside") >= 0, "outside path error names the boundary");
        check(service.historyPath === "", "invalid paths expose no write target");
        check(service.restoreHistory("[]") === false, "restore refuses an unconfined path");
        check(service.historyError.length > 0 && service.historyLoaded,
            "unconfined restore reports an error");
        service.profileRoot = "C:/fixtures/profile";

        service.stateDirectory = "";
        check(!service.pathConfined, "empty state directory is rejected");
        check(service.pathError.indexOf("missing") >= 0, "missing directory error");
        service.stateDirectory = "C:/fixtures/profile/state";

        service.profileRoot = "C:/fixtures/$HOME/profile";
        service.stateDirectory = "C:/fixtures/$HOME/profile/state";
        check(!service.pathConfined, "HOME fallback is rejected");
        check(service.pathError.indexOf("HOME/XDG") >= 0, "HOME fallback error");
        service.profileRoot = "C:/fixtures/profile";
        service.stateDirectory = "C:/fixtures/profile/state";
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
        local.image = "";
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
        check(record.image === "" && record.imageSourceRejected === false,
            "a local notification without an image keeps the fallback path");

        // --- Notification image source policy ---------------------------------
        // Only image:// provider icons and files already inside the staged
        // shell assets directory are accepted. The service never copies,
        // writes, lists, prunes or deletes a notification image file.
        const provider = service.validateImageSource("image://icon/dialog-information-symbolic");
        check(provider.accepted && provider.kind === "provider"
            && provider.canonical === "image://icon/dialog-information-symbolic"
            && provider.path === "", "provider icons are accepted as-is");
        check(service.validateImageSource("image://").accepted === false,
            "an empty provider URL is rejected");
        check(service.validateImageSource("image:///absolute/picture.png").accepted === false,
            "an absolute provider path is rejected");
        check(service.validateImageSource("image://icon/../escape").accepted === false,
            "provider traversal is rejected");

        const asset = service.validateImageSource("C:/fixtures/shell/assets/icon.png");
        check(asset.accepted && asset.kind === "assets"
            && asset.path === "C:/fixtures/shell/assets/icon.png"
            && asset.canonical === "file:///C:/fixtures/shell/assets/icon.png",
            "a staged asset is accepted with a built file URL: " + asset.canonical);
        const assetUrl = service.validateImageSource("file:///C:/fixtures/shell/assets/sub/icon.png");
        check(assetUrl.accepted
            && assetUrl.path === "C:/fixtures/shell/assets/sub/icon.png"
            && assetUrl.canonical === "file:///C:/fixtures/shell/assets/sub/icon.png",
            "a file URL is rebuilt from the validated asset path");
        const assetBackslash = service.validateImageSource("C:\\fixtures\\shell\\assets\\icon.png");
        check(assetBackslash.accepted
            && assetBackslash.canonical === "file:///C:/fixtures/shell/assets/icon.png",
            "a backslash asset path is rebuilt as a file URL");
        const assetCase = service.validateImageSource("c:/FIXTURES/SHELL/ASSETS/Sub/ICON.PNG");
        check(assetCase.accepted
            && assetCase.path === "C:/fixtures/shell/assets/Sub/ICON.PNG"
            && assetCase.canonical === "file:///C:/fixtures/shell/assets/Sub/ICON.PNG",
            "asset containment is case-insensitive and the URL uses the injected root");
        check(service.validateImageSource("C:/fixtures/shell/assets").accepted === false,
            "the assets directory itself is not an image");
        check(service.validateImageSource("C:/fixtures/shell/assetsevil/icon.png").accepted === false,
            "a prefix sibling of the assets directory is rejected");

        service.shellAssetsDirectory = "";
        check(service.validateImageSource("C:/fixtures/shell/assets/icon.png").accepted === false,
            "assets are rejected when the staged directory is not injected");
        service.shellAssetsDirectory = "C:/fixtures/shell/assets";

        const rejectedSources = [
            ["C:/elsewhere/picture.png", "a local path outside the staged assets"],
            ["C:/fixtures/profile/cache/notifs/a.png", "the removed image-cache directory"],
            ["C:/fixtures/profile/cache/a.png", "the profile cache directory"],
            ["C:/fixtures/profile/state/image.png", "the profile state directory"],
            ["C:/fixtures/profile/data/image.png", "the profile data directory"],
            ["C:/fixtures/shell/assets/%2e%2e/escape.png", "a percent-encoded dot-dot"],
            ["C:/fixtures/shell/assets/escape%5c.png", "a percent-encoded backslash"],
            ["C:/fixtures/shell/assets/100%.png", "a bare percent sign"],
            ["C:/fixtures/shell/assets/IMAGE~1.PNG", "an 8.3 short-name alias"],
            ["C:/fixtures/shell/assets/icon.", "a component ending in a dot"],
            ["C:/fixtures/shell/assets/icon ", "a component ending in a space"],
            ["C:/fixtures/shell/assets/../shell/assets/icon.png", "a dot-dot component"],
            ["C:/fixtures/shell/assets/./icon.png", "a dot component"],
            ["C:/fixtures/shell/assets/icon.png:stream", "an alternate data stream"],
            ["\\\\server\\share\\picture.png", "a backslash UNC share"],
            ["//server/share/picture.png", "a forward-slash UNC share"],
            ["\\\\?\\C:\\fixtures\\shell\\assets\\icon.png", "a \\\\?\\ device path"],
            ["\\\\.\\C:\\fixtures\\shell\\assets\\icon.png", "a \\\\.\\ device path"],
            ["file://server/share/picture.png", "a file URL with a UNC authority"],
            ["file:///fixtures/picture.png", "an external file URL"],
            ["http://example.invalid/picture.png", "an http URL"],
            ["https://example.invalid/picture.png", "an https URL"],
            ["data:image/png;base64,AAAA", "a data URL"],
            ["qrc:/icons/picture.png", "a qrc URL"],
            ["picture.png", "a relative path"],
            ["assets\\icon.png", "a backslash-relative path"],
            ["./picture.png", "a dot-relative path"],
            ["../picture.png", "a parent-relative path"],
            ["assets\\IMAGE~1.PNG", "a relative 8.3 short-name path"],
            ["C:picture.png", "a drive-relative path"],
            ["C:/", "a drive root"]
        ];
        for (const entry of rejectedSources) {
            const result = service.validateImageSource(entry[0]);
            check(result.accepted === false && result.canonical === "" && result.path === ""
                && result.reason.length > 0,
                entry[1] + " is rejected without a canonical path");
        }

        // A rejected source never reaches the record or the UI.
        const rejectedCount = service.rejectedImageSources;
        const rejectedImage = makeNotification(110, "Rejected image");
        rejectedImage.image = "file:///C:/elsewhere/banner.png";
        fixture.notificationReceived(rejectedImage);
        const rejectedRecord = service.list[0];
        check(rejectedRecord.image === "" && rejectedRecord.imageSourceRejected === true
            && rejectedRecord.imageSourceError.length > 0,
            "a rejected image is cleared so the original UI shows its fallback icon");
        check(service.rejectedImageSources === rejectedCount + 1,
            "rejected image sources are counted");
        check(service.lastRejectedImageSource === "file:///C:/elsewhere/banner.png",
            "the rejected source is recorded");
        rejectedRecord.close();

        const uncImage = makeNotification(111, "UNC image");
        uncImage.image = "\\\\server\\share\\picture.png";
        fixture.notificationReceived(uncImage);
        check(service.list[0].image === "" && service.list[0].imageSourceRejected === true,
            "a UNC image is cleared from the record");
        service.list[0].close();

        const cacheImage = makeNotification(112, "Profile cache image");
        cacheImage.image = "file:///C:/fixtures/profile/cache/notifs/picture.png";
        fixture.notificationReceived(cacheImage);
        check(service.list[0].image === "" && service.list[0].imageSourceRejected === true,
            "the removed profile cache is no longer an accepted image location");
        service.list[0].close();

        const stateImage = makeNotification(113, "Profile state image");
        stateImage.image = "file:///C:/fixtures/profile/state/picture.png";
        fixture.notificationReceived(stateImage);
        check(service.list[0].image === "" && service.list[0].imageSourceRejected === true,
            "the profile state directory is not an accepted image location");
        service.list[0].close();

        // An accepted asset is handed to the UI as a URL built from the
        // validated path, and a later image change is re-validated.
        const assetImage = makeNotification(114, "Asset image");
        assetImage.image = "C:\\fixtures\\shell\\assets\\banner.png";
        fixture.notificationReceived(assetImage);
        const assetRecord = service.list[0];
        check(assetRecord.image === "file:///C:/fixtures/shell/assets/banner.png"
            && assetRecord.imageSourceRejected === false,
            "an asset image is exposed as a built file URL");
        assetImage.image = "C:/fixtures/profile/cache/notifs/banner.png";
        check(assetRecord.image === "" && assetRecord.imageSourceRejected === true,
            "a later cache image clears the record again");
        assetImage.image = "image://icon/banner";
        check(assetRecord.image === "image://icon/banner" && !assetRecord.imageSourceRejected,
            "a provider image change is accepted");
        assetImage.image = "C:/fixtures/shell/assets/banner.png";
        check(assetRecord.image === "file:///C:/fixtures/shell/assets/banner.png",
            "the asset image is restored from the validated path, not the raw input");
        assetRecord.close();
        check(service.list.length === 1 && service.list[0] === record,
            "the image policy tests leave only the original local record");

        // Baseline for the dismiss-counter assertions: the image policy tests
        // above closed their own records.
        test.dismissalsBeforeImages = service.localDismissals;
        const dismissalsBeforeImages = test.dismissalsBeforeImages;

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
        check(service.localDismissals === dismissalsBeforeImages + 1
            && service.protectedDismissals === 0, "local dismiss counters");

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
        check(service.localDismissals === dismissalsBeforeImages + 2,
            "unlock increments the local dismiss count");

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

        // Restored history images are re-validated by the same policy, so a
        // persisted profile path is rejected and a persisted asset is rebuilt
        // as a UI URL.
        const persistedImages = JSON.stringify([
            {time: 5000, recordId: "restored-asset", notificationId: "9001", summary: "Asset", body: "", image: "C:\\fixtures\\shell\\assets\\restored.png"},
            {time: 4000, recordId: "restored-state", notificationId: "9002", summary: "State", body: "", image: "C:/fixtures/profile/state/restored.png"}
        ]);
        check(restoredService.restoreHistory(persistedImages) === true,
            "history with an asset image restores");
        const restoredAsset = restoredService.recordForNotificationId("9001");
        check(restoredAsset !== null
            && restoredAsset.image === "file:///C:/fixtures/shell/assets/restored.png"
            && restoredAsset.imageSourceRejected === false,
            "a restored asset image is re-validated and rebuilt as a UI URL");
        const restoredState = restoredService.recordForNotificationId("9002");
        check(restoredState !== null && restoredState.image === ""
            && restoredState.imageSourceRejected === true,
            "a restored profile state image is rejected");

        restoredService.failHistory("Fixture read failure");
        check(restoredService.historyError === "Fixture read failure"
            && restoredService.historyLoaded, "explicit history failure is exposed");

        // --- Replacement sends are refused, never reported unconfirmed --------
        check(service.replacementIdFromArgs(["-r", "42"]) === 42, "short -r takes a value");
        check(service.replacementIdFromArgs(["-r42"]) === 42, "an attached -r value is parsed");
        check(service.replacementIdFromArgs(["-r=42"]) === 42, "an equals -r value is parsed");
        check(service.replacementIdFromArgs(["--replace-id", "42"]) === 42,
            "the long replace-id option is parsed");
        check(service.replacementIdFromArgs(["--replace-id=42"]) === 42,
            "the long equals replace-id option is parsed");
        check(service.replacementIdFromArgs(["-a", "Caelestia", "-t", "100", "-A", "default=Open"]) === 0,
            "ordinary send arguments are not replacements");
        check(service.replacementIdFromArgs(["-r", "0"]) === 0,
            "a zero replace id is not a replacement");
        check(service.replacementIdFromArgs(["-r", "-1"]) === 0,
            "a negative replace id is not a replacement");
        check(service.replacementIdFromArgs(["-r", "not-a-number"]) === 0,
            "an invalid replace id is not a replacement");
        check(service.replacementIdFromArgs(["-r", "42.9"]) === 0,
            "a fractional replace id is not a replacement");
        check(service.replacementSendRefusal(["-a", "Caelestia"]) === "",
            "an ordinary send is not refused");
        const replacementRefusal = service.replacementSendRefusal(["-r", "42"]);
        check(replacementRefusal.indexOf("Replacement") >= 0
            && replacementRefusal.indexOf("not supported") >= 0,
            "a replacement send has a clear refusal: " + replacementRefusal);
        check(service.deliveryConfirmation === "idle" && !service.deliveryUnconfirmed
            && service.unconfirmedDeliveries === 0,
            "a refused replacement never starts or fails a delivery check");

        // Clear the open records before the delivery-confirmation tests.
        for (const open of service.list.slice())
            open.close();
        check(service.list.length === 0, "all local records can be closed");

        // --- Finding 4: startup history merges instead of destroying live ------
        mergeService.enabled = true;
        check(mergeService.status === "local", "the merge service is ready: " + mergeService.status);
        const liveBeforeHistory = makeNotification(700, "Live before history");
        liveBeforeHistory.body = "Live body";
        check(mergeService.handleNotification(liveBeforeHistory) === true,
            "a live notification arrives before the history load");
        const liveRecord = mergeService.list[0];
        const liveRecordId = String(liveRecord.recordId);
        check(liveRecord.notification === liveBeforeHistory,
            "the live record keeps its backend notification");

        const mergeHistory = JSON.stringify([
            {time: 5000, recordId: "persisted-700", notificationId: "700", summary: "Persisted 700", body: "Stale", image: ""},
            {time: 4000, recordId: liveRecordId, notificationId: "778", summary: "Colliding record id", body: "", image: ""},
            {time: 3000, recordId: "persisted-701", notificationId: "701", summary: "Persisted 701", body: "History body", image: "file:///C:/elsewhere/persisted.png"},
            {time: 2000, recordId: "persisted-702", notificationId: "702", summary: "Persisted 702", body: "", image: "C:/fixtures/shell/assets/persisted.png"},
            {time: 1500, recordId: "persisted-703", notificationId: "703", summary: "Persisted 703", body: "", image: "C:/fixtures/profile/cache/notifs/persisted.png"}
        ]);
        check(mergeService.restoreHistory(mergeHistory) === true,
            "history restore after a live arrival succeeds");
        check(mergeService.historyLoaded && mergeService.historyError === "",
            "the merged restore is clean");
        check(mergeService.list.length === 4,
            "the live record and the non-colliding history survive: " + mergeService.list.length);
        check(mergeService.list.indexOf(liveRecord) >= 0 && !liveRecord.closed,
            "the live record survives the restore");
        const mergedLive = mergeService.recordForNotificationId("700");
        check(mergedLive === liveRecord && mergedLive.summary === "Live before history",
            "the live record wins the id collision");
        check(mergeService.recordForNotificationId("778") === null,
            "a colliding record id is dropped");
        const mergedPersisted = mergeService.recordForNotificationId("701");
        check(mergedPersisted !== null && mergedPersisted.notification === null
            && mergedPersisted.summary === "Persisted 701", "non-colliding history is merged");
        check(mergedPersisted.imageSourceRejected === true && mergedPersisted.image === "",
            "a persisted unsafe image is revalidated and cleared");
        const mergedAsset = mergeService.recordForNotificationId("702");
        check(mergedAsset !== null
            && mergedAsset.image === "file:///C:/fixtures/shell/assets/persisted.png"
            && mergedAsset.imageSourceRejected === false,
            "a persisted asset image is re-validated and rebuilt as a UI URL");
        const mergedCache = mergeService.recordForNotificationId("703");
        check(mergedCache !== null && mergedCache.image === ""
            && mergedCache.imageSourceRejected === true,
            "a persisted profile cache image is rejected on restore");
        const mergedJson = JSON.parse(mergeService.serializeHistory());
        check(mergedJson.length === 4, "the merged set is what gets persisted");
        check(mergedJson.some(entry => entry.notificationId === "700")
            && mergedJson.some(entry => entry.notificationId === "701")
            && mergedJson.some(entry => entry.notificationId === "702")
            && mergedJson.some(entry => entry.notificationId === "703"),
            "the merged history keeps live and restored entries");
        check(service.list.length === 0, "the merge did not touch the other service");
        mergeService.enabled = false;
        check(mergeService.list.length === 0, "disabling the merge service clears it");

        // --- Finding 5: a send is confirmed only by a fresh delivery -----------
        const stale = makeNotification(999, "Pre-existing");
        fixture.notificationReceived(stale);
        check(service.liveRecordForNotificationId(999) !== null,
            "the pre-existing record is observable before the send");
        service.expectDelivery(999);
        check(service.deliveryConfirmation === "pending" && service.pendingDeliveryId === 999,
            "the send expectation is recorded");
        service.checkPendingDelivery();
        check(service.deliveryUnconfirmed === true && service.deliveryConfirmation === "forwarded",
            "an id that already existed never confirms a send");
        expectStatus("unconfirmed", "forwarded delivery is reported unconfirmed");
        check(service.reason.indexOf("forwarded") >= 0
            && service.reason.indexOf("unconfirmed") >= 0,
            "the reason reports forwarded/unconfirmed");
        check(service.unconfirmedDeliveries === 1, "unconfirmed counter");

        const unrelated = makeNotification(1000, "Unrelated delivery");
        fixture.notificationReceived(unrelated);
        check(service.deliveryConfirmation === "forwarded" && service.deliveryUnconfirmed === true,
            "an unrelated fresh delivery does not confirm the earlier send");
        expectStatus("unconfirmed", "the unconfirmed state survives an unrelated arrival");

        service.expectDelivery(1001, "Confirmed summary", "Confirmed body");
        check(service.deliveryConfirmation === "pending", "a new send starts pending");
        const confirmed = makeNotification(1001, "Confirmed summary");
        confirmed.body = "Confirmed body";
        fixture.notificationReceived(confirmed);
        check(service.deliveryConfirmation === "confirmed" && !service.deliveryUnconfirmed,
            "a fresh matching delivery confirms the send");
        check(service.confirmedDeliveries === 1, "confirmed deliveries are counted");
        expectStatus("local", "a confirmed delivery returns the service to local");

        service.expectDelivery(1002, "Mismatch summary", "Mismatch body");
        const mismatch = makeNotification(1002, "Other summary");
        mismatch.body = "Other body";
        fixture.notificationReceived(mismatch);
        check(service.deliveryConfirmation === "pending",
            "a fresh id with different content is not a confirmation");
        service.checkPendingDelivery();
        check(service.deliveryConfirmation === "forwarded" && service.deliveryUnconfirmed === true,
            "a content mismatch ends as forwarded/unconfirmed");
        check(service.unconfirmedDeliveries === 2, "second unconfirmed counter");

        for (const open of service.list.slice())
            open.close();
        check(service.list.length === 0, "delivery confirmation records can be closed");

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
        check(service.localDismissals >= test.dismissalsBeforeImages + 3, "async dismissal counted");
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
