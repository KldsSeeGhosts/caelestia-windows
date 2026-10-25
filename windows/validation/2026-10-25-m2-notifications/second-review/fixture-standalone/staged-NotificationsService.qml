import QtQuick

// Windows adaptation of the bounded parts of services/Notifs.qml and
// services/NotifData.qml. This object has no Quickshell import, constructs no
// native server, and performs no file or image reads, writes, listings or
// deletions: the singleton facade owns FileView persistence. A notification
// image is only ever accepted as an image-provider URL or as a file already
// inside the staged shell assets directory; no image is copied or cached.
// Backends, paths and translations may be injected in tests.
//
// The notification list is the original NotifData contract consumed by
// modules/notifications/*: summary, body, appName, appIcon, image, urgency,
// resident, hasActionIcons, hints, actions, expireTimeout, time/timeStr,
// popup/closed, lock()/unlock()/close() and a timer that can be stopped by the
// original hover state.
//
// This slice only delivers notifications sent through the server's local path
// (notifySend / the fixture). System toast mirroring stays off, so a close or
// dismiss here only ever reaches a local backend object. The guards below also
// refuse to dismiss anything carrying a Windows toast identity, so a future
// mirroring slice cannot turn a local close into a Windows notification removal.
QtObject {
    id: root

    // The injected backend is the NativeNotificationBackend facade (or a test
    // fake) exposing: ready (bool), ownership (string), mirrorSystemNotifications
    // (bool), systemMirrorActive (bool), systemNotificationAccess (int),
    // notifySend(summary, body, args), and notificationReceived(notification).
    property var backend: null
    property bool enabled: false

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

    // Confinement root injected by the facade. The history path is built from
    // stateDirectory and must be a strict descendant of profileRoot. There is
    // deliberately no HOME, XDG or upstream Paths fallback in this object.
    property string profileRoot: ""
    property string stateDirectory: ""

    property bool historyLoaded: false
    property string historyError: ""

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
        if (root.enabled)
            return;
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

    // Mirroring defaults true in the pinned backend. This slice must never
    // request, enable or rely on it; a backend reporting true is refused rather
    // than allowed to deliver system notifications through the original UI.
    readonly property bool mirroringRequested: backend?.mirrorSystemNotifications === true
    readonly property bool mirroringOff: !mirroringRequested
    readonly property bool systemMirrorActive: backend?.systemMirrorActive === true
    readonly property int systemNotificationAccess: {
        const value = backend?.systemNotificationAccess;
        return Number.isInteger(value) ? value : -1;
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
        if (mirroringRequested)
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
        if (mirroringRequested)
            return "System notification mirroring is on; this slice only delivers local notifications and refuses to run with mirroring enabled.";
        if (!backend)
            return "Waiting for the Windows notification server.";
        if (backend.ready !== true)
            return "Waiting for the Windows notification server to finish loading.";
        if (contended)
            return "Another notification owner is active. This shell is not delivering notifications and leaves the backend's bounded ownership retry alone.";
        if (deliveryUnconfirmed)
            return "The send was forwarded to another notification owner or was not delivered by this shell, so it is unconfirmed. No system notification was requested or dismissed.";
        return "Windows local notifications are delivered to this shell only. System notification mirroring is off; real Windows notifications are neither read nor removed.";
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

        const record = root._recordComponent.createObject(root, {
            service: root,
            recordId: root.nextRecordId++ + "-" + Date.now(),
            notification: notification,
            popup: !root.popupsSuppressed,
            local: !root.isSystemNotification(notification)
        });
        if (!record)
            return false;

        record.arrivalSequence = root.arrivalSequence;
        root.list = [record, ...root.list];
        root.deliveredNotifications++;
        root.settlePendingDelivery();
        root.historyChanged();
        return true;
    }

    function deliveryAllowed(): bool {
        return root.enabled && root.backendPresent && root.backend.ready === true
            && !root.mirroringRequested && !root.contended;
    }

    // A mirrored/toast-backed notification carries the backend's Windows toast
    // hints. This slice never dismisses one, even if a future backend hands one
    // to the original UI.
    function isSystemNotification(notification): bool {
        const hints = notification?.hints;
        if (!hints || typeof hints !== "object")
            return false;
        return Object.prototype.hasOwnProperty.call(hints, "x-windows-toast-id")
            || Object.prototype.hasOwnProperty.call(hints, "x-windows-aumid");
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
            // Local-only removal. This is the only place that calls into the
            // backend notification's close path.
            root.localDismissals++;
            record.notification.dismiss();
        } else if (dismiss && record.notification) {
            // Never remove a real Windows notification from this slice.
            root.protectedDismissals++;
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

    // ---- History -----------------------------------------------------------

    function serializeHistory(): string {
        const entries = root.list.filter(record => !record.closed).map(record => ({
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
                imageSourceRejected: rawImage !== "" && !image.accepted,
                imageSourceError: image.accepted ? "" : image.reason,
                expireTimeout: Number.isFinite(Number(entry.expireTimeout)) ? Number(entry.expireTimeout) : root.defaultExpireTimeout,
                urgency: Number.isInteger(entry.urgency) ? entry.urgency : root.urgencyNormal,
                resident: entry.resident === true,
                hasActionIcons: entry.hasActionIcons === true,
                historicalActions: actions,
                local: entry.local !== false
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

    // ---- Image source policy ----------------------------------------------

    // Upstream rasterised notification images into a cache and the previous
    // revision of this slice copied them into the profile cache. That cache is
    // removed: this slice never copies, writes, lists, prunes or deletes a
    // notification image file. A notification image is used only when it is an
    // image:// provider URL or a file already inside the staged shell assets
    // directory; anything else is cleared so the original card shows its
    // existing fallback icon.
    //
    // The decision is purely lexical (no filesystem access), so a rejected
    // source is never opened by the UI:
    //   - percent encoding is refused everywhere (%2e%2e and %5c would
    //     otherwise bypass the component checks after a decoder ran),
    //   - UNC, \\?\, \\.\, // and file://host sources are refused,
    //   - alternate data streams (any ":" beyond the drive letter) are refused,
    //   - relative and drive-relative paths are refused,
    //   - any component ending in "." or a space, containing "~" (an 8.3
    //     short-name alias) or equal to "." or ".." is refused,
    //   - the remaining absolute path must be a strict case-insensitive child
    //     of the injected staged assets directory.
    // The UI image is rebuilt from the validated path ("file:///" plus forward
    // slashes), never from the raw input.

    // Injected by the facade: the staged shell's assets directory.
    property string shellAssetsDirectory: ""

    property int rejectedImageSources: 0
    property string lastRejectedImageSource: ""
    property string lastImageSourceError: ""

    readonly property string canonicalShellAssetsDirectory: canonicalLocalPath(shellAssetsDirectory)

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
        if (normalized.toLowerCase().startsWith("image://")) {
            const provider = normalized.slice("image://".length);
            if (provider === "" || provider.startsWith("/") || provider.indexOf("..") >= 0)
                return reject("The notification image provider URL is invalid.");
            return {
                accepted: true, kind: "provider", canonical: "image://" + provider,
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
        return {
            accepted: true, kind: "assets", canonical: root.imageUrlForPath(resolved),
            path: resolved, reason: ""
        };
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
            parts.push(segment);
        }
        if (parts.length === 0)
            return "";
        return match[1].toUpperCase() + ":/" + parts.join("/");
    }

    function imageUrlForPath(path): string {
        return "file:///" + normalizePath(path);
    }

    function reportRejectedImageSource(source, reason): void {
        root.rejectedImageSources++;
        root.lastRejectedImageSource = String(source ?? "");
        root.lastImageSourceError = String(reason ?? "");
    }

    // ---- Replacement sends -------------------------------------------------

    // The pinned backend parses -r/--replace-id and reports a new notification
    // with its own id; this slice has no local replace path, so a replacement
    // send would never confirm. It is refused before notifySend and before
    // expectDelivery, so it cannot be reported as forwarded/unconfirmed.
    function replacementIdFromArgs(args): int {
        if (!args || typeof args.length !== "number")
            return 0;
        for (let i = 0; i < args.length; i++) {
            const arg = String(args[i] ?? "");
            let value = "";
            let hasValue = false;

            if (arg.length > 2 && arg.startsWith("--")) {
                const eq = arg.indexOf("=");
                const name = (eq < 0 ? arg.slice(2) : arg.slice(2, eq)).toLowerCase();
                if (name !== "replace-id")
                    continue;
                if (eq >= 0) {
                    value = arg.slice(eq + 1);
                    hasValue = true;
                }
            } else if (arg.length > 1 && arg.startsWith("-")) {
                if (arg.charAt(1) !== "r")
                    continue;
                if (arg.length > 2) {
                    value = arg.slice(arg.charAt(2) === "=" ? 3 : 2);
                    hasValue = true;
                }
            } else {
                continue;
            }

            if (!hasValue) {
                if (i + 1 >= args.length)
                    return 0;
                value = String(args[++i] ?? "");
            }
            // The backend parses the value with QString::toUInt, so a
            // fractional or otherwise non-numeric value is not a replacement.
            const text = value.trim();
            if (!/^\d+$/.test(text))
                continue;
            const id = Number(text);
            if (id > 0)
                return id;
        }
        return 0;
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
            console.log("Caelestia notifications: historical action consumed:", identifier);
    }
}
