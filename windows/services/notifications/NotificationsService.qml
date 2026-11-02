import QtQuick

// Windows adaptation of the bounded parts of services/Notifs.qml and
// services/NotifData.qml. This object has no Quickshell import, constructs no
// native server, and performs no file or image reads, writes, listings or
// deletions: the singleton facade owns FileView persistence. A notification
// image is only ever accepted as an allowlisted image://icon theme name or as a
// file already inside the staged shell assets directory; no image is copied or
// cached. Bodies are sanitized of Markdown and HTML images before the original
// Markdown-rendering popup/sidebar can load them.
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
//   at most once per process. Denied/Unavailable never retry a prompt. The
//   consent-fix backend also keeps a process-lifetime request latch
//   (accessRequested); this object reconciles with it after a QML reload
//   instead of re-asking, and mirrored enable is withdrawn when access is
//   lost, the mirror opt-in is removed or the service becomes unavailable.
// - A mirrored record is identified only by the backend's x-windows-toast-id /
//   x-windows-aumid hints. Its dismissal removes the real Windows toast only
//   with the separate dismiss opt-in; app-open is a third opt-in that goes
//   through the backend's mirrored activation member, never the generic
//   action path whose native auto-close would dismiss the toast. Mirrored
//   records are never serialized to history.
QtObject {
    id: root

    // The injected backend is the NativeNotificationBackend facade (or a test
    // fake) exposing: ready (bool), ownership (string), mirrorSystemNotifications
    // (bool), systemMirrorActive (bool), systemNotificationAccess (int),
    // notifySend(summary, body, args), and notificationReceived(notification).
    // The pinned backend also exposes accessRequested (bool),
    // refreshAccessStatus() and activateMirrored(id); uses are feature-detected
    // for older backends.
    property var backend: null
    property bool enabled: false

    // ---- Mirroring opt-ins and consent state ------------------------------
    // Injected by the facade from the child-process variables. Local delivery
    // works without them; mirroring, Windows dismissal of mirrored records and
    // app-open each stay independent and default off.
    property bool mirrorOptIn: false
    property bool replaceSystemBanners: true
    // Query an existing Windows grant without showing a consent prompt.
    property bool useExistingAccess: false
    property var accessProbeBackend: null
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
    property int mirrorDisables: 0
    property bool mirroringApplied: false
    // Consent observation is independent of active mirroring: the observer
    // stays applied in Denied/Unavailable so a re-grant is seen with the
    // notification centre closed.
    property int observationWrites: 0
    property bool observationApplied: false
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

    // Upstream NotifsFullscreen values: On (0) keeps popups over a fullscreen
    // toplevel, Off (1) suppresses them and always expires a shown one.
    readonly property int fullscreenPolicyOn: 0
    readonly property int fullscreenPolicyOff: 1
    property int fullscreenPolicy: fullscreenPolicyOn
    // Injected by the facade: returns whether the focused monitor currently
    // has a fullscreen toplevel. The pure object has no compositor query.
    property var fullscreenProvider: null

    // The bounded host does not stage do-not-disturb or sidebar state. A host
    // that does can suppress popups without inventing a Windows notification.
    property bool popupsSuppressed: false

    // Untrusted bodies have no natural length limit; one hostile body must not
    // pin the UI thread. Bodies are capped before any scanning.
    readonly property int maxBodyLength: 16384

    // Retained records (live and restored, mirrored included) are capped so
    // the serialized file, the startup parse and the QObject list stay
    // bounded. 0 disables the cap.
    property int maxHistoryCount: 300

    // Confinement root injected by the facade. The history path is built from
    // stateDirectory and must be a strict descendant of profileRoot. There is
    // deliberately no HOME, XDG or upstream Paths fallback in this object.
    property string profileRoot: ""
    property string stateDirectory: ""

    property bool historyLoaded: false
    property string historyError: ""
    // True after a present history file failed to read or parse. While it is
    // set the file on disk is the only copy of the user's history, so the
    // facade must not overwrite it: mayPersistHistory() refuses, and a failed
    // load emits no historyChanged. Only a subsequent successful restore
    // clears it, so a corrupt or unreadable history file survives the session
    // unchanged.
    property bool historyLoadFailed: false

    // Counters used by the fixture and the native smoke. They never affect the
    // original UI contract.
    property int deliveredNotifications: 0
    property int localDismissals: 0
    property int protectedDismissals: 0
    property int unconfirmedDeliveries: 0
    property int confirmedDeliveries: 0
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
            root.probeExistingAccess();
            return;
        }
        root.disableObservation();
        root.disableMirroring();
        for (const record of root.list.slice()) {
            record.closed = true;
            record.notification = null;
            record.destroy();
        }
        root.list = [];
        root.historyLoaded = false;
        root.historyError = "";
        root.historyLoadFailed = false;
        root.pendingDeliveryId = 0;
        root.deliveryUnconfirmed = false;
        root.deliveryConfirmation = "idle";
        if (typeof deliveryTimer !== "undefined")
            deliveryTimer.stop();
    }

    // ---- Path boundary -----------------------------------------------------

    readonly property string normalizedProfileRoot: normalizePath(profileRoot)
    readonly property string normalizedStateDirectory: normalizePath(stateDirectory)

    readonly property bool pathConfined: {
        if (root.normalizedProfileRoot === "" || root.normalizedStateDirectory === "")
            return false;
        if (!isAbsolutePath(root.normalizedProfileRoot)
                || !isAbsolutePath(root.normalizedStateDirectory))
            return false;
        if (!isUnder(root.normalizedStateDirectory, root.normalizedProfileRoot))
            return false;

        const combined = (root.profileRoot + "|" + root.stateDirectory).toLowerCase();
        if (combined.indexOf("/home/") >= 0 || combined.indexOf("xdg_") >= 0
                || combined.indexOf("$home") >= 0 || combined.indexOf("${home}") >= 0
                || combined.indexOf("paths.state") >= 0 || combined.indexOf("paths.cache") >= 0)
            return false;

        return true;
    }

    readonly property string pathError: {
        if (root.normalizedProfileRoot === "")
            return "The isolated profile root is missing.";
        if (root.normalizedStateDirectory === "")
            return "The isolated profile state directory is missing.";
        if (!isAbsolutePath(root.normalizedProfileRoot)
                || !isAbsolutePath(root.normalizedStateDirectory))
            return "The isolated profile paths must be absolute local paths.";
        if (!isUnder(root.normalizedStateDirectory, root.normalizedProfileRoot))
            return "The notification history directory is outside the isolated profile.";
        if (!root.pathConfined)
            return "The notification paths use a HOME/XDG fallback; only the isolated profile is allowed.";
        return "";
    }

    readonly property string historyPath: pathConfined ? normalizedStateDirectory + "/notifs.json" : ""

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
    // Process-lifetime consent latch published by the consent-fix backend: an
    // explicit request made earlier in this process stays made. A reloaded QML
    // object reconciles with it (cached Allowed is usable without a new
    // request; an unanswered request is not repeatable). The pinned revision
    // publishes nothing, so this stays false there and only this object's own
    // latch applies.
    readonly property bool backendAccessRequested: backend?.accessRequested === true

    // ---- Mirroring state machine ------------------------------------------

    // Staged means the opt-in is present and a usable backend exists. It does
    // not mean access was requested or granted.
    readonly property bool mirrorStaged: enabled && mirrorOptIn && backendPresent && !contended
    readonly property bool windowsDismissPermitted: mirrorStaged && windowsDismissOptIn
    readonly property bool appOpenPermitted: mirrorStaged && appOpenOptIn

    // Unknown/Unspecified/Allowed/Denied/Unavailable, as required by the
    // backend contract. Without a staged mirror there is no measurement.
    readonly property string accessState: root.computeAccessState()
    readonly property bool bannerSuppressionAllowed: replaceSystemBanners && mirrorStaged
        && systemMirrorActive && systemNotificationAccess === 2 && accessState === "Allowed"

    readonly property bool canRequestAccess: mirrorStaged && backend?.ready === true
        && accessState === "Unspecified" && !consentRequested && !consentPending
        && !backendAccessRequested
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

    function probeExistingAccess(): void {
        const candidate = root.backend;
        if (!root.useExistingAccess || !root.enabled || !root.mirrorOptIn
                || root.backendError !== "" || !candidate || candidate.ready !== true
                || candidate.ownership === "contended"
                || root.accessProbeBackend === candidate
                || typeof candidate.refreshAccessStatus !== "function")
            return;
        root.accessProbeBackend = candidate;
        candidate.refreshAccessStatus();
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
    // includes centerVisible, so hiding the center stops it immediately. Each
    // poll asks the consent-fix backend to re-query Windows without prompting
    // (refreshAccessStatus), so recovery is observable; the pinned revision has
    // no such member and the poll only re-reads the published value. It never
    // calls a native request API.
    function pollAccess(): bool {
        if (!root.deniedPollingActive)
            return false;
        root.deniedPolls++;
        if (typeof root.backend?.refreshAccessStatus === "function")
            root.backend.refreshAccessStatus();
        root.refreshAccess();
        if (root.deniedPolls >= root.accessPollBudget)
            root.deniedPollExhausted = true;
        return true;
    }

    function noteSettingsOpened(): void {
        root.settingsOpenRequests++;
    }

    // Consent observation and active mirroring are reconciled separately. The
    // observer runs while the user has the feature opted in and a usable owner
    // backend exists, in every access state, so a re-grant is noticed with the
    // notification centre closed. Active mirroring (and therefore banner
    // suppression) follows the observed Allowed status.
    //
    // Property-change handlers can run before dependent bindings (mirrorStaged,
    // accessState) have re-evaluated, so the desired state is recomputed from
    // the raw inputs instead of reading those bindings.
    function applyMirroring(): void {
        const backend = root.backend;
        const staged = root.enabled && root.mirrorOptIn && root.backendError === ""
            && !!backend && backend?.ownership !== "contended";
        const usable = staged && backend?.ready === true;

        if (!usable) {
            root.disableObservation();
            root.disableMirroring();
            return;
        }

        if (!root.observationApplied && typeof backend.setAccessObservation === "function") {
            root.observationApplied = true;
            root.observationWrites++;
            backend.setAccessObservation(true);
        }

        const desired = usable
            && root.reportedAccess === 2
            && (root.useExistingAccess || root.consentRequested || backend?.accessRequested === true);

        if (!desired) {
            root.disableMirroring();
            return;
        }
        if (root.mirroringApplied)
            return;
        if (typeof backend.setMirroring !== "function")
            return;

        root.mirrorWrites++;
        root.mirroringApplied = true;
        backend.setMirroring(true);
    }

    function disableObservation(): void {
        if (!root.observationApplied)
            return;
        root.observationApplied = false;
        if (root.backend && typeof root.backend.setAccessObservation === "function")
            root.backend.setAccessObservation(false);
    }

    function disableMirroring(): void {
        if (!root.mirroringApplied)
            return;
        root.mirroringApplied = false;
        root.mirrorDisables++;
        if (root.backend && typeof root.backend.setMirroring === "function")
            root.backend.setMirroring(false);
    }

    // Ownership is real mutex ownership. A contended shell stops observing and
    // mirroring; becoming owner runs the same start pass as a fresh shell:
    // probe existing consent, re-observe, and reconcile mirroring/suppression.
    function handleOwnershipChange(): void {
        // Read the backend value directly: this handler can run before the
        // computed ownership/contended bindings have re-evaluated.
        const value = root.backend?.ownership;
        if (value === "contended") {
            root.disableObservation();
            root.disableMirroring();
            root.refreshAccess();
            return;
        }
        if (value !== "owner")
            return;
        root.accessProbeBackend = null;
        root.probeExistingAccess();
        root.refreshAccess();
    }

    // The backend publishes real session-bus ownership: "owner" once its lock
    // thread holds the mutex and "contended" while another shell owns it
    // (server.cpp claimSession). Values outside the known set are "unknown"
    // and never guessed into "owner" or "contended".
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
        ? "" : "The Windows notification backend has not reported session-bus ownership yet."

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
            root.probeExistingAccess();
        }

        function onOwnershipChanged(): void {
            root.handleOwnershipChange();
        }
    }

    onBackendChanged: {
        root.accessProbeBackend = null;
        root.observationApplied = false;
        root.refreshAccess();
        root.probeExistingAccess();
    }
    // Removing the mirror opt-in or a backend component failure must reconcile
    // mirroring immediately, not only on the next access signal.
    onMirrorOptInChanged: {
        root.refreshAccess();
        root.probeExistingAccess();
    }
    onBackendErrorChanged: {
        root.refreshAccess();
        root.probeExistingAccess();
    }
    onUseExistingAccessChanged: {
        root.refreshAccess();
        root.probeExistingAccess();
    }

    // The focused monitor's fullscreen state, through the injected provider.
    function currentHasFullscreen(): bool {
        return typeof root.fullscreenProvider === "function"
            && root.fullscreenProvider() === true;
    }

    // Upstream admission rule: popups are suppressed by the host state and,
    // with the fullscreen policy Off, while a fullscreen toplevel is focused.
    function shouldShowPopup(): bool {
        if (root.popupsSuppressed)
            return false;
        return root.fullscreenPolicy !== root.fullscreenPolicyOff
            || !root.currentHasFullscreen();
    }

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
            popup: root.shouldShowPopup(),
            local: !mirrored,
            hasFullscreen: root.currentHasFullscreen(),
            _wasMirrored: mirrored
        });
        if (!record)
            return false;

        if (mirrored)
            root.mirroredCount++;
        record.arrivalSequence = root.arrivalSequence;
        root.list = [record, ...root.list];
        root.enforceHistoryCap();
        root.deliveredNotifications++;
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

        if (String(action.identifier) !== "default") {
            action.invoke();
            return true;
        }

        if (record.mirrored !== true) {
            action.invoke();
            return true;
        }

        // App-open on a mirrored record must activate the source app without
        // dismissing the real Windows toast. The native action's own invoke
        // auto-closes as dismissed, which removes the toast, so the opt-in is
        // only honored through the backend's mirrored-activation member; when
        // the backend (at the pinned revision) does not expose it, app-open is
        // refused instead of bypassing the separate dismissal opt-in.
        if (!root.appOpenPermitted) {
            root.appOpenRefusals++;
            return false;
        }
        if (typeof root.backend?.activateMirrored !== "function") {
            root.appOpenRefusals++;
            return false;
        }

        root.appOpenInvocations++;
        return root.backend.activateMirrored(record.notificationId) === true;
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
        // Upstream always expires a shown popup while a fullscreen toplevel
        // is focused, regardless of the expire configuration, so the state is
        // re-queried at the moment of expiry.
        record.hasFullscreen = root.currentHasFullscreen();
        if (root.expirePopups || record.hasFullscreen)
            record.popup = false;
    }

    function removeRecord(record, dismiss): void {
        if (!record)
            return;
        record.closed = true;

        if ((record.locks?.size ?? 0) > 0)
            return;

        if (root.list.indexOf(record) < 0) {
            // Cap eviction already removed this record from the list;
            // releasing its last lock must still destroy the detached object.
            if (record.evicted === true) {
                record.notification = null;
                record.destroy();
            }
            return;
        }

        root.list = root.list.filter(item => item !== record);

        if (dismiss && record.notification && !record.mirrored && record.local) {
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
        // The record exposes a sanitized body, so the expectation must compare
        // against the same sanitized text.
        root.pendingDeliveryBody = root.pendingDeliveryContentKnown ? root.sanitizeBody(String(body)) : "";
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
        root.historyLoadFailed = false;

        // Restoration merges instead of replacing. A live notification can
        // arrive before the asynchronous history load finishes; destroying it
        // here lost it and its arrival. Live records survive (and win every id
        // collision) and the merged set is what the facade persists back.
        if (!root.pathConfined) {
            root.historyLoaded = true;
            root.historyError = root.pathError || "The notification history path is not confined to the isolated profile.";
            root.historyLoadFailed = true;
            root.finishHistoryRestore([], true);
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
            root.historyLoadFailed = true;
            root.finishHistoryRestore([], true);
            return false;
        }

        if (!Array.isArray(parsed)) {
            root.historyLoaded = true;
            root.historyError = "The notification history is not a list.";
            root.historyLoadFailed = true;
            root.finishHistoryRestore([], true);
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
            // Persisted history can be edited outside this process, so the app
            // icon and body are re-validated exactly like a live one.
            const appIcon = root.validateAppIcon(String(entry.appIcon ?? ""));

            const record = root._recordComponent.createObject(root, {
                service: root,
                recordId: String(entry.recordId ?? ("restored-" + root.nextRecordId++)),
                notification: null,
                popup: false,
                time: new Date(Number.isFinite(time) && time > 0 ? time : Date.now()),
                notificationId: String(entry.notificationId ?? entry.id ?? ""),
                summary: String(entry.summary ?? ""),
                body: root.sanitizeBody(String(entry.body ?? "")),
                appIcon: appIcon.value,
                appName: String(entry.appName ?? ""),
                image: image.accepted ? image.canonical : "",
                imageSourceRejected: rawImage !== "" && !image.accepted,
                imageSourceError: image.accepted ? "" : image.reason,
                expireTimeout: Number.isFinite(Number(entry.expireTimeout)) ? Number(entry.expireTimeout) : root.defaultExpireTimeout,
                urgency: Number.isInteger(entry.urgency) ? entry.urgency : root.urgencyNormal,
                resident: entry.resident === true,
                hasActionIcons: entry.hasActionIcons === true,
                historicalActions: actions,
                local: entry.local !== false,
                _wasMirrored: false
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
    // the facade's existing historyChanged save. A silent pass, used after a
    // failed load, clears stale restored records without announcing a save.
    function finishHistoryRestore(restored, silent): void {
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
        root.enforceHistoryCap();
        if (!silent)
            root.historyChanged();
    }

    // Bound the retained list. Eviction drops the oldest records from the
    // list; it is not a dismissal, so a still-live native notification keeps
    // its own lifetime with the backend. A record a visible card still holds
    // a lock on (for example mid removal animation) is marked evicted and
    // detached, but its QObject is destroyed only when the last lock is
    // released.
    function enforceHistoryCap(): void {
        if (root.maxHistoryCount <= 0)
            return;
        while (root.list.length > root.maxHistoryCount) {
            const evicted = root.list[root.list.length - 1];
            root.list = root.list.slice(0, -1);
            if (!evicted)
                continue;
            evicted.closed = true;
            evicted.popup = false;
            evicted.notification = null;
            evicted.evicted = true;
            if ((evicted.locks?.size ?? 0) === 0)
                evicted.destroy();
        }
    }

    // The single save gate for the facade's writers: after a failed read or
    // parse the file on disk is the only copy of the user's history and must
    // not be overwritten with the empty or partial in-memory state.
    function mayPersistHistory(): bool {
        return root.enabled && root.pathConfined && root.historyLoaded
            && !root.historyLoadFailed;
    }

    function failHistory(message): void {
        root.historyError = String(message ?? "The notification history could not be read.");
        root.historyLoadFailed = true;
        root.historyLoaded = true;
        // No historyChanged: a failed read must not start the debounced save
        // that would overwrite the unreadable file.
    }

    function historyContains(recordId): bool {
        return findRecordById(recordId) !== null;
    }

    function historyContainsNotificationId(notificationId): bool {
        return recordForNotificationId(notificationId) !== null;
    }

    // ---- Image source policy ----------------------------------------------

    // Upstream rasterised notification images into a cache and the previous
    // revision of this slice copied them into the profile cache. That cache is
    // removed: this slice never copies, writes, lists, prunes or deletes a
    // notification image file. A notification image is used only when it is the
    // allowlisted image://icon theme provider or a file already inside the
    // staged shell assets directory; anything else is cleared so the original
    // card shows its existing fallback icon.
    //
    // Providers are allowlisted, not merely prefixed. QIcon::fromTheme (the
    // image://icon provider) loads an absolute path and honours a fallback name,
    // so image://icon/C:/outside.png and image://icon/x?fallback=C:/outside.png
    // were confinement bypasses. Only image://icon/<name> is accepted, where
    // <name> is a bare theme name matching ^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$:
    // no slash, backslash, colon, "?", "#", "%", whitespace or authority. Every
    // other provider (image://, image:///path, image://other/..., query or
    // fragment forms) is rejected.
    //
    // The local-file decision is purely lexical (no filesystem access), so a
    // rejected source is never opened by the UI:
    //   - percent encoding is refused everywhere (%2e%2e and %5c would
    //     otherwise bypass the component checks after a decoder ran),
    //   - UNC, \\?\, \\.\, // and file://host sources are refused,
    //   - alternate data streams (any ":" beyond the drive letter) are refused,
    //   - relative and drive-relative paths are refused,
    //   - any component ending in "." or a space, containing "~" (an 8.3
    //     short-name alias) or equal to "." or ".." is refused,
    //   - the remaining absolute path must be a strict case-insensitive child
    //     of the injected staged assets directory.
    // The UI image URL is rebuilt from the validated path, never from the raw
    // input, and each path segment is percent-encoded so "#", "?" and other URL
    // delimiters in a staged file name cannot become a fragment or query.
    //
    // The staged assets root comes from Quickshell.shellPath("assets") and is
    // trusted staging, not notification input. The validator is lexical: it does
    // not detect a reparse point (junction/symlink) placed inside that trusted
    // root, and physical containment relies on the staging step.

    // Injected by the facade: the staged shell's assets directory.
    property string shellAssetsDirectory: ""

    property int rejectedImageSources: 0
    property string lastRejectedImageSource: ""
    property string lastImageSourceError: ""

    readonly property string canonicalShellAssetsDirectory: canonicalLocalPath(shellAssetsDirectory)

    // A theme icon name and a provider id share one shape. The name must start
    // alphanumerically (so no "."/".." or leading punctuation) and may contain
    // only characters that cannot introduce a path, query, fragment, authority
    // or percent escape.
    function isThemeIconName(value): bool {
        return /^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$/.test(String(value ?? ""));
    }

    // Pure, Quickshell-free source validation. Returns
    // { accepted, kind, canonical, path, reason } where kind is "provider",
    // "assets" or "rejected", canonical is the URL handed to the UI and path is
    // the validated local path (empty for providers and rejections).
    function validateImageSource(source): var {
        const reject = reason => ({
            accepted: false, kind: "rejected", canonical: "", path: "", reason: reason
        });

        if (source === undefined || source === null)
            return reject("The notification image source is missing.");
        const raw = String(source);
        if (raw.trim() === "")
            return reject("The notification image source is empty.");
        if (raw.indexOf("%") >= 0)
            return reject("Percent-encoded notification image sources are not allowed.");

        const normalized = raw.replace(/\\/g, "/");
        if (normalized.startsWith("image://")) {
            const prefix = "image://icon/";
            if (!normalized.startsWith(prefix))
                return reject("Only image://icon/<theme-name> provider URLs are allowed.");
            const name = normalized.slice(prefix.length);
            if (!root.isThemeIconName(name))
                return reject("The image provider name is not a bare theme icon name.");
            return {
                accepted: true, kind: "provider", canonical: prefix + name,
                path: "", reason: ""
            };
        }

        // A leading // is a UNC share, a \\?\ or \\.\ device path, or a
        // protocol-relative URL. None is ever a local staged asset.
        if (normalized.startsWith("//"))
            return reject("UNC, device and protocol-relative sources are not allowed.");

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

        const validated = root.canonicalLocalPath(path);
        if (validated === "")
            return reject("The notification image is not an absolute local path.");

        const assets = root.canonicalShellAssetsDirectory;
        if (assets === "" || !root.isUnder(validated, assets))
            return reject("The notification image is outside the staged shell assets directory.");
        const resolved = assets + "/" + validated.slice(assets.length + 1);
        const canonical = root.imageUrlForPath(resolved);
        if (canonical === "")
            return reject("The notification image path cannot be represented as a file URL.");
        return {
            accepted: true, kind: "assets", canonical: canonical,
            path: resolved, reason: ""
        };
    }

    // App icons reach Quickshell.iconPath(), which turns the value into
    // image://icon/<value> and therefore also reaches QIcon::fromTheme. The same
    // allowlist applies: a bare theme name, or a staged asset file (returned as
    // the validated local path, not a URL, because iconPath builds the provider
    // URL itself). Anything else becomes "" so the original fallback renders.
    function validateAppIcon(source): var {
        const reject = reason => ({
            accepted: false, kind: "rejected", value: "", reason: reason
        });

        if (source === undefined || source === null)
            return { accepted: true, kind: "empty", value: "", reason: "" };
        const raw = String(source);
        if (raw === "")
            return { accepted: true, kind: "empty", value: "", reason: "" };
        if (root.isThemeIconName(raw))
            return { accepted: true, kind: "theme", value: raw, reason: "" };

        const image = root.validateImageSource(raw);
        if (image.accepted && image.kind === "assets")
            return { accepted: true, kind: "assets", value: image.path, reason: "" };
        return reject("The app icon is neither a theme icon name nor a staged asset.");
    }

    // Lexical canonicalisation only: no filesystem access. Returns "" for a
    // rejected source. Windows resolves ":" as an alternate data stream and
    // treats trailing dots/spaces and "~" short names as the same file, so the
    // raw input must be exact before it is accepted.
    function canonicalLocalPath(value): string {
        if (value === undefined || value === null)
            return "";
        const text = String(value);
        if (text === "" || text.indexOf("%") >= 0)
            return "";
        const path = text.replace(/\\/g, "/");
        if (path.startsWith("//"))
            return "";

        const match = /^([A-Za-z]):\/(.*)$/.exec(path);
        if (!match)
            return "";

        const segments = match[2].split("/");
        const parts = [];
        for (const segment of segments) {
            if (segment === "")
                continue;
            if (segment === "." || segment === "..")
                return "";
            if (segment.endsWith(".") || segment.endsWith(" "))
                return "";
            if (segment.indexOf("~") >= 0)
                return "";
            if (segment.indexOf(":") >= 0)
                return "";
            // A lone surrogate cannot be percent-encoded and is not a real
            // Windows file name.
            if (/[\uD800-\uDFFF]/.test(segment))
                return "";
            parts.push(segment);
        }
        if (parts.length === 0)
            return "";
        return match[1].toUpperCase() + ":/" + parts.join("/");
    }

    // Build the UI URL only from the validated path. Each segment is
    // percent-encoded so a staged file named "banner#v2.png" keeps its "#"
    // instead of turning it into a URL fragment (and "?" cannot become a
    // query). encodeURIComponent leaves the unreserved characters, including
    // the "." used by ordinary extensions, untouched.
    function imageUrlForPath(path): string {
        const normalized = normalizePath(path);
        const match = /^([A-Za-z]):\/(.*)$/.exec(normalized);
        if (!match)
            return "";
        const segments = [];
        for (const segment of match[2].split("/")) {
            if (segment === "")
                continue;
            let encoded = "";
            try {
                encoded = encodeURIComponent(segment);
            } catch (error) {
                return "";
            }
            if (encoded === "")
                return "";
            segments.push(encoded);
        }
        if (segments.length === 0)
            return "";
        return "file:///" + match[1].toUpperCase() + ":/" + segments.join("/");
    }

    function reportRejectedImageSource(source, reason): void {
        root.rejectedImageSources++;
        root.lastRejectedImageSource = String(source ?? "");
        root.lastImageSourceError = String(reason ?? "");
    }

    // ---- Body sanitization ------------------------------------------------

    // The original popup and sidebar render the body as Markdown when it
    // contains Markdown punctuation, and Qt's Markdown importer loads image
    // resources from inline images, reference images and raw HTML. A
    // notification body is untrusted text, so image-bearing constructs are
    // reduced to their alt text (or removed) before the record exposes it:
    //   - ![alt](destination "title") and ![alt](<destination>) -> alt,
    //   - ![alt][reference] and ![alt] -> alt,
    //   - reference definition lines "[ref]: url ..." -> removed,
    //   - <img>, <picture>, <source>, <svg>, <image>, <object>, <embed> and
    //     <iframe> tags (case-insensitive, multi-line attributes, quoted ">")
    //     -> removed.
    // Ordinary text and ordinary links are kept. This is a lexical filter, not
    // a Markdown parser: fenced code blocks and multi-line reference titles are
    // not modelled, and a definition-looking line is removed even without a
    // matching image reference. NotifData applies it to live bodies, body
    // updates and restored history, so the UI only ever sees the result.
    function sanitizeBody(value): string {
        if (value === undefined || value === null)
            return "";
        let text = String(value);
        if (text === "")
            return "";
        // A notification body is untrusted and unbounded; cap it before any
        // scanning so one body cannot pin the UI thread.
        if (text.length > root.maxBodyLength) {
            text = text.slice(0, root.maxBodyLength);
            // Do not leave a split surrogate pair at the cut.
            if (/[\uD800-\uDBFF]/.test(text.charAt(text.length - 1)))
                text = text.slice(0, -1);
        }
        text = root.stripHtmlMediaTags(text);
        text = root.stripMarkdownReferenceDefinitions(text);
        // An image alt may itself contain an image, or stripping markup may
        // expose another construct. Keep the work bounded, then fail closed.
        for (let pass = 0; pass < 8; pass++) {
            const next = root.stripMarkdownReferenceDefinitions(
                root.stripHtmlMediaTags(root.replaceMarkdownImages(text)));
            if (next === text)
                return text;
            text = next;
        }
        // Drop all possible image openers after the budget, including ones
        // exposed by removing another opener. Removing every "!" and "<"
        // prevents inline/reference images and all HTML media forms, regardless
        // of remaining depth, escapes or incomplete delimiters.
        return text.replace(/!/g, "").replace(/</g, "");
    }

    // Remove media-bearing HTML tags with a small scanner instead of a single
    // regex: quoted attribute values may contain ">", and an unterminated tag is
    // dropped to the end of the text because a tolerant HTML parser could still
    // treat it as an image. Ordinary "<" text is left alone.
    function stripHtmlMediaTags(text): string {
        const source = String(text ?? "");
        const opener = /^<\/?(?:img|image|picture|source|svg|object|embed|iframe)\b/i;
        let output = "";
        let i = 0;
        while (i < source.length) {
            if (source.charAt(i) === "<") {
                const match = opener.exec(source.slice(i, i + 12));
                if (match) {
                    let j = i + match[0].length;
                    let quote = "";
                    while (j < source.length) {
                        const ch = source.charAt(j);
                        if (quote !== "") {
                            if (ch === quote)
                                quote = "";
                        } else if (ch === "\"" || ch === "'") {
                            quote = ch;
                        } else if (ch === ">") {
                            j++;
                            break;
                        }
                        j++;
                    }
                    i = j;
                    continue;
                }
            }
            output += source.charAt(i);
            i++;
        }
        return output;
    }

    function stripMarkdownReferenceDefinitions(text): string {
        return String(text ?? "").replace(/^[ \t]{0,3}\[[^\]\n]+\]:[^\n]*(?:\r?\n|$)/gm, "");
    }

    // Replace every Markdown image with its alt text. Destinations are
    // skipped with escape-aware delimiter matching, so "![x](file:///C:/a(b).png)",
    // angle destinations and nested alt brackets do not leave a partial
    // destination behind — including an image nested inside an unclosed
    // "![a](< ... >", whose inner parentheses still pair normally. All
    // matching is precomputed in one linear pass per table: no path rescans
    // the suffix, so an image-storm body stays linear.
    function replaceMarkdownImages(text): string {
        const source = String(text ?? "");
        const bracketMatch = root.computeDelimiterMatches(source, "[", "]");
        const firstParenDrop = root.computeFirstParenDrop(source);
        const nextAngleClose = root.computeNextAngleClose(source);
        const nextNonWhitespace = root.computeNextNonWhitespace(source);
        let output = "";
        let i = 0;
        while (i < source.length) {
            const ch = source.charAt(i);
            if (ch === "\\") {
                output += source.slice(i, i + 2);
                i += 2;
                continue;
            }
            if (ch === "!" && source.charAt(i + 1) === "[") {
                const altEnd = bracketMatch[i + 1];
                if (altEnd >= 0) {
                    const alt = source.slice(i + 2, altEnd);
                    const marker = source.charAt(altEnd + 1);
                    if (marker === "(") {
                        const destinationEnd = root.imageDestinationEnd(source,
                            altEnd + 1, firstParenDrop, nextAngleClose, nextNonWhitespace);
                        if (destinationEnd >= 0) {
                            output += alt;
                            i = destinationEnd + 1;
                            continue;
                        }
                    } else if (marker === "[") {
                        const referenceEnd = bracketMatch[altEnd + 1];
                        if (referenceEnd >= 0) {
                            output += alt;
                            i = referenceEnd + 1;
                            continue;
                        }
                    } else {
                        output += alt;
                        i = altEnd + 1;
                        continue;
                    }
                }
            }
            output += ch;
            i++;
        }
        return output;
    }

    // One linear pass: match[i] is the index of the delimiter closing the one
    // at i, or -1 when it never closes. Stack pairing over the whole text is
    // the same depth counting the previous per-opener scan performed, but each
    // position is answered once. Backslash escapes skip the next character.
    function computeDelimiterMatches(text, open, close): var {
        const source = String(text ?? "");
        const match = new Array(source.length).fill(-1);
        const stack = [];
        for (let i = 0; i < source.length; i++) {
            const ch = source.charAt(i);
            if (ch === "\\") {
                i++;
                continue;
            }
            if (ch === open) {
                stack.push(i);
            } else if (ch === close && stack.length > 0) {
                match[stack.pop()] = i;
            }
        }
        return match;
    }

    // The ")" that closes an inline image destination opened by the "(" at
    // parenStart, or -1 when it never closes. A "<...>" destination is
    // recognized first — CommonMark lets it contain "(" and ")" — and only
    // when that form is not closed by ">" plus optional whitespace and ")"
    // do the plain escape-aware parentheses pair. Every lookup is a
    // precomputed table access, so no path rescans the text.
    // firstDrop[k] is the first index q >= k where cumulative unescaped "("
    // minus ")" depth drops to depth[k] - 1 (i.e. where a "(" opened just
    // before k closes), or -1 if never. For an angle destination "<...>" ending
    // at angleEnd, all "(" and ")" inside "<...>" are opaque, so the "(" at
    // parenStart closes at firstDrop[angleEnd + 1] (covering optional titles
    // such as '![x](<C:/a(b.png> "title")'); otherwise it closes at
    // firstDrop[parenStart + 1].
    function computeFirstParenDrop(text): var {
        const source = String(text ?? "");
        const depth = new Array(source.length + 1).fill(0);
        for (let i = 0; i < source.length; i++) {
            const ch = source.charAt(i);
            if (ch === "\\") {
                depth[i + 1] = depth[i];
                if (i + 1 < source.length) {
                    depth[i + 2] = depth[i];
                    i++;
                }
                continue;
            }
            if (ch === "(")
                depth[i + 1] = depth[i] + 1;
            else if (ch === ")")
                depth[i + 1] = depth[i] - 1;
            else
                depth[i + 1] = depth[i];
        }
        const firstAtDepth = new Map();
        const firstDrop = new Array(source.length + 1).fill(-1);
        for (let k = source.length; k >= 0; k--) {
            const pos = firstAtDepth.get(depth[k] - 1);
            if (pos !== undefined)
                firstDrop[k] = pos - 1;
            firstAtDepth.set(depth[k], k);
        }
        return firstDrop;
    }

    function imageDestinationEnd(source, parenStart, firstParenDrop,
            nextAngleClose, nextNonWhitespace): int {
        const angleStart = nextNonWhitespace[parenStart + 1];
        if (source.charAt(angleStart) === "<") {
            const angleEnd = nextAngleClose[angleStart + 1];
            if (angleEnd >= 0) {
                const closeAfterAngle = firstParenDrop[angleEnd + 1];
                if (closeAfterAngle >= 0)
                    return closeAfterAngle;
            }
        }
        return firstParenDrop[parenStart + 1];
    }

    // Whether the character at index is preceded by an odd number of
    // backslashes, so "\\" before it escapes the escape and leaves it live.
    function isEscapedAt(source, index): bool {
        let slashes = 0;
        for (let i = index - 1; i >= 0 && source.charAt(i) === "\\"; i--)
            slashes++;
        return slashes % 2 === 1;
    }

    // nextAngleClose[k] is the index of the next unescaped ">" at or after k
    // on the same line, or -1 when none follows: a CommonMark "<...>" link
    // destination cannot span lines. One backwards pass answers every query.
    function computeNextAngleClose(text): var {
        const source = String(text ?? "");
        const next = new Array(source.length + 1).fill(-1);
        for (let i = source.length - 1; i >= 0; i--) {
            const ch = source.charAt(i);
            if (ch === "\n" || ch === "\r") {
                next[i] = -1;
                continue;
            }
            next[i] = ch === ">" && !root.isEscapedAt(source, i) ? i : next[i + 1];
        }
        return next;
    }

    // nextNonWhitespace[k] is the index of the first non-whitespace character
    // at or after k, or source.length when none follows, so destination
    // scanning skips whitespace without an inner loop.
    function computeNextNonWhitespace(text): var {
        const source = String(text ?? "");
        const next = new Array(source.length + 1).fill(source.length);
        for (let i = source.length - 1; i >= 0; i--) {
            const ch = source.charAt(i);
            next[i] = ch === " " || ch === "\t" || ch === "\n" || ch === "\r"
                ? next[i + 1] : i;
        }
        return next;
    }

    // ---- Replacement sends -------------------------------------------------

    // The pinned backend parses -r/--replace-id and reports a new notification
    // with its own id; this slice has no local replace path, so a replacement
    // send would never confirm. It is refused before notifySend and before
    // expectDelivery, so it cannot be reported as forwarded/unconfirmed.
    //
    // This mirrors notify_send.cpp option consumption exactly: every option in
    // the backend's table is recognised (case-sensitive long names, the first
    // character after "-"), only u/t/a/i/c/h/A/r take a following argument, and
    // an unknown option consumes nothing. That is why ["-a", "-r", "42"] is an
    // app name and is NOT refused, while ["-r", "+42"] is a replacement.
    //
    // The value goes through QString::toUInt (base 10), whose observed rules are
    // mirrored by backendReplaceId(): optional ASCII whitespace, optional "+",
    // decimal digits, optional ASCII whitespace, and a result <= UINT_MAX.
    // Unicode whitespace, a negative sign, fractional values and overflow are
    // not parsed by the backend and are not treated as replacements.
    readonly property var notifySendShortOptions: ["u", "t", "a", "i", "c", "h", "A", "r", "e", "p", "w"]
    readonly property var notifySendValueOptions: ["u", "t", "a", "i", "c", "h", "A", "r"]
    readonly property var notifySendLongOptions: ({
        "urgency": "u",
        "expire-time": "t",
        "app-name": "a",
        "icon": "i",
        "category": "c",
        "hint": "h",
        "action": "A",
        "replace-id": "r",
        "transient": "e",
        "print-id": "p",
        "wait": "w"
    })

    function notifySendOptionTakesValue(option): bool {
        return root.notifySendValueOptions.indexOf(String(option)) >= 0;
    }

    // Returns the unsigned 32-bit value the backend would parse, or -1 when
    // toUInt() would fail. Zero is a valid parsed value but means "no replace".
    function backendReplaceId(value): int {
        const text = String(value ?? "");
        if (!/^[\t\n\v\f\r ]*\+?[0-9]+[\t\n\v\f\r ]*$/.test(text))
            return -1;
        const digits = text.replace(/^[\t\n\v\f\r ]*\+?/, "").replace(/[\t\n\v\f\r ]*$/, "");
        const id = Number(digits);
        if (!Number.isSafeInteger(id) || id > 4294967295)
            return -1;
        return id;
    }

    function replacementIdFromArgs(args): int {
        if (!args || typeof args.length !== "number")
            return 0;

        let replacesId = 0;
        for (let i = 0; i < args.length; i++) {
            const arg = String(args[i] ?? "");
            let option = "";
            let value = "";
            let hasValue = false;

            if (arg.startsWith("--") && arg.length > 2) {
                const eq = arg.indexOf("=");
                const name = eq < 0 ? arg.slice(2) : arg.slice(2, eq);
                // Long names are compared case-sensitively by the backend. Use
                // an own-property test so inherited names are not mistaken for
                // options.
                const longNames = root.notifySendLongOptions;
                option = Object.prototype.hasOwnProperty.call(longNames, name)
                    ? String(longNames[name]) : "";
                if (eq >= 0) {
                    value = arg.slice(eq + 1);
                    hasValue = true;
                }
            } else if (arg.startsWith("-") && arg.length > 1) {
                const shortName = arg.charAt(1);
                option = root.notifySendShortOptions.indexOf(shortName) >= 0 ? shortName : "";
                if (arg.length > 2) {
                    value = arg.slice(arg.charAt(2) === "=" ? 3 : 2);
                    hasValue = true;
                }
            }

            // Unknown arguments are logged and ignored by the backend; they do
            // not consume the next argument.
            if (option === "")
                continue;

            if (root.notifySendOptionTakesValue(option) && !hasValue) {
                if (i + 1 >= args.length)
                    break;
                value = String(args[++i] ?? "");
            }

            if (option !== "r")
                continue;
            const parsed = root.backendReplaceId(value);
            // A later valid -r wins; an invalid later value keeps the previous
            // one, exactly like the backend's apply().
            if (parsed >= 0)
                replacesId = parsed;
        }
        return replacesId;
    }

    function replacementSendRefusal(args): string {
        if (root.replacementIdFromArgs(args) <= 0)
            return "";
        return "Replacement notifications are not supported by this slice; the local send was refused.";
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

    function invokeHistoricalAction(record, identifier): void {
        // Restored history has no backend notification to invoke. Keep the
        // original object shape and consume the action without a process call.
        if (record && record.service)
            console.log("Caelestia notifications: historical action consumed");
    }
}
