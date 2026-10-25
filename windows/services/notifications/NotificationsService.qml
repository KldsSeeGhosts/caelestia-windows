import QtQuick

// Windows adaptation of the bounded parts of services/Notifs.qml and
// services/NotifData.qml. This object has no Quickshell import, constructs no
// native server, and performs no file or image reads or writes itself: the
// singleton facade owns FileView persistence and the injected directory
// listing/removal, and the host owns the bounded image-cache writer. Backends,
// paths and translations may be injected in tests.
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
    property int confirmedDeliveries: 0
    property int imageCacheErrors: 0
    property int pendingDeliveryId: 0
    property bool deliveryUnconfirmed: false
    property int nextRecordId: 1

    // Delivery confirmation. A send is only confirmed by a delivery observed
    // after it: the arrival sequence is monotonic, and a matching record must
    // have been received after expectDelivery(). Anything else is reported as
    // forwarded/unconfirmed; a pre-existing id never confirms a send.
    // deliveryConfirmation is "idle", "pending", "confirmed" or "forwarded".
    property int arrivalSequence: 0
    property int pendingDeliverySequence: 0
    property bool pendingDeliveryContentKnown: false
    property string pendingDeliverySummary: ""
    property string pendingDeliveryBody: ""
    property string deliveryConfirmation: "idle"

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
        root.imageCacheSlots = [];
        root.imageCacheQueue = [];
        root.historyLoaded = false;
        root.historyError = "";
        root.pendingDeliveryId = 0;
        root.deliveryUnconfirmed = false;
        root.deliveryConfirmation = "idle";
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
            return "The send was forwarded to another notification owner or was not delivered by this shell, so it is unconfirmed. No system notification was requested or dismissed.";
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

        root.arrivalSequence++;

        const existing = root.list.find(record => !record.closed && record.notification === notification);
        if (existing) {
            existing.syncFromNotification();
            root.settlePendingDelivery();
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
        record.arrivalSequence = root.arrivalSequence;
        root.list = [record, ...root.list];
        root.deliveredNotifications++;
        if (record.imageCachePending)
            root.scheduleImageCache(record);
        root.settlePendingDelivery();
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
        root.releaseImageCache(record);

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
        root.pruneImageCacheFiles();
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

    // ---- Delivery confirmation (fresh-delivery only) ----------------------

    // A send's returned id may belong to a notification that already existed
    // (the backend forwards to another owner, or an id is reused). Confirmation
    // therefore requires a record received after this call whose id matches and
    // whose summary/body match when the caller supplied them.
    function expectDelivery(id, summary, body): void {
        const numeric = Number(id);
        root.pendingDeliveryId = Number.isFinite(numeric) && numeric > 0 ? numeric : 0;
        root.pendingDeliverySequence = root.arrivalSequence;
        root.pendingDeliveryContentKnown = summary !== undefined && summary !== null
            && body !== undefined && body !== null;
        root.pendingDeliverySummary = root.pendingDeliveryContentKnown ? String(summary) : "";
        root.pendingDeliveryBody = root.pendingDeliveryContentKnown ? String(body) : "";
        root.deliveryUnconfirmed = false;
        root.deliveryConfirmation = root.pendingDeliveryId === 0 ? "idle" : "pending";
        deliveryTimer.stop();
        if (root.pendingDeliveryId !== 0)
            deliveryTimer.restart();
    }

    function settlePendingDelivery(): void {
        if (root.pendingDeliveryId === 0)
            return;

        const id = String(root.pendingDeliveryId);
        const record = root.list.find(item => item.notification !== null
            && String(item.notificationId) === id
            && item.arrivalSequence > root.pendingDeliverySequence
            && (!root.pendingDeliveryContentKnown
                || (String(item.summary) === root.pendingDeliverySummary
                    && String(item.body) === root.pendingDeliveryBody))) ?? null;
        if (!record)
            return;

        root.confirmedDeliveries++;
        root.deliveryUnconfirmed = false;
        root.deliveryConfirmation = "confirmed";
        root.pendingDeliveryId = 0;
        deliveryTimer.stop();
    }

    function checkPendingDelivery(): void {
        if (root.pendingDeliveryId === 0)
            return;
        root.settlePendingDelivery();
        if (root.pendingDeliveryId === 0)
            return;
        root.deliveryUnconfirmed = true;
        root.deliveryConfirmation = "forwarded";
        root.unconfirmedDeliveries++;
        root.pendingDeliveryId = 0;
        deliveryTimer.stop();
    }

    function clearPendingDelivery(): void {
        root.pendingDeliveryId = 0;
        root.deliveryUnconfirmed = false;
        root.deliveryConfirmation = "idle";
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

        // Restoration merges instead of replacing. A live notification can
        // arrive before the asynchronous history load finishes; destroying it
        // here lost it and its arrival. Live records survive (and win every id
        // collision) and the merged set is what the facade persists back.
        if (!root.pathConfined) {
            root.historyLoaded = true;
            root.historyError = root.pathError || "The notification history path is not confined to the isolated profile.";
            root.finishHistoryRestore([]);
            return false;
        }

        if (data === undefined || data === null || String(data).trim() === "") {
            root.historyLoaded = true;
            root.finishHistoryRestore([]);
            return true;
        }

        let parsed;
        try {
            parsed = JSON.parse(String(data));
        } catch (error) {
            root.historyLoaded = true;
            root.historyError = "The notification history is not valid JSON.";
            root.finishHistoryRestore([]);
            return false;
        }

        if (!Array.isArray(parsed)) {
            root.historyLoaded = true;
            root.historyError = "The notification history is not a list.";
            root.finishHistoryRestore([]);
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
            // Persisted history can be edited outside this process, so its
            // image is re-validated exactly like a live one.
            const rawImage = String(entry.image ?? "");
            const image = root.validateImageSource(rawImage);
            if (rawImage !== "" && !image.accepted)
                root.reportRejectedImageSource(rawImage, image.reason);

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
                image: image.accepted ? image.canonical : "",
                imageCachePending: image.accepted && root.imageSourceNeedsCache(image.canonical),
                imageSourceRejected: rawImage !== "" && !image.accepted,
                imageSourceError: image.accepted ? "" : image.reason,
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

        root.historyLoaded = true;
        root.finishHistoryRestore(restored);
        return true;
    }

    // Keeps every live (backend-backed) record, drops the previously restored
    // historical ones, then appends the freshly parsed entries that do not
    // collide with a live id. Live records win; the merged list is persisted by
    // the facade's existing historyChanged save.
    function finishHistoryRestore(restored): void {
        const live = root.list.filter(record => !record.closed && record.notification !== null);
        for (const record of root.list.slice()) {
            if (live.indexOf(record) < 0)
                record.destroy();
        }

        const merged = live.slice();
        const recordIds = merged.map(record => String(record.recordId ?? "").toLowerCase());
        const notificationIds = merged.map(record => String(record.notificationId ?? "").toLowerCase())
            .filter(id => id !== "");

        for (const record of restored) {
            const recordId = String(record.recordId ?? "").toLowerCase();
            const notificationId = String(record.notificationId ?? "").toLowerCase();
            if ((recordId !== "" && recordIds.indexOf(recordId) >= 0)
                    || (notificationId !== "" && notificationIds.indexOf(notificationId) >= 0)) {
                record.destroy();
                continue;
            }
            if (recordId !== "")
                recordIds.push(recordId);
            if (notificationId !== "")
                notificationIds.push(notificationId);
            merged.push(record);
        }

        merged.sort((a, b) => b.time.getTime() - a.time.getTime());
        root.list = merged;
        for (const record of merged) {
            if (record.imageCachePending)
                root.scheduleImageCache(record);
        }
        root.pumpImageCache();
        root.pruneImageCacheFiles();
        root.historyChanged();
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
    // window under the upstream image-cache path. This object performs no
    // reads, stats, writes or deletions itself. It owns the source-trust
    // decision, the hash key and the bounded writer pool; the host owns the
    // actual window, and the facade supplies the directory listing/removal.
    //
    // Trusted sources are exactly: image:// provider icons, and local absolute
    // non-UNC files that canonicalise (separators, "." and ".." resolved,
    // case-insensitive containment) inside the isolated profile cache or state
    // directory, or the staged shell assets directory. Everything else is
    // rejected before any writer or UI image sees it, so a rejected path is
    // never opened.

    // Injected by the facade: the staged shell's assets directory.
    property string shellAssetsDirectory: ""

    // Injected by the facade: directory listing and deletion. The service only
    // ever hands them canonical paths inside imageCacheDirectory.
    property var imageCacheLister: null
    property var imageCacheRemover: null

    // Bounded writer pool. A host instantiates maxConcurrentImageWriters
    // writers and binds each to imageCacheSlot(index); the service hands slots
    // out FIFO, caps the waiting queue and records every drop.
    readonly property int maxConcurrentImageWriters: 2
    property int maxQueuedImageWriters: 8
    property int maxImageCacheFiles: 64
    property var imageCacheSlots: []
    property var imageCacheQueue: []
    property var imageCacheFiles: []
    property int imageCacheCompleted: 0
    property int imageCacheDropped: 0
    property int imageCacheEvicted: 0
    property int imageCachePruned: 0
    property string lastImageCacheDropReason: ""
    property string lastImageCacheError: ""

    property int rejectedImageSources: 0
    property string lastRejectedImageSource: ""
    property string lastImageSourceError: ""

    readonly property string canonicalStateDirectory: canonicalImagePath(normalizedStateDirectory)
    readonly property string canonicalCacheDirectory: canonicalImagePath(normalizedCacheDirectory)
    readonly property string canonicalImageCacheDirectory: canonicalImagePath(imageCacheDirectory)
    readonly property string canonicalShellAssetsDirectory: canonicalImagePath(shellAssetsDirectory)

    readonly property int activeImageWriters: imageCacheSlots.filter(record => record !== null && record !== undefined).length
    readonly property int queuedImageWriters: imageCacheQueue.length
    readonly property var imageCacheRequests: imageCacheSlots.filter(record => record !== null && record !== undefined).concat(imageCacheQueue)

    // Pure, Quickshell-free source validation. Returns
    // { accepted, kind, canonical, reason } where kind is one of "provider",
    // "cache", "data", "assets" or "rejected". No filesystem access happens
    // here, so a rejected source is never opened by callers.
    function validateImageSource(source): var {
        const reject = reason => ({
            accepted: false, kind: "rejected", canonical: "", reason: reason
        });

        if (source === undefined || source === null)
            return reject("The notification image source is missing.");
        const raw = String(source).trim();
        if (raw === "")
            return reject("The notification image source is empty.");

        const normalized = raw.replace(/\\/g, "/");
        if (normalized.toLowerCase().startsWith("image://")) {
            const provider = normalized.slice("image://".length);
            if (provider === "" || provider.startsWith("/") || provider.indexOf("..") >= 0)
                return reject("The notification image provider URL is invalid.");
            return {
                accepted: true, kind: "provider", canonical: "image://" + provider, reason: ""
            };
        }

        // A leading // is a UNC share or a protocol-relative URL on every
        // platform this object runs on. Neither is ever local to the profile.
        if (normalized.startsWith("//"))
            return reject("UNC and protocol-relative sources are not allowed.");

        let path = normalized;
        const scheme = /^([A-Za-z][A-Za-z0-9+.\-]*):/.exec(normalized);
        // A single letter is a drive, not a URL scheme.
        if (scheme && scheme[1].length > 1) {
            const name = scheme[1].toLowerCase();
            if (name !== "file")
                return reject("Only image:// and local file sources are allowed; " + name + ": is refused.");
            path = normalized.slice(scheme[0].length);
            if (path.startsWith("//")) {
                // file://<host>/<path>: any authority is a UNC share.
                const authority = path.slice(2);
                const slash = authority.indexOf("/");
                const host = slash < 0 ? authority : authority.slice(0, slash);
                if (host !== "")
                    return reject("UNC file URLs are not allowed.");
                path = slash < 0 ? "" : authority.slice(slash);
            }
            if (/^\/[A-Za-z]:\//.test(path))
                path = path.slice(1);
        }

        const canonical = canonicalImagePath(path);
        if (canonical === "")
            return reject("The notification image is not an absolute local path.");

        if (root.canonicalImageCacheDirectory !== ""
                && isUnder(canonical, root.canonicalImageCacheDirectory))
            return { accepted: true, kind: "cache", canonical: canonical, reason: "" };
        if (root.canonicalCacheDirectory !== "" && isUnder(canonical, root.canonicalCacheDirectory))
            return { accepted: true, kind: "cache", canonical: canonical, reason: "" };
        if (root.canonicalStateDirectory !== "" && isUnder(canonical, root.canonicalStateDirectory))
            return { accepted: true, kind: "data", canonical: canonical, reason: "" };
        if (root.canonicalShellAssetsDirectory !== ""
                && isUnder(canonical, root.canonicalShellAssetsDirectory))
            return { accepted: true, kind: "assets", canonical: canonical, reason: "" };
        return reject("The notification image is outside the isolated profile cache/state and the staged shell assets.");
    }

    // Lexical canonicalisation only: no filesystem access. Returns "" for a
    // relative, drive-relative, UNC or traversal-above-root path, an
    // alternate-data-stream name or a bare directory root.
    function canonicalImagePath(value): string {
        if (value === undefined || value === null)
            return "";
        const path = String(value).trim().replace(/\\/g, "/");
        const match = /^([A-Za-z]):\/(.*)$/.exec(path);
        if (!match)
            return "";

        const segments = match[2].split("/");
        const parts = [];
        for (const segment of segments) {
            if (segment === "" || segment === ".")
                continue;
            if (segment === "..") {
                if (parts.length === 0)
                    return "";
                parts.pop();
                continue;
            }
            if (segment.indexOf(":") >= 0)
                return "";
            parts.push(segment);
        }
        if (parts.length === 0)
            return "";
        return match[1].toUpperCase() + ":/" + parts.join("/");
    }

    function reportRejectedImageSource(source, reason): void {
        root.rejectedImageSources++;
        root.lastRejectedImageSource = String(source ?? "");
        root.lastImageSourceError = String(reason ?? "");
    }

    function imageSourceNeedsCache(source): bool {
        if (!root.pathConfined)
            return false;
        const validation = root.validateImageSource(source);
        if (!validation.accepted || validation.kind === "provider")
            return false;
        return !isUnder(validation.canonical, root.canonicalImageCacheDirectory);
    }

    function needsImageCache(record): bool {
        return !!record && !record.closed && root.imageSourceNeedsCache(record.image);
    }

    // The destination is keyed by a hash of the canonical source, so a repeat
    // of the same image always shares one cache file.
    function imageCachePath(record): string {
        if (!root.needsImageCache(record) || root.imageCacheDirectory === "")
            return "";
        const validation = root.validateImageSource(record.image);
        if (!validation.accepted)
            return "";
        const hash = notificationHash(validation.canonical.toLowerCase());
        return root.imageCacheDirectory + "/" + hash + ".png";
    }

    function imageCacheSlot(index): var {
        const slots = root.imageCacheSlots;
        if (index < 0 || index >= slots.length)
            return null;
        return slots[index] ?? null;
    }

    function scheduleImageCache(record): void {
        if (!record || record.closed || !root.list.includes(record) || !root.needsImageCache(record))
            return;
        if (root.imageCacheSlots.indexOf(record) >= 0 || root.imageCacheQueue.indexOf(record) >= 0)
            return;

        const queue = root.imageCacheQueue.slice();
        if (queue.length >= root.maxQueuedImageWriters) {
            const dropped = queue.shift();
            if (dropped) {
                dropped.imageCachePending = false;
                dropped.imageCacheDropped = true;
                dropped.imageCacheError = "The notification image-cache queue was full.";
                root.imageCacheDropped++;
                root.lastImageCacheDropReason = "The notification image-cache queue is full; the oldest waiting image was dropped.";
            }
        }
        queue.push(record);
        root.imageCacheQueue = queue;
        root.pumpImageCache();
    }

    function pumpImageCache(): void {
        if (!root.pathConfined) {
            root.imageCacheQueue = [];
            root.imageCacheSlots = [];
            return;
        }

        const slots = root.imageCacheSlots.slice();
        while (slots.length < root.maxConcurrentImageWriters)
            slots.push(null);

        const queue = [];
        for (const record of root.imageCacheQueue) {
            if (record && !record.closed && root.needsImageCache(record) && queue.indexOf(record) < 0)
                queue.push(record);
        }

        for (let i = 0; i < slots.length; i++) {
            if (slots[i] && (slots[i].closed || !root.needsImageCache(slots[i])))
                slots[i] = null;
            if (slots[i] === null && queue.length > 0) {
                const next = queue.shift();
                if (slots.indexOf(next) < 0) {
                    slots[i] = next;
                    next.imageCachePending = true;
                }
            }
        }

        root.imageCacheQueue = queue;
        root.imageCacheSlots = slots.slice(0, root.maxConcurrentImageWriters);
    }

    function completeImageCache(record): void {
        const index = root.imageCacheSlots.indexOf(record);
        if (index < 0)
            return;
        const slots = root.imageCacheSlots.slice();
        slots[index] = null;
        root.imageCacheSlots = slots;
        root.imageCacheCompleted++;
        root.pumpImageCache();
    }

    function abortImageCache(record, reason): void {
        const message = String(reason ?? "The notification image could not be written.");
        const slots = root.imageCacheSlots.slice();
        const index = slots.indexOf(record);
        if (index >= 0)
            slots[index] = null;
        const queue = root.imageCacheQueue.filter(item => item !== record);
        const wasQueued = queue.length !== root.imageCacheQueue.length;
        root.imageCacheSlots = slots;
        root.imageCacheQueue = queue;
        if (record) {
            record.imageCachePending = false;
            record.imageCacheError = message;
        }
        root.imageCacheErrors++;
        root.lastImageCacheError = message;
        if (index >= 0 || wasQueued)
            root.pumpImageCache();
    }

    function releaseImageCache(record): void {
        const slots = root.imageCacheSlots.slice();
        const index = slots.indexOf(record);
        if (index >= 0)
            slots[index] = null;
        const queue = root.imageCacheQueue.filter(item => item !== record);
        if (index < 0 && queue.length === root.imageCacheQueue.length)
            return;
        root.imageCacheSlots = slots;
        root.imageCacheQueue = queue;
        root.pumpImageCache();
    }

    function applyCachedImage(record, path): bool {
        if (!root.pathConfined || !record || !root.list.includes(record))
            return false;

        const validation = root.validateImageSource(path);
        if (!validation.accepted || validation.kind !== "cache" || validation.canonical === "")
            return false;
        if (!isUnder(validation.canonical, root.canonicalImageCacheDirectory)
                || !/\.png$/i.test(validation.canonical))
            return false;

        record.image = validation.canonical;
        record.imageCachePending = false;
        record.imageCacheError = "";
        root.registerImageCacheFile(validation.canonical);
        root.completeImageCache(record);
        return true;
    }

    function markImageCacheFailed(record): void {
        root.abortImageCache(record, root.lastImageCacheError !== ""
            ? root.lastImageCacheError : "The notification image could not be written.");
    }

    function registerImageCacheFile(path): void {
        const canonical = root.canonicalImagePath(path);
        if (canonical === "" || !root.pathConfined
                || !isUnder(canonical, root.canonicalImageCacheDirectory))
            return;
        const key = canonical.toLowerCase();
        const files = root.imageCacheFiles.filter(file => file && String(file.key ?? "").toLowerCase() !== key);
        files.push({ path: canonical, key: key, savedAt: Date.now() });
        root.imageCacheFiles = files;
        root.pruneImageCacheFiles();
    }

    function removeImageCacheFile(path): bool {
        if (typeof root.imageCacheRemover !== "function")
            return false;
        const canonical = root.canonicalImagePath(path);
        if (canonical === "" || root.canonicalImageCacheDirectory === ""
                || !isUnder(canonical, root.canonicalImageCacheDirectory))
            return false;
        return root.imageCacheRemover(canonical) === true;
    }

    function forgetImageCacheFile(path): void {
        const key = root.canonicalImagePath(path).toLowerCase();
        if (key === "")
            return;
        for (const record of root.list) {
            if (record && record.image && root.canonicalImagePath(record.image).toLowerCase() === key) {
                record.image = "";
                record.imageCachePending = false;
            }
        }
    }

    // Deletes cache files no retained record references, then enforces the hard
    // file quota oldest-first. Deletion only ever targets canonical paths under
    // imageCacheDirectory; a rejected or outside entry is skipped unread.
    function pruneImageCacheFiles(): void {
        if (!root.pathConfined || root.imageCacheDirectory === ""
                || typeof root.imageCacheRemover !== "function")
            return;

        const referenced = [];
        const addReference = value => {
            const canonical = root.canonicalImagePath(value);
            if (canonical !== "" && isUnder(canonical, root.canonicalImageCacheDirectory))
                referenced.push(canonical.toLowerCase());
        };
        for (const record of root.list) {
            if (record && !record.closed)
                addReference(record.image);
        }
        for (const record of root.imageCacheQueue)
            addReference(root.imageCachePath(record));
        for (const record of root.imageCacheSlots) {
            if (record)
                addReference(root.imageCachePath(record));
        }

        const listing = typeof root.imageCacheLister === "function" ? root.imageCacheLister() : null;
        const source = Array.isArray(listing) ? listing.concat(root.imageCacheFiles) : root.imageCacheFiles;
        const known = [];
        const seen = [];
        for (const entry of source) {
            const raw = typeof entry === "string" ? entry : String(entry?.path ?? "");
            const canonical = root.canonicalImagePath(raw);
            if (canonical === "" || !isUnder(canonical, root.canonicalImageCacheDirectory))
                continue;
            const key = canonical.toLowerCase();
            if (seen.indexOf(key) >= 0)
                continue;
            seen.push(key);
            const savedAt = entry && typeof entry === "object" ? Number(entry.savedAt ?? 0) : 0;
            known.push({ path: canonical, key: key, savedAt: Number.isFinite(savedAt) ? savedAt : 0 });
        }

        const retained = [];
        for (const file of known) {
            if (referenced.indexOf(file.key) >= 0) {
                retained.push(file);
                continue;
            }
            if (root.removeImageCacheFile(file.path))
                root.imageCachePruned++;
        }

        retained.sort((a, b) => a.savedAt - b.savedAt);
        if (retained.length > root.maxImageCacheFiles) {
            const excess = retained.length - root.maxImageCacheFiles;
            for (let i = 0; i < excess; i++) {
                const file = retained[i];
                if (!root.removeImageCacheFile(file.path))
                    continue;
                root.imageCacheEvicted++;
                root.forgetImageCacheFile(file.path);
            }
            retained.splice(0, excess);
        }
        root.imageCacheFiles = retained;
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
