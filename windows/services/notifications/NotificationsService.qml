import QtQuick

// Windows adaptation of the bounded parts of services/Notifs.qml and
// services/NotifData.qml. This object has no Quickshell import, constructs no
// native server, and performs no file or image writes itself: the singleton
// facade owns FileView persistence and the host owns the optional image cache.
// Backends, paths and translations may be injected in tests.
//
// The notification list is the original NotifData contract consumed by
// modules/notifications/*: summary, body, appName, appIcon, image, urgency,
// resident, hasActionIcons, hints, actions, expireTimeout, time/timeStr,
// popup/closed, lock()/unlock()/close() and a timer that can be stopped by the
// original hover state.
//
// Local delivery is unchanged from the first slice. System toast mirroring is a
// separate, opt-in state machine layered on top:
//
// - Nothing here requests Windows notification-listener access by itself. The
//   only path is requestAccess(), which the original notification-center UI
//   invokes from an explicit button and only while the state is Unspecified.
// - The pinned backend reports Unknown until its mirror worker exists, so while
//   mirroring is staged and no request has been made the service labels the
//   un-queried consent state Unspecified. The backend only shows an OS prompt
//   when Windows itself reports Unspecified.
// - Mirroring is enabled on the backend only after Windows reports Allowed, and
//   at most once per process. Denied/Unavailable never retry a prompt.
// - A mirrored record is identified only by the backend's x-windows-toast-id /
//   x-windows-aumid hints. Its dismissal removes the real Windows toast only
//   with the separate dismiss opt-in; app-open is a third opt-in. Mirrored
//   records are never serialized to history.
QtObject {
    id: root

    // The injected backend is the NativeNotificationBackend facade (or a test
    // fake) exposing: ready (bool), ownership (string), mirrorSystemNotifications
    // (bool), systemMirrorActive (bool), systemNotificationAccess (int),
    // notifySend(summary, body, args), and notificationReceived(notification).
    property var backend: null
    property bool enabled: false

    // ---- Mirroring opt-ins and consent state ------------------------------
    // Injected by the facade from the child-process variables. Local delivery
    // works without them; mirroring, Windows dismissal of mirrored records and
    // app-open each stay independent and default off.
    property bool mirrorOptIn: false
    property bool windowsDismissOptIn: false
    property bool appOpenOptIn: false
    property bool centerVisible: false
    property int consentTimeout: 60000
    property int accessPollInterval: 5000
    property int accessPollBudget: 5

    // The last access value published by the backend. The service caches it so
    // denied polling is counted and bounded instead of following a binding.
    property int reportedAccess: -1
    property bool consentRequested: false
    property bool consentPending: false
    property bool consentTimedOut: false
    property int consentAttempts: 0
    property int accessRequestsIssued: 0
    property int accessRequestRefusals: 0
    property int settingsOpenRequests: 0
    property int mirrorWrites: 0
    property bool mirroringApplied: false
    property int deniedPolls: 0
    property bool deniedPollExhausted: false
    property int mirroredCount: 0
    property int mirroredLocalDismissals: 0
    property int windowsDismissals: 0
    property int appOpenRefusals: 0
    property int appOpenInvocations: 0

    // A loader can supply a known component failure. Native delivery problems
    // are observed through status/deliveryUnconfirmed instead.
    property string backendError: ""

    // Injected so the pure object needs neither GlobalConfig nor Caelestia.I18n.
    property var translator: null
    property int defaultExpireTimeout: 5000
    property int fullscreenExpireTimeout: 2000
    property bool expirePopups: true

    // The bounded host does not stage do-not-disturb or sidebar state. A host
    // that does can suppress popups without inventing a Windows notification.
    property bool popupsSuppressed: false

    // Confinement roots injected by the facade. The history path is built from
    // stateDirectory, the image-cache path from cacheDirectory, and both must be
    // strict descendants of profileRoot. There is deliberately no HOME, XDG or
    // upstream Paths fallback in this object.
    property string profileRoot: ""
    property string stateDirectory: ""
    property string cacheDirectory: ""

    property bool historyLoaded: false
    property string historyError: ""

    // Counters used by the fixture and the native smoke. They never affect the
    // original UI contract.
    property int deliveredNotifications: 0
    property int localDismissals: 0
    property int protectedDismissals: 0
    property int unconfirmedDeliveries: 0
    property int imageCacheErrors: 0
    property int pendingDeliveryId: 0
    property bool deliveryUnconfirmed: false
    property int nextRecordId: 1

    signal historyChanged()

    onEnabledChanged: {
        if (root.enabled) {
            root.refreshAccess();
            return;
        }
        for (const record of root.list.slice()) {
            record.closed = true;
            record.notification = null;
            record.destroy();
        }
        root.list = [];
        root.historyLoaded = false;
        root.historyError = "";
        root.pendingDeliveryId = 0;
        root.deliveryUnconfirmed = false;
        if (typeof deliveryTimer !== "undefined")
            deliveryTimer.stop();
    }

    // ---- Path boundary -----------------------------------------------------

    readonly property string normalizedProfileRoot: normalizePath(profileRoot)
    readonly property string normalizedStateDirectory: normalizePath(stateDirectory)
    readonly property string normalizedCacheDirectory: normalizePath(cacheDirectory)

    readonly property bool pathConfined: {
        if (root.normalizedProfileRoot === "" || root.normalizedStateDirectory === ""
                || root.normalizedCacheDirectory === "")
            return false;
        if (!isAbsolutePath(root.normalizedProfileRoot)
                || !isAbsolutePath(root.normalizedStateDirectory)
                || !isAbsolutePath(root.normalizedCacheDirectory))
            return false;
        if (root.normalizedStateDirectory === root.normalizedCacheDirectory)
            return false;
        if (!isUnder(root.normalizedStateDirectory, root.normalizedProfileRoot)
                || !isUnder(root.normalizedCacheDirectory, root.normalizedProfileRoot))
            return false;

        const combined = (root.profileRoot + "|" + root.stateDirectory + "|" + root.cacheDirectory).toLowerCase();
        if (combined.indexOf("/home/") >= 0 || combined.indexOf("xdg_") >= 0
                || combined.indexOf("$home") >= 0 || combined.indexOf("${home}") >= 0
                || combined.indexOf("paths.state") >= 0 || combined.indexOf("paths.cache") >= 0)
            return false;

        return true;
    }

    readonly property string pathError: {
        if (root.normalizedProfileRoot === "")
            return "The isolated profile root is missing.";
        if (root.normalizedStateDirectory === "" || root.normalizedCacheDirectory === "")
            return "The isolated profile state or cache directory is missing.";
        if (!isAbsolutePath(root.normalizedProfileRoot)
                || !isAbsolutePath(root.normalizedStateDirectory)
                || !isAbsolutePath(root.normalizedCacheDirectory))
            return "The isolated profile paths must be absolute local paths.";
        if (root.normalizedStateDirectory === root.normalizedCacheDirectory)
            return "The state and cache directories must be distinct.";
        if (!isUnder(root.normalizedStateDirectory, root.normalizedProfileRoot))
            return "The notification history directory is outside the isolated profile.";
        if (!isUnder(root.normalizedCacheDirectory, root.normalizedProfileRoot))
            return "The notification image-cache directory is outside the isolated profile.";
        if (!root.pathConfined)
            return "The notification paths use a HOME/XDG fallback; only the isolated profile is allowed.";
        return "";
    }

    readonly property string historyPath: pathConfined ? normalizedStateDirectory + "/notifs.json" : ""
    readonly property string imageCacheDirectory: pathConfined ? normalizedCacheDirectory + "/notifs" : ""

    // ---- Backend and ownership state --------------------------------------

    readonly property bool backendPresent: enabled && !backendError && !!backend

    // Mirroring defaults true in the pinned backend, so the wrapper sets it
    // false at construction. Only the staged, consented path below may turn it
    // on. A true flag without the opt-in is refused rather than allowed to
    // deliver system notifications through the original UI.
    readonly property bool mirroringRequested: backend?.mirrorSystemNotifications === true
    readonly property bool mirroringOff: !mirroringRequested
    // With mirroring staged, a true backend flag is this service's own gated
    // write. Without the opt-in it is unexpected and refused, exactly as in the
    // local-delivery slice.
    readonly property bool mirroringUnexpected: mirroringRequested && !mirrorStaged
    readonly property bool systemMirrorActive: backend?.systemMirrorActive === true
    readonly property int systemNotificationAccess: {
        const value = backend?.systemNotificationAccess;
        return Number.isInteger(value) ? value : -1;
    }

    // ---- Mirroring state machine ------------------------------------------

    // Staged means the opt-in is present and a usable backend exists. It does
    // not mean access was requested or granted.
    readonly property bool mirrorStaged: enabled && mirrorOptIn && backendPresent && !contended
    readonly property bool windowsDismissPermitted: mirrorStaged && windowsDismissOptIn
    readonly property bool appOpenPermitted: mirrorStaged && appOpenOptIn

    // Unknown/Unspecified/Allowed/Denied/Unavailable, as required by the
    // backend contract. Without a staged mirror there is no measurement.
    readonly property string accessState: root.computeAccessState()

    readonly property bool canRequestAccess: mirrorStaged && backend?.ready === true
        && accessState === "Unspecified" && !consentRequested && !consentPending
    readonly property bool settingsActionRequired: mirrorStaged
        && (accessState === "Denied" || consentTimedOut)
    readonly property bool deniedPollingActive: mirrorStaged && accessState === "Denied"
        && centerVisible && !deniedPollExhausted && deniedPolls < accessPollBudget
    readonly property int deniedPollsRemaining: Math.max(0, accessPollBudget - deniedPolls)

    readonly property string mirrorStatus: {
        if (!enabled || !mirrorOptIn)
            return "disabled";
        if (backendError)
            return "unavailable";
        if (!backend || backend.ready !== true)
            return "initializing";
        if (contended)
            return "blocked";
        if (mirroringUnexpected)
            return "blocked";
        if (accessState === "Unavailable")
            return "unavailable";
        if (accessState === "Denied")
            return "denied";
        if (accessState === "Allowed")
            return "allowed";
        if (consentPending)
            return "pending";
        if (consentTimedOut)
            return "timed-out";
        if (accessState === "Unspecified")
            return "consent-required";
        return "unknown";
    }

    readonly property string mirrorReason: {
        switch (root.mirrorStatus) {
        case "disabled":
            return "System notification mirroring is off.";
        case "unavailable":
            return "Windows notification-listener access is unavailable on this system.";
        case "initializing":
            return "Waiting for the Windows notification server before mirroring can be offered.";
        case "blocked":
            return "Another notification owner is active. Mirroring and access requests stay disabled.";
        case "denied":
            return "Windows notification access is denied. No prompt is retried; open Windows settings to change it.";
        case "allowed":
            return "Windows notifications are mirrored here. Local notifications continue to work.";
        case "pending":
            return "Waiting for Windows to answer the explicit access request.";
        case "timed-out":
            return "Windows did not answer the access request. It is not retried automatically.";
        case "consent-required":
            return "Windows notifications can be mirrored after you allow access. Access is requested only from the button; it is never requested automatically.";
        default:
            return "Windows notification access has not been reported yet.";
        }
    }

    function computeAccessState(): string {
        if (!root.mirrorStaged)
            return "Unknown";

        switch (root.reportedAccess) {
        case 2:
            return "Allowed";
        case 3:
            return "Denied";
        case 4:
            return "Unavailable";
        case 1:
            return "Unspecified";
        case 0:
            // The pinned backend cannot publish Unspecified without creating
            // its mirror worker, which may prompt. Staged mirroring treats the
            // un-queried/unanswered value as undecided consent; an actual
            // request is still gated by consentRequested below.
            return "Unspecified";
        default:
            return "Unknown";
        }
    }

    function refreshAccess(): void {
        const value = root.backend?.systemNotificationAccess;
        root.reportedAccess = Number.isInteger(value) ? value : -1;

        if (root.consentPending && root.accessState !== "Unspecified") {
            root.consentPending = false;
            consentTimer.stop();
        }

        root.applyMirroring();
    }

    // The single, explicit consent action. It refuses unless the state is
    // Unspecified and no attempt was made in this process, so Windows is never
    // asked twice and Denied/Allowed/Unavailable never prompt again.
    function requestAccess(): bool {
        if (!root.canRequestAccess || !root.backend
                || typeof root.backend.requestAccess !== "function") {
            root.accessRequestRefusals++;
            return false;
        }

        root.consentRequested = true;
        root.consentPending = true;
        root.consentTimedOut = false;
        root.consentAttempts++;
        root.accessRequestsIssued++;
        consentTimer.restart();
        root.backend.requestAccess();
        root.refreshAccess();
        return true;
    }

    function checkConsentTimeout(): void {
        if (!root.consentPending)
            return;
        if (root.accessState !== "Unspecified") {
            root.consentPending = false;
            return;
        }
        root.consentPending = false;
        root.consentTimedOut = true;
    }

    // Bounded denied polling. The timer is bound to deniedPollingActive, which
    // includes centerVisible, so hiding the center stops it immediately. It
    // only re-reads the state the backend published; it never calls a native
    // request API.
    function pollAccess(): bool {
        if (!root.deniedPollingActive)
            return false;
        root.deniedPolls++;
        root.refreshAccess();
        if (root.deniedPolls >= root.accessPollBudget)
            root.deniedPollExhausted = true;
        return true;
    }

    function noteSettingsOpened(): void {
        root.settingsOpenRequests++;
    }

    function applyMirroring(): void {
        if (!root.mirrorStaged || root.accessState !== "Allowed" || !root.consentRequested)
            return;
        if (root.mirrorWrites > 0)
            return;
        if (!root.backend || typeof root.backend.setMirroring !== "function")
            return;

        root.mirrorWrites++;
        root.mirroringApplied = true;
        root.backend.setMirroring(true);
    }

    // The pinned backend performs the bounded five-second claim retry in C++
    // (server.cpp claimSession), but exposes no claim/ownership property to
    // QML. Values other than the known set are therefore "unknown" and never
    // guessed into "owner" or "contended".
    readonly property string ownership: {
        const value = backend?.ownership;
        return value === "owner" || value === "contended" || value === "forwarding"
            ? value : "unknown";
    }
    readonly property bool ownershipKnown: ownership !== "unknown"
    readonly property bool contended: enabled && ownership === "contended"
    readonly property bool ready: status === "local" || status === "unconfirmed"

    readonly property string status: {
        if (!enabled)
            return "disabled";
        if (backendError)
            return "unavailable";
        if (mirroringUnexpected)
            return "mirroring-blocked";
        if (!backend)
            return "initializing";
        if (backend.ready !== true)
            return "initializing";
        if (contended)
            return "contended";
        if (deliveryUnconfirmed)
            return "unconfirmed";
        return "local";
    }

    readonly property string reason: {
        if (!enabled)
            return "Windows notifications are disabled.";
        if (backendError)
            return backendError;
        if (mirroringUnexpected)
            return "System notification mirroring is on before any explicit consent; records are refused and no Windows notification is read or removed.";
        if (!backend)
            return "Waiting for the Windows notification server.";
        if (backend.ready !== true)
            return "Waiting for the Windows notification server to finish loading.";
        if (contended)
            return "Another notification owner is active. This shell is not delivering notifications and leaves the backend's bounded ownership retry alone.";
        if (deliveryUnconfirmed)
            return "A local notification was not delivered by this shell. Another notification owner may be active; no system notification was requested or dismissed.";
        if (root.mirrorStaged)
            return root.mirrorReason + " " + root.mirroringStateNote;
        return "Windows local notifications are delivered to this shell only. System notification mirroring is off; real Windows notifications are neither read nor removed.";
    }

    readonly property string mirroringStateNote: {
        if (!root.mirrorStaged)
            return "";
        switch (root.accessState) {
        case "Allowed":
            return "Mirrored records are shown with their original app name and icon and are not saved to history."
                + (root.windowsDismissPermitted
                    ? "" : " Dismissing one hides it here only.")
                + (root.appOpenPermitted ? "" : " Opening the source app stays disabled.");
        case "Denied":
            return "No access prompt is retried; use Windows settings.";
        case "Unavailable":
            return "This system does not offer notification-listener access.";
        default:
            return "Access is requested only from the mirroring button in the notification center.";
        }
    }

    readonly property string ownershipNote: ownershipKnown
        ? "" : "The pinned backend does not publish session-bus ownership; its five-second claim retry stays inside the backend."

    // ---- Records and the preserved Notifs contract ------------------------

    property var list: []
    readonly property var notClosed: list.filter(notification => !notification.closed)
    readonly property var popups: list.filter(notification => !notification.closed && notification.popup)
    readonly property int count: list.length
    readonly property int popupCount: popups.length

    readonly property Component _recordComponent: Component {
        NotifData {}
    }

    // The original notification card expects a NotificationUrgency enum value.
    // Keep the numeric constants local so the fixture needs no native module.
    readonly property int urgencyLow: 0
    readonly property int urgencyNormal: 1
    readonly property int urgencyCritical: 2

    readonly property Connections _backendConnections: Connections {
        target: root.backend
        enabled: root.enabled
        ignoreUnknownSignals: true

        function onNotificationReceived(notification): void {
            root.handleNotification(notification);
        }

        function onSystemNotificationAccessChanged(): void {
            root.refreshAccess();
        }

        function onReadyChanged(): void {
            root.refreshAccess();
        }
    }

    onBackendChanged: root.refreshAccess()

    function handleNotification(notification): bool {
        if (!deliveryAllowed() || !notification || typeof notification !== "object")
            return false;

        const id = String(notification.id ?? "");
        if (root.pendingDeliveryId !== 0 && id === String(root.pendingDeliveryId))
            clearPendingDelivery();

        // Any local delivery proves this server can receive its own local
        // path, so an earlier unconfirmed probe hint no longer applies.
        root.deliveryUnconfirmed = false;

        const existing = root.list.find(record => !record.closed && record.notification === notification);
        if (existing) {
            existing.syncFromNotification();
            return true;
        }

        const mirrored = root.isSystemNotification(notification);
        const record = root._recordComponent.createObject(root, {
            service: root,
            recordId: root.nextRecordId++ + "-" + Date.now(),
            notification: notification,
            popup: !root.popupsSuppressed,
            local: !mirrored,
            mirrored: mirrored
        });
        if (!record)
            return false;

        if (mirrored)
            root.mirroredCount++;
        root.list = [record, ...root.list];
        root.deliveredNotifications++;
        root.historyChanged();
        return true;
    }

    function deliveryAllowed(): bool {
        return root.enabled && root.backendPresent && root.backend.ready === true
            && !root.mirroringUnexpected && !root.contended;
    }

    // A mirrored/toast-backed notification carries the backend's Windows toast
    // hints (server.cpp onToastAdded). Only those two hints mark a record as a
    // real Windows notification; the app name/icon are ordinary fields.
    function isSystemNotification(notification): bool {
        const hints = notification?.hints;
        if (!hints || typeof hints !== "object")
            return false;
        return Object.prototype.hasOwnProperty.call(hints, "x-windows-toast-id")
            || Object.prototype.hasOwnProperty.call(hints, "x-windows-aumid");
    }

    // App-open on a mirrored record activates or launches another application.
    // It needs the separate opt-in, so the action object reports itself disabled
    // and invokeAction refuses even if a caller bypasses the button.
    function isActionDisabled(record, identifier): bool {
        return !!record && record.mirrored === true
            && String(identifier) === "default" && !root.appOpenPermitted;
    }

    function invokeAction(record, action): bool {
        if (!record || !action || typeof action.invoke !== "function")
            return false;

        if (root.isActionDisabled(record, action.identifier)) {
            root.appOpenRefusals++;
            return false;
        }

        if (record.mirrored === true && String(action.identifier) === "default")
            root.appOpenInvocations++;
        action.invoke();
        return true;
    }

    function recordForNotificationId(notificationId): var {
        const id = String(notificationId);
        // A live record wins over restored history because backend ids restart
        // at 1 in each process and can collide with a persisted id.
        const live = root.list.find(record => record.notification !== null
            && String(record.notificationId) === id);
        return live ?? root.list.find(record => String(record.notificationId) === id) ?? null;
    }

    function liveRecordForNotificationId(notificationId): var {
        const id = String(notificationId);
        return root.list.find(record => record.notification !== null
            && String(record.notificationId) === id) ?? null;
    }

    function findRecordById(recordId): var {
        const id = String(recordId);
        return root.list.find(record => String(record.recordId) === id) ?? null;
    }

    function handleExpiry(record): void {
        if (!record || record.closed || !root.list.includes(record))
            return;
        if (root.expirePopups || record.hasFullscreen)
            record.popup = false;
    }

    function removeRecord(record, dismiss): void {
        if (!record)
            return;
        record.closed = true;

        if ((record.locks?.size ?? 0) > 0)
            return;

        if (root.list.indexOf(record) < 0)
            return;

        root.list = root.list.filter(item => item !== record);

        if (dismiss && record.notification && record.local) {
            // Local-only removal. The local path never reaches a Windows toast.
            root.localDismissals++;
            record.notification.dismiss();
        } else if (dismiss && record.notification) {
            // A mirrored record. The backend's Notification.dismiss() removes
            // the real Windows toast (server.cpp deleteNotification), so it is
            // gated by the separate dismiss opt-in. Without it the record is
            // hidden locally and the Windows toast is left untouched.
            if (root.windowsDismissPermitted) {
                root.windowsDismissals++;
                record.notification.dismiss();
            } else {
                root.protectedDismissals++;
                root.mirroredLocalDismissals++;
            }
        }

        record.notification = null;
        record.destroy();
        root.historyChanged();
    }

    function dismiss(record): void {
        if (!record)
            return;
        if (record.closed) {
            // The original NotifData may already be marked closed but still
            // locked. Closing again is what releases it.
            if (record.locks?.size === 0)
                removeRecord(record, true);
            return;
        }
        record.close();
    }

    function clearAll(): void {
        for (const record of root.list.slice())
            record.close();
    }

    // ---- Delivery confirmation (bounded ownership hint) -------------------

    function expectDelivery(id): void {
        const numeric = Number(id);
        root.pendingDeliveryId = Number.isFinite(numeric) && numeric > 0 ? numeric : 0;
        root.deliveryUnconfirmed = false;
        deliveryTimer.stop();
        if (root.pendingDeliveryId !== 0)
            deliveryTimer.restart();
    }

    function checkPendingDelivery(): void {
        if (root.pendingDeliveryId === 0)
            return;
        if (liveRecordForNotificationId(root.pendingDeliveryId)) {
            clearPendingDelivery();
            return;
        }
        root.deliveryUnconfirmed = true;
        root.unconfirmedDeliveries++;
        root.pendingDeliveryId = 0;
        deliveryTimer.stop();
    }

    function clearPendingDelivery(): void {
        root.pendingDeliveryId = 0;
        root.deliveryUnconfirmed = false;
        deliveryTimer.stop();
    }

    readonly property Timer _deliveryTimer: Timer {
        id: deliveryTimer
        interval: 2500
        onTriggered: root.checkPendingDelivery()
    }

    // Bounded wait for Windows to answer the explicit access request. It never
    // re-requests; after the timeout the UI states that no answer arrived.
    readonly property Timer _consentTimer: Timer {
        id: consentTimer
        interval: root.consentTimeout
        onTriggered: root.checkConsentTimeout()
    }

    // Denied polling runs only while the notification center is visible and
    // stops at the budget even if it stays visible.
    readonly property Timer _accessPollTimer: Timer {
        interval: root.accessPollInterval
        repeat: true
        running: root.deniedPollingActive
        onTriggered: root.pollAccess()
    }

    // ---- History -----------------------------------------------------------

    function serializeHistory(): string {
        // Mirrored Windows toasts are live system state, not this shell's
        // history: they are re-read from Windows on the next mirror start and
        // persisting them would show stale records after the source app or
        // Windows removed the toast. Only records this shell owns are saved.
        const entries = root.list
            .filter(record => !record.closed && record.mirrored !== true)
            .map(record => ({
            time: new Date(record.time).getTime(),
            recordId: String(record.recordId ?? ""),
            notificationId: String(record.notificationId ?? ""),
            summary: String(record.summary ?? ""),
            body: String(record.body ?? ""),
            appIcon: String(record.appIcon ?? ""),
            appName: String(record.appName ?? ""),
            image: String(record.image ?? ""),
            expireTimeout: record.expireTimeout,
            urgency: record.urgency,
            resident: record.resident === true,
            hasActionIcons: record.hasActionIcons === true,
            actions: (record.actions ?? []).map(action => ({
                identifier: String(action.identifier ?? ""),
                text: String(action.text ?? "")
            })),
            local: record.local === true
        }));
        return JSON.stringify(entries);
    }

    function restoreHistory(data): bool {
        root.historyError = "";

        for (const record of root.list.slice())
            record.destroy();
        root.list = [];
        root.clearPendingDelivery();

        if (!root.pathConfined) {
            root.historyLoaded = true;
            root.historyError = root.pathError || "The notification history path is not confined to the isolated profile.";
            root.historyChanged();
            return false;
        }

        if (data === undefined || data === null || String(data).trim() === "") {
            root.historyLoaded = true;
            root.historyChanged();
            return true;
        }

        let parsed;
        try {
            parsed = JSON.parse(String(data));
        } catch (error) {
            root.historyLoaded = true;
            root.historyError = "The notification history is not valid JSON.";
            root.historyChanged();
            return false;
        }

        if (!Array.isArray(parsed)) {
            root.historyLoaded = true;
            root.historyError = "The notification history is not a list.";
            root.historyChanged();
            return false;
        }

        const restored = [];
        for (const entry of parsed) {
            if (!entry || typeof entry !== "object")
                continue;

            const time = Number(entry.time);
            const actions = Array.isArray(entry.actions)
                ? entry.actions.filter(action => action && typeof action === "object").map(action => ({
                    identifier: String(action.identifier ?? ""),
                    text: String(action.text ?? "")
                }))
                : [];

            const record = root._recordComponent.createObject(root, {
                service: root,
                recordId: String(entry.recordId ?? ("restored-" + root.nextRecordId++)),
                notification: null,
                popup: false,
                time: new Date(Number.isFinite(time) && time > 0 ? time : Date.now()),
                notificationId: String(entry.notificationId ?? entry.id ?? ""),
                summary: String(entry.summary ?? ""),
                body: String(entry.body ?? ""),
                appIcon: String(entry.appIcon ?? ""),
                appName: String(entry.appName ?? ""),
                image: String(entry.image ?? ""),
                expireTimeout: Number.isFinite(Number(entry.expireTimeout)) ? Number(entry.expireTimeout) : root.defaultExpireTimeout,
                urgency: Number.isInteger(entry.urgency) ? entry.urgency : root.urgencyNormal,
                resident: entry.resident === true,
                hasActionIcons: entry.hasActionIcons === true,
                historicalActions: actions,
                local: entry.local !== false,
                mirrored: false
            });
            if (record)
                restored.push(record);
        }

        restored.sort((a, b) => b.time.getTime() - a.time.getTime());
        root.list = restored;
        root.historyLoaded = true;
        root.historyChanged();
        return true;
    }

    function failHistory(message): void {
        root.historyError = String(message ?? "The notification history could not be read.");
        root.historyLoaded = true;
        root.historyChanged();
    }

    function historyContains(recordId): bool {
        return findRecordById(recordId) !== null;
    }

    function historyContainsNotificationId(notificationId): bool {
        return recordForNotificationId(notificationId) !== null;
    }

    // ---- Image-cache boundary ---------------------------------------------

    // The original NotifData cached remote images through a hidden native
    // window under the upstream image-cache path. This object only computes a
    // confined destination and accepts a saved path back; the host owns any
    // native writer. An image already served from the icon provider or the
    // confined cache never requests a copy.
    function needsImageCache(record): bool {
        if (!record || record.closed || !root.pathConfined)
            return false;
        const image = String(record.image ?? "");
        if (image === "" || image.startsWith("image://"))
            return false;
        return !isUnder(normalizePath(image), root.imageCacheDirectory);
    }

    readonly property var imageCacheRequests: list.filter(record => needsImageCache(record))

    function imageCachePath(record): string {
        if (!root.needsImageCache(record))
            return "";

        const cacheKey = String(record.appName ?? "") + String(record.summary ?? "")
            + String(record.notificationId ?? "") + String(record.image ?? "");
        const hash = notificationHash(cacheKey);
        return root.imageCacheDirectory + "/" + hash + ".png";
    }

    function applyCachedImage(record, path): bool {
        if (!root.pathConfined || !record || !root.list.includes(record))
            return false;
        const normalized = normalizePath(String(path ?? ""));
        if (normalized === "" || !isUnder(normalized, root.imageCacheDirectory))
            return false;
        record.image = path;
        record.imageCachePending = false;
        return true;
    }

    function markImageCacheFailed(record): void {
        if (record)
            record.imageCachePending = false;
        root.imageCacheErrors++;
    }

    // ---- Small path helpers ------------------------------------------------

    function normalizePath(value): string {
        if (value === undefined || value === null)
            return "";
        let path = String(value).replace(/\\/g, "/");
        while (path.length > 1 && path.endsWith("/"))
            path = path.slice(0, -1);
        return path;
    }

    function isAbsolutePath(path): bool {
        return /^[A-Za-z]:\//.test(path) || /^\/\/[^\/]/.test(path);
    }

    function isUnder(path, parent): bool {
        const candidate = normalizePath(path).toLowerCase();
        const base = normalizePath(parent).toLowerCase();
        if (candidate === "" || base === "")
            return false;
        return candidate.length > base.length && candidate.startsWith(base + "/");
    }

    function notificationHash(key): string {
        let h1 = 0xdeadbeef;
        let h2 = 0x41c6ce57;

        for (let i = 0; i < key.length; i++) {
            const ch = key.charCodeAt(i);
            h1 = Math.imul(h1 ^ ch, 2654435761);
            h2 = Math.imul(h2 ^ ch, 1597334677);
        }
        h1 = Math.imul(h1 ^ (h1 >>> 16), 2246822507);
        h1 ^= Math.imul(h2 ^ (h2 >>> 13), 3266489909);
        h2 = Math.imul(h2 ^ (h2 >>> 16), 2246822507);
        h2 ^= Math.imul(h1 ^ (h1 >>> 13), 3266489909);
        return (h2 >>> 0).toString(16).padStart(8, "0")
            + (h1 >>> 0).toString(16).padStart(8, "0");
    }

    function invokeHistoricalAction(record, identifier): void {
        // Restored history has no backend notification to invoke. Keep the
        // original object shape and consume the action without a process call.
        if (record && record.service)
            console.log("Caelestia notifications: historical action consumed:", identifier);
    }
}
