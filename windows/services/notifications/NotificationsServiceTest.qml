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
        property int requestAccessCalls: 0
        property int setMirroringCalls: 0
        property bool lastMirroringValue: false
        signal notificationReceived(var notification)

        // Mirrors the native wrapper's explicit consent/enable path so the
        // fixture can prove when and how often the service reaches it.
        function requestAccess(): void {
            requestAccessCalls++;
        }

        function setMirroring(enabled): void {
            setMirroringCalls++;
            lastMirroringValue = enabled === true;
            mirrorSystemNotifications = enabled === true;
        }
    }

    readonly property FakeBackend fixture: FakeBackend {}

    readonly property NotificationsService service: NotificationsService {
        enabled: false
        profileRoot: "C:/fixtures/profile"
        stateDirectory: "C:/fixtures/profile/state"
        cacheDirectory: "C:/fixtures/profile/cache"
        shellAssetsDirectory: "C:/fixtures/shell/assets"
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

    // Independent backends/services keep each mirroring policy isolated so a
    // consent or dismissal test cannot mask another.
    readonly property FakeBackend mirrorFixture: FakeBackend {}
    readonly property FakeBackend dismissFixture: FakeBackend {}
    readonly property FakeBackend appOpenFixture: FakeBackend {}
    readonly property FakeBackend deniedFixture: FakeBackend {}
    readonly property FakeBackend autoFixture: FakeBackend {}

    readonly property NotificationsService mirrorService: NotificationsService {
        enabled: true
        mirrorOptIn: true
        profileRoot: "C:/fixtures/profile"
        stateDirectory: "C:/fixtures/profile/state"
        cacheDirectory: "C:/fixtures/profile/cache"
        defaultExpireTimeout: 5000
        backend: mirrorFixture
        accessPollBudget: 5
    }

    readonly property NotificationsService dismissService: NotificationsService {
        enabled: true
        mirrorOptIn: true
        windowsDismissOptIn: true
        profileRoot: "C:/fixtures/profile"
        stateDirectory: "C:/fixtures/profile/state"
        cacheDirectory: "C:/fixtures/profile/cache"
        backend: dismissFixture
    }

    readonly property NotificationsService appOpenService: NotificationsService {
        enabled: true
        mirrorOptIn: true
        appOpenOptIn: true
        profileRoot: "C:/fixtures/profile"
        stateDirectory: "C:/fixtures/profile/state"
        cacheDirectory: "C:/fixtures/profile/cache"
        backend: appOpenFixture
    }

    readonly property NotificationsService deniedService: NotificationsService {
        enabled: true
        mirrorOptIn: true
        profileRoot: "C:/fixtures/profile"
        stateDirectory: "C:/fixtures/profile/state"
        cacheDirectory: "C:/fixtures/profile/cache"
        backend: deniedFixture
        accessPollBudget: 5
    }

    readonly property NotificationsService autoService: NotificationsService {
        enabled: true
        mirrorOptIn: true
        profileRoot: "C:/fixtures/profile"
        stateDirectory: "C:/fixtures/profile/state"
        cacheDirectory: "C:/fixtures/profile/cache"
        backend: autoFixture
    }

    // Third isolated instance used only for the startup-history merge case: it
    // is enabled per test and delivered to directly, so the shared fixture
    // signal cannot leak records into it.
    readonly property NotificationsService mergeService: NotificationsService {
        enabled: false
        profileRoot: "C:/fixtures/profile"
        stateDirectory: "C:/fixtures/profile/state"
        cacheDirectory: "C:/fixtures/profile/cache"
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

    function expectStatusFor(target, expected, message): void {
        check(target.status === expected,
            message + ": status " + target.status + " != " + expected + " (" + target.reason + ")");
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

    readonly property Component actionComponent: Component {
        FakeAction {}
    }

    function makeAction(identifier, text): FakeAction {
        return actionComponent.createObject(test, {
            identifier: identifier,
            text: text
        });
    }

    function stageMirror(service, backend, access): void {
        backend.ready = true;
        backend.ownership = "owner";
        backend.mirrorSystemNotifications = false;
        backend.systemNotificationAccess = access;
        service.refreshAccess();
    }

    // The only supported consent path: an explicit call from Unspecified, then
    // Windows answering Allowed.
    function grantMirror(service, backend): void {
        backend.systemNotificationAccess = 0;
        service.refreshAccess();
        check(service.requestAccess(), "explicit consent request accepted");
        check(service.accessRequestsIssued === 1, "consent is requested exactly once");
        backend.systemNotificationAccess = 2;
        service.refreshAccess();
        check(service.accessState === "Allowed", "consent result is Allowed");
        check(service.mirrorWrites === 1, "mirroring is enabled once after Allowed");
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
        check(service.accessRequestsIssued === 0 && service.mirrorWrites === 0
            && fixture.requestAccessCalls === 0, "local mode never requests access");
        check(service.mirrorStatus === "disabled" && service.accessState === "Unknown",
            "mirroring stays disabled without its opt-in");

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
        check(record.image === "" && record.imageCachePending === false,
            "a local notification without an image has no cache request");

        // --- Confined cache acceptance and refusal ---------------------------
        record.image = "C:/fixtures/profile/cache/notifs/existing.png";
        record.imageCachePending = false;
        check(service.needsImageCache(record) === false,
            "an image already inside the confined notifs cache needs no copy");
        check(service.imageCachePath(record) === "", "no cache target for a cached image");
        check(service.applyCachedImage(record, "C:/fixtures/profile/cache/notifs/escape.png") === true,
            "image cache accepts a confined notifs path");
        check(record.image === "C:/fixtures/profile/cache/notifs/escape.png",
            "an accepted cache path updates the record");
        check(service.applyCachedImage(record, "C:/fixtures/profile/cache/other/escape.png") === false,
            "image cache refuses a path outside notifs");
        check(service.applyCachedImage(record, "C:/elsewhere/escape.png") === false,
            "image cache refuses an external path");
        check(service.applyCachedImage(record, "C:/fixtures/profile/cache/notifs/escape.txt") === false,
            "image cache refuses a non-image extension");
        check(service.applyCachedImage(record, "C:/fixtures/profile/state/escape.png") === false,
            "image cache only accepts its own cache directory");
        check(record.image === "C:/fixtures/profile/cache/notifs/escape.png",
            "rejected cache paths do not rewrite the image");
        const accepted = "C:/fixtures/profile/cache/notifs/1234567890abcdef.png";
        check(service.applyCachedImage(record, accepted) === true, "confined cache path accepted");
        check(record.image === accepted && record.imageCachePending === false,
            "accepted cache path updates the record");
        record.image = "";
        service.markImageCacheFailed(record);
        check(record.imageCachePending === false && service.imageCacheErrors === 1,
            "failed image cache is counted and cleared");

        // --- Finding 1: notification image source trust ------------------------
        const provider = service.validateImageSource("image://icon/dialog-information-symbolic");
        check(provider.accepted && provider.kind === "provider"
            && provider.canonical === "image://icon/dialog-information-symbolic",
            "provider icons are accepted as-is");
        check(service.validateImageSource("image://").accepted === false,
            "an empty provider URL is rejected");

        const stateImage = service.validateImageSource("file:///C:/fixtures/profile/state/image.png");
        check(stateImage.accepted && stateImage.kind === "data"
            && stateImage.canonical === "C:/fixtures/profile/state/image.png",
            "a profile file URL canonicalises to a local path");
        const cacheImage = service.validateImageSource("C:\\fixtures\\profile\\cache\\notifs\\a.png");
        check(cacheImage.accepted && cacheImage.kind === "cache"
            && cacheImage.canonical === "C:/fixtures/profile/cache/notifs/a.png",
            "backslash local paths canonicalise inside the cache");
        check(service.validateImageSource("c:/FIXTURES/PROFILE/CACHE/NOTIFS/A.png").accepted === true,
            "containment is case-insensitive on Windows");
        check(service.validateImageSource("C:/fixtures/profile/state/../cache/notifs/a.png").canonical
            === "C:/fixtures/profile/cache/notifs/a.png",
            "dot-dot is normalised before the containment check");
        check(service.validateImageSource("C:/fixtures/profile/state/../../escape.png").accepted === false,
            "traversal out of the profile is rejected");
        check(service.validateImageSource("C:/../escape.png").accepted === false,
            "traversal above the drive root is rejected");
        check(service.validateImageSource("C:/fixtures/shell/assets/icon.png").accepted === true
            && service.validateImageSource("C:/fixtures/shell/assets/icon.png").kind === "assets",
            "the staged shell assets directory is trusted");
        service.shellAssetsDirectory = "";
        check(service.validateImageSource("C:/fixtures/shell/assets/icon.png").accepted === false,
            "assets are rejected when the staged directory is not injected");
        service.shellAssetsDirectory = "C:/fixtures/shell/assets";

        const rejectedSources = [
            ["C:/elsewhere/picture.png", "a local path outside the profile"],
            ["file:///fixtures/picture.png", "an external file URL"],
            ["file://server/share/picture.png", "a file URL with a UNC authority"],
            ["\\\\server\\share\\picture.png", "a backslash UNC share"],
            ["//server/share/picture.png", "a forward-slash UNC share"],
            ["http://example.invalid/picture.png", "an http URL"],
            ["https://example.invalid/picture.png", "an https URL"],
            ["data:image/png;base64,AAAA", "a data URL"],
            ["qrc:/icons/picture.png", "a qrc URL"],
            ["picture.png", "a relative path"],
            ["./picture.png", "a dot-relative path"],
            ["../picture.png", "a parent-relative path"],
            ["C:picture.png", "a drive-relative path"],
            ["C:/", "a drive root"],
            ["C:/fixtures/profile/cache/notifs/a.png:stream", "an alternate data stream"]
        ];
        for (const entry of rejectedSources) {
            const result = service.validateImageSource(entry[0]);
            check(result.accepted === false && result.canonical === "" && result.reason.length > 0,
                entry[1] + " is rejected without a canonical path");
        }

        // A rejected source never reaches the record, the writer or the UI.
        const rejectedCount = service.rejectedImageSources;
        const rejectedImage = makeNotification(110, "Rejected image");
        rejectedImage.image = "file:///C:/elsewhere/banner.png";
        fixture.notificationReceived(rejectedImage);
        const rejectedRecord = service.list[0];
        check(rejectedRecord.image === "" && rejectedRecord.imageCachePending === false,
            "a rejected image is cleared so the original UI shows its fallback icon");
        check(rejectedRecord.imageSourceRejected === true
            && rejectedRecord.imageSourceError.length > 0, "the rejection is recorded on the record");
        check(service.rejectedImageSources === rejectedCount + 1,
            "rejected image sources are counted");
        check(service.lastRejectedImageSource === "file:///C:/elsewhere/banner.png",
            "the rejected source is recorded");
        check(service.imageCachePath(rejectedRecord) === ""
            && service.imageCacheRequests.indexOf(rejectedRecord) < 0,
            "a rejected source is never handed to a writer");
        check(service.imageCacheSlots.indexOf(rejectedRecord) < 0,
            "a rejected source takes no writer slot");
        rejectedRecord.close();

        const uncImage = makeNotification(111, "UNC image");
        uncImage.image = "\\\\server\\share\\picture.png";
        fixture.notificationReceived(uncImage);
        check(service.list[0].image === "" && service.list[0].imageSourceRejected === true,
            "a UNC image is cleared from the record");
        service.list[0].close();

        // An accepted profile image is canonicalised and handed to a writer.
        const dataImage = makeNotification(112, "Profile image");
        dataImage.image = "file:///C:/fixtures/profile/state/picture.png";
        fixture.notificationReceived(dataImage);
        const dataRecord = service.list[0];
        check(dataRecord.image === "C:/fixtures/profile/state/picture.png"
            && dataRecord.imageCachePending === true,
            "a profile image canonicalises and requests a cache copy");
        const dataTarget = service.imageCachePath(dataRecord);
        check(dataTarget.startsWith("C:/fixtures/profile/cache/notifs/")
            && /[0-9a-f]{16}\.png$/.test(dataTarget),
            "the cache target is confined and hash-keyed: " + dataTarget);
        check(dataTarget.indexOf("112") < 0, "the cache name does not embed the notification id");
        check(service.activeImageWriters === 1 && service.imageCacheSlot(0) === dataRecord,
            "the accepted image is handed to the first writer slot");

        // --- Finding 2: source-keyed files and a bounded writer pool ----------
        const repeatImage = makeNotification(113, "Same image");
        repeatImage.image = "C:/fixtures/profile/state/picture.png";
        fixture.notificationReceived(repeatImage);
        const repeatRecord = service.list[0];
        check(service.imageCachePath(repeatRecord) === dataTarget,
            "the same canonical source shares one cache file");
        check(service.activeImageWriters === 2 && service.maxConcurrentImageWriters === 2,
            "two writers may run concurrently");
        check(service.applyCachedImage(dataRecord, dataTarget) === true,
            "the first writer result is accepted");
        check(service.activeImageWriters === 1, "completing a writer frees its slot");
        check(service.applyCachedImage(repeatRecord, dataTarget) === true,
            "the shared image result is accepted");
        check(service.activeImageWriters === 0, "both writers complete");
        check(dataRecord.image === dataTarget && repeatRecord.image === dataTarget,
            "both records reference the shared cache file");
        check(service.imageCacheCompleted === 2, "completed writers are counted");
        dataRecord.close();
        repeatRecord.close();
        check(service.activeImageWriters === 0 && service.queuedImageWriters === 0,
            "closing records leaves no writer behind");

        // The FIFO queue is bounded and drops the oldest waiting request.
        check(service.maxQueuedImageWriters === 8, "the waiting queue has a fixed bound");
        const pooledRecords = [];
        for (let i = 0; i < 12; i++) {
            const notification = makeNotification(400 + i, "Pooled " + i);
            notification.image = "C:/fixtures/profile/state/pool-" + i + ".png";
            fixture.notificationReceived(notification);
            pooledRecords.push(service.list[0]);
        }
        check(service.activeImageWriters === 2, "only two writers are active");
        check(service.queuedImageWriters === 8,
            "the waiting queue is capped: " + service.queuedImageWriters);
        check(service.imageCacheDropped === 2,
            "the oldest waiting requests are dropped: " + service.imageCacheDropped);
        check(service.lastImageCacheDropReason.length > 0, "dropping records a reason");
        check(pooledRecords[2].imageCacheDropped === true && pooledRecords[3].imageCacheDropped === true,
            "the oldest waiting images were the ones dropped");
        check(pooledRecords[2].imageCachePending === false, "a dropped image is no longer pending");
        check(service.imageCacheSlot(0) === pooledRecords[0]
            && service.imageCacheSlot(1) === pooledRecords[1], "the first two images hold the slots");
        check(service.imageCacheQueue[0] === pooledRecords[4]
            && service.imageCacheQueue[7] === pooledRecords[11], "the queue is FIFO");

        const firstTarget = service.imageCachePath(pooledRecords[0]);
        check(service.applyCachedImage(pooledRecords[0], firstTarget) === true,
            "the first pooled writer result is accepted");
        check(service.imageCacheSlot(0) === pooledRecords[4],
            "the oldest waiting image takes the freed slot");
        check(service.queuedImageWriters === 7, "the queue advanced");
        const imageCacheErrors = service.imageCacheErrors;
        service.abortImageCache(pooledRecords[1], "fixture writer timeout");
        check(service.imageCacheSlot(1) === pooledRecords[5],
            "an aborted writer frees its slot");
        check(service.imageCacheErrors === imageCacheErrors + 1
            && service.lastImageCacheError === "fixture writer timeout",
            "writer failures are recorded in service state");
        check(pooledRecords[1].imageCachePending === false
            && pooledRecords[1].imageCacheError.length > 0,
            "an aborted record records its reason");
        for (const pooled of pooledRecords.slice())
            pooled.close();
        check(service.activeImageWriters === 0 && service.queuedImageWriters === 0
            && service.list.length === 1,
            "closing every pooled record drains the writer pool");

        // --- Finding 2: confined pruning and the hard quota --------------------
        service.imageCacheFiles = [];
        const removed = [];
        let cacheListing = null;
        service.imageCacheLister = () => cacheListing;
        service.imageCacheRemover = path => {
            removed.push(String(path));
            return true;
        };

        // Without a directory listing, the writer's registry still allows a
        // dismissed record's file to be pruned.
        const registryNotification = makeNotification(499, "Registry cache image");
        registryNotification.image = "C:/fixtures/profile/state/registry.png";
        fixture.notificationReceived(registryNotification);
        const registryRecord = service.list[0];
        const registryPath = service.imageCachePath(registryRecord);
        check(service.applyCachedImage(registryRecord, registryPath) === true,
            "the registry image is cached");
        removed.length = 0;
        let pruned = service.imageCachePruned;
        registryRecord.close();
        check(removed.length === 1 && removed[0] === registryPath,
            "dismissing the last reference prunes its cache file without a listing");
        check(service.imageCachePruned === pruned + 1, "the registry prune is counted");

        // A listing is filtered to the cache directory before anything is
        // deleted; unreferenced files are pruned and referenced files stay.
        const retainedNotification = makeNotification(500, "Retained cache image");
        retainedNotification.image = "C:/fixtures/profile/state/retained.png";
        fixture.notificationReceived(retainedNotification);
        const retainedRecord = service.list[0];
        const retainedPath = service.imageCachePath(retainedRecord);
        check(service.applyCachedImage(retainedRecord, retainedPath) === true,
            "the retained image is cached");
        cacheListing = [
            { path: retainedPath, savedAt: 10 },
            { path: "C:/fixtures/profile/cache/notifs/orphan.png", savedAt: 20 },
            { path: "C:/elsewhere/outside.png", savedAt: 30 },
            { path: "C:/fixtures/profile/state/not-an-image.png", savedAt: 40 },
            { path: "C:/fixtures/profile/cache/notifs/../notifs/traversal.png", savedAt: 50 }
        ];
        removed.length = 0;
        pruned = service.imageCachePruned;
        service.pruneImageCacheFiles();
        check(removed.indexOf(retainedPath) < 0, "a referenced cache file is retained");
        check(removed.indexOf("C:/fixtures/profile/cache/notifs/orphan.png") >= 0,
            "an unreferenced cache file is pruned");
        check(removed.indexOf("C:/fixtures/profile/cache/notifs/traversal.png") >= 0,
            "a traversal entry is canonicalised and pruned");
        check(removed.indexOf("C:/elsewhere/outside.png") < 0
            && removed.indexOf("C:/fixtures/profile/state/not-an-image.png") < 0,
            "entries outside the image cache are never deleted");
        check(removed.every(path => path.toLowerCase().startsWith("c:/fixtures/profile/cache/notifs/")),
            "every deletion is confined to the image cache");
        check(service.imageCachePruned === pruned + 2, "pruned files are counted");
        cacheListing = [{ path: retainedPath, savedAt: 10 }];
        removed.length = 0;
        retainedRecord.close();
        check(removed.length === 1 && removed[0] === retainedPath,
            "dismissing the last reference prunes the retained cache file");

        // The hard quota evicts the oldest referenced file first.
        service.maxImageCacheFiles = 2;
        const quotaPaths = [
            "C:/fixtures/profile/cache/notifs/oldest.png",
            "C:/fixtures/profile/cache/notifs/middle.png",
            "C:/fixtures/profile/cache/notifs/newest.png"
        ];
        const quotaRecords = [];
        for (let i = 0; i < quotaPaths.length; i++) {
            const notification = makeNotification(510 + i, "Quota " + i);
            notification.image = quotaPaths[i];
            fixture.notificationReceived(notification);
            const quotaImageRecord = service.list[0];
            check(quotaImageRecord.image === quotaPaths[i], "a cached image is kept as-is: " + i);
            quotaRecords.push(quotaImageRecord);
        }
        cacheListing = [
            { path: quotaPaths[0], savedAt: 1 },
            { path: quotaPaths[1], savedAt: 2 },
            { path: quotaPaths[2], savedAt: 3 }
        ];
        removed.length = 0;
        const evicted = service.imageCacheEvicted;
        service.pruneImageCacheFiles();
        check(removed.length === 1 && removed[0] === quotaPaths[0],
            "the oldest referenced cache file is evicted first: " + JSON.stringify(removed));
        check(quotaRecords[0].image === "" && quotaRecords[0].imageSourceRejected === false,
            "an evicted file is forgotten without marking its source untrusted");
        check(quotaRecords[1].image === quotaPaths[1] && quotaRecords[2].image === quotaPaths[2],
            "newer cache files survive the quota");
        check(service.imageCacheEvicted === evicted + 1, "evictions are counted");

        service.imageCacheLister = null;
        service.imageCacheRemover = null;
        service.maxImageCacheFiles = 64;
        service.imageCacheFiles = [];
        for (const cached of service.list.slice()) {
            if (cached !== record)
                cached.close();
        }
        check(service.list.length === 1 && service.list[0] === record
            && service.activeImageWriters === 0 && service.queuedImageWriters === 0,
            "the image-cache tests leave only the original local record");

        // Baseline for the dismiss-counter assertions: the image source and
        // cache tests above closed their own records.
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

        restoredService.failHistory("Fixture read failure");
        check(restoredService.historyError === "Fixture read failure"
            && restoredService.historyLoaded, "explicit history failure is exposed");

        // --- Mirroring: every access state -----------------------------------
        stageMirror(mirrorService, mirrorFixture, 0);
        check(mirrorService.mirrorStaged, "the mirror opt-in stages mirroring");
        check(mirrorService.accessState === "Unspecified",
            "un-queried access is the undecided consent state");
        check(mirrorService.canRequestAccess, "consent is available from Unspecified");
        check(mirrorService.accessRequestsIssued === 0 && mirrorFixture.requestAccessCalls === 0,
            "staging issued no access request");

        const accessStates = [
            [0, "Unspecified", true],
            [1, "Unspecified", true],
            [2, "Allowed", false],
            [3, "Denied", false],
            [4, "Unavailable", false],
            [9, "Unknown", false],
            [-1, "Unknown", false]
        ];
        for (const entry of accessStates) {
            mirrorFixture.systemNotificationAccess = entry[0];
            mirrorService.refreshAccess();
            check(mirrorService.accessState === entry[1],
                "access " + entry[0] + " maps to " + entry[1] + ": " + mirrorService.accessState);
            check(mirrorService.canRequestAccess === entry[2],
                "consent availability for " + entry[1]);
        }

        // Refusal for every state except Unspecified, without a single request.
        for (const deniedValue of [2, 3, 4, 9]) {
            mirrorFixture.systemNotificationAccess = deniedValue;
            mirrorService.refreshAccess();
            check(!mirrorService.requestAccess(),
                "access " + deniedValue + " refuses the consent call");
        }
        check(mirrorService.accessRequestsIssued === 0
            && mirrorService.accessRequestRefusals === 4
            && mirrorFixture.requestAccessCalls === 0,
            "refused consent never reaches the backend");

        mirrorFixture.systemNotificationAccess = 3;
        mirrorService.refreshAccess();
        check(mirrorService.mirrorStatus === "denied"
            && mirrorService.settingsActionRequired,
            "denied access exposes the settings action");

        // One explicit request from Unspecified, then no retry.
        mirrorFixture.systemNotificationAccess = 0;
        mirrorService.refreshAccess();
        check(mirrorService.requestAccess(), "the explicit consent call is accepted once");
        check(mirrorService.accessRequestsIssued === 1 && mirrorService.consentAttempts === 1
            && mirrorFixture.requestAccessCalls === 1,
            "exactly one access request reaches the backend");
        check(mirrorService.consentPending && !mirrorService.canRequestAccess,
            "a pending request hides the consent button");
        mirrorService.checkConsentTimeout();
        check(!mirrorService.consentPending && mirrorService.consentTimedOut
            && mirrorService.mirrorStatus === "timed-out",
            "an unanswered request times out instead of retrying");
        check(!mirrorService.requestAccess() && mirrorService.accessRequestsIssued === 1
            && mirrorFixture.requestAccessCalls === 1,
            "consent is never requested repeatedly");

        // Allowed enables mirroring exactly once and leaves local delivery on.
        mirrorFixture.systemNotificationAccess = 2;
        mirrorService.refreshAccess();
        check(mirrorService.accessState === "Allowed" && mirrorService.mirrorStatus === "allowed",
            "allowed is exposed");
        check(mirrorService.mirrorWrites === 1 && mirrorFixture.setMirroringCalls === 1
            && mirrorFixture.lastMirroringValue === true,
            "mirroring is enabled once after Allowed");
        check(mirrorService.mirroringApplied && mirrorService.mirroringRequested
            && !mirrorService.mirroringUnexpected,
            "the staged enable is not treated as unexpected mirroring");
        mirrorService.refreshAccess();
        mirrorService.refreshAccess();
        check(mirrorService.mirrorWrites === 1 && mirrorFixture.setMirroringCalls === 1,
            "mirroring is never written repeatedly");
        expectStatusFor(mirrorService, "local", "local delivery continues with mirroring allowed");

        // Mirrored record identification uses only the toast hints.
        const mirroredNotification = makeNotification(501, "Windows toast");
        mirroredNotification.appName = "Windows Terminal";
        mirroredNotification.appIcon = "terminal";
        mirroredNotification.hints = {
            "x-windows-toast-id": 7,
            "x-windows-aumid": "Microsoft.WindowsTerminal_8wekyb3d8bbwe!App"
        };
        const mirroredAction = makeAction("default", "Open");
        mirroredNotification.actions = [mirroredAction];
        mirrorFixture.notificationReceived(mirroredNotification);
        const mirroredRecord = mirrorService.list[0];
        check(mirroredRecord.mirrored === true && mirroredRecord.local === false,
            "toast hints identify a mirrored record");
        check(mirroredRecord.appName === "Windows Terminal"
            && mirroredRecord.appIcon === "terminal",
            "mirrored records use the original app name/icon fields");
        check(mirroredRecord.hints["x-windows-toast-id"] === 7, "toast identity is preserved");
        check(mirrorService.mirroredCount === 1, "mirrored records are counted");
        check(mirroredRecord.actions[0].disabled === true,
            "app-open is disabled without its opt-in");

        const beforeRefusal = mirroredAction.invokeCalls;
        mirroredRecord.actions[0].invoke();
        check(mirroredAction.invokeCalls === beforeRefusal,
            "app-open refusal does not invoke the native action");
        check(mirrorService.appOpenRefusals === 1, "app-open refusal is counted");

        // Dismissing a mirrored record without the opt-in stays local.
        mirroredRecord.close();
        check(mirroredNotification.dismissCalls === 0,
            "mirrored dismissal is local-only without the opt-in");
        check(mirrorService.mirroredLocalDismissals === 1
            && mirrorService.windowsDismissals === 0
            && mirrorService.protectedDismissals === 1,
            "local-only mirrored dismissal counters");
        check(mirrorService.list.length === 0, "local-only dismissal removed the UI record");

        // An aumid-only record is mirrored too, and local delivery is unaffected.
        const aumidOnly = makeNotification(502, "Aumid only");
        aumidOnly.hints = {"x-windows-aumid": "Contoso!App"};
        mirrorFixture.notificationReceived(aumidOnly);
        check(mirrorService.list[0].mirrored === true,
            "the aumid hint alone identifies a mirrored record");
        const localAlongside = makeNotification(503, "Local alongside mirror");
        mirrorFixture.notificationReceived(localAlongside);
        check(mirrorService.list[0].mirrored === false
            && mirrorService.list[0].local === true,
            "a notification without toast hints stays local");

        // Mirrored records are not persisted; local records are.
        const mirrorHistory = mirrorService.serializeHistory();
        const mirrorHistoryEntries = JSON.parse(mirrorHistory);
        check(mirrorHistoryEntries.length === 1
            && mirrorHistoryEntries[0].notificationId === "503",
            "mirrored records are not serialized to history");
        check(mirrorHistory.indexOf("x-windows") < 0,
            "history carries no Windows toast identity");
        check(restoredService.restoreHistory(mirrorHistory)
            && restoredService.list.length === 1
            && restoredService.list[0].mirrored === false,
            "restored history is never marked mirrored");

        // --- Opted-in Windows dismissal ---------------------------------------
        stageMirror(dismissService, dismissFixture, 0);
        grantMirror(dismissService, dismissFixture);
        check(dismissService.windowsDismissPermitted, "dismiss opt-in is staged");
        const dismissToast = makeNotification(601, "Dismissible toast");
        dismissToast.hints = {"x-windows-toast-id": 11};
        dismissFixture.notificationReceived(dismissToast);
        check(dismissService.list.length === 1, "dismissal fixture record arrived");
        dismissService.list[0].close();
        check(dismissToast.dismissCalls === 1,
            "opted-in dismissal removes the real Windows toast");
        check(dismissService.windowsDismissals === 1
            && dismissService.protectedDismissals === 0
            && dismissService.mirroredLocalDismissals === 0,
            "opted-in dismissal counters");

        // --- Opted-in app-open -------------------------------------------------
        stageMirror(appOpenService, appOpenFixture, 0);
        grantMirror(appOpenService, appOpenFixture);
        check(appOpenService.appOpenPermitted, "app-open opt-in is staged");
        const openToast = makeNotification(602, "Openable toast");
        openToast.hints = {"x-windows-toast-id": 12};
        const openAction = makeAction("default", "Open");
        openToast.actions = [openAction];
        appOpenFixture.notificationReceived(openToast);
        const openRecord = appOpenService.list[0];
        check(openRecord.actions[0].disabled === false,
            "app-open is enabled with its opt-in");
        openRecord.actions[0].invoke();
        check(openAction.invokeCalls === 1, "opted-in app-open invokes the native action");
        check(appOpenService.appOpenInvocations === 1
            && appOpenService.appOpenRefusals === 0,
            "opted-in app-open counters");

        // A local action is never gated by the app-open opt-in.
        const localAction = makeAction("default", "Open");
        const localOpen = makeNotification(603, "Local action");
        localOpen.actions = [localAction];
        mirrorFixture.notificationReceived(localOpen);
        const localOpenRecord = mirrorService.recordForNotificationId(603);
        check(localOpenRecord.actions[0].disabled === false,
            "local actions are never disabled");
        localOpenRecord.actions[0].invoke();
        check(localAction.invokeCalls === 1, "local action remains invokable");

        // --- Bounded denied polling -------------------------------------------
        stageMirror(deniedService, deniedFixture, 0);
        check(deniedService.requestAccess(), "denied path starts with one explicit request");
        deniedFixture.systemNotificationAccess = 3;
        deniedService.refreshAccess();
        check(deniedService.accessState === "Denied" && deniedService.mirrorStatus === "denied",
            "denied access state is exposed");
        check(deniedService.mirrorWrites === 0 && deniedFixture.setMirroringCalls === 0,
            "denied access never enables mirroring");
        check(!deniedService.deniedPollingActive,
            "denied polling stays off while the center is hidden");
        deniedService.centerVisible = true;
        check(deniedService.deniedPollingActive,
            "denied polling starts while the center is visible");
        check(deniedService.pollAccess() && deniedService.pollAccess(),
            "denied polls within the budget succeed");
        check(deniedService.deniedPolls === 2, "denied polls are counted");
        deniedService.centerVisible = false;
        check(!deniedService.deniedPollingActive && !deniedService.pollAccess(),
            "hiding the center stops denied polling immediately");
        check(deniedService.deniedPolls === 2, "hidden center issues no poll");
        deniedService.centerVisible = true;
        while (deniedService.pollAccess()) {}
        check(deniedService.deniedPolls === deniedService.accessPollBudget,
            "denied polling is bounded to its budget");
        check(deniedService.deniedPollExhausted && !deniedService.deniedPollingActive,
            "denied polling stops at the budget");
        deniedService.centerVisible = false;
        deniedService.centerVisible = true;
        check(!deniedService.deniedPollingActive, "visibility does not reset the budget");
        check(deniedService.accessRequestsIssued === 1
            && deniedFixture.requestAccessCalls === 1,
            "denied access never retries the prompt");
        deniedService.noteSettingsOpened();
        check(deniedService.settingsOpenRequests === 1,
            "the settings action is recorded as explicit");

        // --- Clear the open records before the delivery-confirmation tests.
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
            {time: 2000, recordId: "persisted-702", notificationId: "702", summary: "Persisted 702", body: "", image: "C:/fixtures/profile/state/persisted.png"}
        ]);
        check(mergeService.restoreHistory(mergeHistory) === true,
            "history restore after a live arrival succeeds");
        check(mergeService.historyLoaded && mergeService.historyError === "",
            "the merged restore is clean");
        check(mergeService.list.length === 3,
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
        const mergedCached = mergeService.recordForNotificationId("702");
        check(mergedCached.image === "C:/fixtures/profile/state/persisted.png"
            && mergedCached.imageCachePending === true,
            "a persisted profile image is canonicalised and re-queued");
        const mergedJson = JSON.parse(mergeService.serializeHistory());
        check(mergedJson.length === 3, "the merged set is what gets persisted");
        check(mergedJson.some(entry => entry.notificationId === "700")
            && mergedJson.some(entry => entry.notificationId === "701")
            && mergedJson.some(entry => entry.notificationId === "702"),
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
        check(service.imageCacheSlots.length === 0 && service.imageCacheQueue.length === 0,
            "disable clears the writer pool");
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
        // A staged service that was never asked must not have requested access
        // after the event loop ran: consent cannot come from timers or startup.
        check(test.autoService.accessRequestsIssued === 0
            && test.autoFixture.requestAccessCalls === 0
            && test.autoService.mirrorWrites === 0,
            "staging never triggers an automatic access request");
        check(test.autoService.accessState === "Unspecified"
            && test.autoService.canRequestAccess
            && !test.autoService.consentPending,
            "the un-requested state stays consent-eligible and idle");

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
