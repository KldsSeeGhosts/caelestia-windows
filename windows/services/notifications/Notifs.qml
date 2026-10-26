pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Qt.labs.folderlistmodel
import Quickshell
import Quickshell.Io
import Quickshell.Windows
import Caelestia
import Caelestia.Config
import Caelestia.I18n

// Windows replacement for the original services/Notifs.qml singleton contract.
// The pure NotificationsService owns records, expiry, dismissal, source trust,
// the bounded writer pool, mirroring consent and history serialization; this
// facade adds only the opt-ins, the native loader, the Windows settings action
// and the isolated-profile FileView. It intentionally imports no HOME/XDG path
// object and never constructs the native server while disabled.
Singleton {
    id: root

    // Local delivery opt-in. -NotificationsMode Local maps to this single
    // variable; mirrored delivery additionally needs the mirror opt-in below.
    readonly property bool enabled: Quickshell.env("CAELESTIA_WINDOWS_NOTIFICATIONS") === "1"

    // Mirroring is off unless explicitly opted into. It still starts
    // unrequested: the service must never ask for notification-listener access
    // until the user presses the notification-center button.
    readonly property bool mirrorOptIn: enabled
        && Quickshell.env("CAELESTIA_WINDOWS_NOTIFICATION_MIRROR") === "1"
    // Separate opt-ins for the two side effects a mirrored record can cause.
    readonly property bool windowsDismissOptIn: mirrorOptIn
        && Quickshell.env("CAELESTIA_WINDOWS_NOTIFICATION_MIRROR_DISMISS") === "1"
    readonly property bool appOpenOptIn: mirrorOptIn
        && Quickshell.env("CAELESTIA_WINDOWS_NOTIFICATION_APP_OPEN") === "1"

    // Quickshell's state/cache directories are the staged //@ pragma values
    // (profile/state and profile/cache). The profile root is their parent, and
    // the service refuses any state/cache path outside it. No upstream path
    // fallback exists here.
    readonly property string profileRoot: {
        const state = root.normalize(Quickshell.stateDir);
        const slash = state.lastIndexOf("/");
        return slash > 0 ? state.substring(0, slash) : "";
    }

    // The staged shell's assets directory is the only non-profile location a
    // notification image may come from.
    readonly property string shellAssetsDirectory: Quickshell.shellPath("assets")

    readonly property NotificationsService service: NotificationsService {
        enabled: root.enabled
        mirrorOptIn: root.mirrorOptIn
        windowsDismissOptIn: root.windowsDismissOptIn
        appOpenOptIn: root.appOpenOptIn
        centerVisible: root.centerVisible
        translator: Tr
        defaultExpireTimeout: GlobalConfig.notifs.defaultExpireTimeout
        fullscreenExpireTimeout: GlobalConfig.notifs.fullscreenExpireTimeout
        expirePopups: GlobalConfig.notifs.expire
        profileRoot: root.profileRoot
        stateDirectory: Quickshell.stateDir
        cacheDirectory: Quickshell.cacheDir
        shellAssetsDirectory: root.shellAssetsDirectory
        imageCacheLister: root.listImageCacheFiles
        imageCacheRemover: root.removeImageCacheFile
        backend: nativeLoader.item ?? null
        backendError: nativeLoader.status === Loader.Error
            ? "The Windows notification backend component failed to load." : ""
    }

    // The bounded host sets this while the original notification center is
    // visible. Denied access polling is bounded to that window.
    property bool centerVisible: false

    // Preserved original Notifs singleton surface consumed by
    // modules/notifications/* and the sidebar notification components.
    readonly property var list: service.list
    readonly property var notClosed: service.notClosed
    readonly property var popups: service.popups
    readonly property bool loaded: service.historyLoaded

    readonly property bool nativeRequested: nativeLoader.active
    readonly property bool backendLoaded: nativeLoader.item !== null
    readonly property var backend: nativeLoader.item ?? null

    readonly property string status: service.status
    readonly property string reason: service.reason
    readonly property bool mirroringOff: service.mirroringOff
    readonly property bool mirrorSystemNotifications: service.mirroringRequested
    readonly property bool systemMirrorActive: service.systemMirrorActive
    readonly property int systemNotificationAccess: service.systemNotificationAccess
    readonly property string ownership: service.ownership
    readonly property bool ownershipKnown: service.ownershipKnown
    readonly property string ownershipNote: service.ownershipNote
    readonly property bool contended: service.contended
    readonly property bool deliveryUnconfirmed: service.deliveryUnconfirmed
    readonly property string deliveryConfirmation: service.deliveryConfirmation

    // ---- Mirroring control surface consumed by the notification center -----
    readonly property bool mirrorControlEnabled: service.mirrorStaged
    readonly property bool mirrorStaged: service.mirrorStaged
    readonly property string mirrorAccessState: service.accessState
    readonly property string mirrorStatus: service.mirrorStatus
    readonly property string mirrorStatusText: {
        switch (service.mirrorStatus) {
        case "consent-required":
            return "Windows notifications can be mirrored here after you allow access. They are requested only when you choose it.";
        case "pending":
            return "Waiting for Windows to answer the access request.";
        case "allowed":
            return "Windows notifications are mirrored here.";
        case "denied":
            return "Windows notification access is denied.";
        case "unavailable":
            return "Windows notification-listener access is unavailable on this system.";
        case "timed-out":
            return "Windows did not answer the access request. Use Windows settings; it is not asked again.";
        case "blocked":
            return "Another notification owner is active; mirroring stays off.";
        default:
            return "Windows notification access has not been reported yet.";
        }
    }
    readonly property bool canRequestMirrorAccess: service.canRequestAccess
    readonly property bool mirrorConsentRequested: service.consentRequested
    readonly property bool mirrorConsentPending: service.consentPending
    readonly property bool mirrorSettingsActionRequired: service.settingsActionRequired
    readonly property bool windowsDismissEnabled: service.windowsDismissPermitted
    readonly property bool appOpenEnabled: service.appOpenPermitted
    readonly property int mirroredCount: service.mirroredCount
    readonly property int windowsDismissals: service.windowsDismissals
    readonly property int mirroredLocalDismissals: service.mirroredLocalDismissals
    readonly property int appOpenRefusals: service.appOpenRefusals
    readonly property int appOpenInvocations: service.appOpenInvocations
    readonly property int mirrorAccessRequests: service.accessRequestsIssued
    readonly property int mirrorAccessRequestRefusals: service.accessRequestRefusals
    readonly property int mirrorWrites: service.mirrorWrites
    readonly property int mirrorDisables: service.mirrorDisables
    readonly property int deniedPolls: service.deniedPolls
    readonly property bool deniedPollExhausted: service.deniedPollExhausted
    readonly property bool deniedPollingActive: service.deniedPollingActive
    readonly property int settingsOpenRequests: service.settingsOpenRequests

    readonly property bool pathConfined: service.pathConfined
    readonly property string pathError: service.pathError
    readonly property string historyPath: service.historyPath
    readonly property string imageCacheDirectory: service.imageCacheDirectory
    readonly property string historyError: service.historyError

    readonly property int localDismissals: service.localDismissals
    readonly property int protectedDismissals: service.protectedDismissals
    readonly property int deliveredNotifications: service.deliveredNotifications
    readonly property int unconfirmedDeliveries: service.unconfirmedDeliveries
    readonly property int confirmedDeliveries: service.confirmedDeliveries
    readonly property int rejectedImageSources: service.rejectedImageSources
    readonly property string lastRejectedImageSource: service.lastRejectedImageSource
    readonly property string lastImageSourceError: service.lastImageSourceError
    readonly property int imageCacheErrors: service.imageCacheErrors
    readonly property int imageCacheDropped: service.imageCacheDropped
    readonly property int imageCacheEvicted: service.imageCacheEvicted
    readonly property int imageCachePruned: service.imageCachePruned
    readonly property int activeImageWriters: service.activeImageWriters
    readonly property int queuedImageWriters: service.queuedImageWriters
    readonly property var imageCacheRequests: service.imageCacheRequests

    function imageCacheSlot(index): var {
        return service.imageCacheSlot(index);
    }

    // A bounded previous-slice UI calls these helpers. Windows has no Hyprland
    // fullscreen toplevels in this slice, and do-not-disturb is not staged.
    function hasFullscreen(): bool {
        return false;
    }

    function shouldShowPopup(): bool {
        return !service.popupsSuppressed;
    }

    function historyJson(): string {
        return service.serializeHistory();
    }

    function historyContains(recordId): bool {
        return service.historyContains(recordId);
    }

    function historyContainsNotificationId(notificationId): bool {
        return service.historyContainsNotificationId(notificationId);
    }

    function recordForNotificationId(notificationId): var {
        return service.recordForNotificationId(notificationId);
    }

    function liveRecordForNotificationId(notificationId): var {
        return service.liveRecordForNotificationId(notificationId);
    }

    function findRecordById(recordId): var {
        return service.findRecordById(recordId);
    }

    function dismiss(record): void {
        service.dismiss(record);
    }

    function clearAll(): void {
        service.clearAll();
    }

    function imageCachePath(record): string {
        return service.imageCachePath(record);
    }

    function applyCachedImage(record, path): bool {
        return service.applyCachedImage(record, path);
    }

    function markImageCacheFailed(record): void {
        service.markImageCacheFailed(record);
    }

    // Injected into the service. The listing is only used to prune or evict
    // files inside the confined notification image-cache directory; deletion is
    // re-checked against that directory here as well as in the service, and a
    // disabled or unconfined shell lists and deletes nothing.
    function listImageCacheFiles(): var {
        if (!root.enabled || !root.service.pathConfined)
            return [];
        const files = [];
        for (let i = 0; i < root._imageCacheFileModel.count; i++) {
            const path = String(root._imageCacheFileModel.get(i, "filePath") ?? "");
            const modified = root._imageCacheFileModel.get(i, "modified");
            files.push({
                path: path,
                savedAt: modified instanceof Date ? modified.getTime() : 0
            });
        }
        return files;
    }

    function removeImageCacheFile(path): bool {
        if (!root.enabled || !root.service.pathConfined)
            return false;
        const directory = root.service.imageCacheDirectory.toLowerCase();
        const target = root.normalize(String(path ?? "")).toLowerCase();
        if (directory === "" || !target.startsWith(directory + "/"))
            return false;
        return CUtils.deleteFile(Qt.resolvedUrl(String(path)));
    }

    // Only the bounded host/fixture calls this. The backend's local path is the
    // only delivery path staged in this slice; it never requests system access.
    // The summary/body are part of the confirmation: a returned id that already
    // existed must not count as a delivered send.
    function postLocalTest(summary, body, args): int {
        if (!root.enabled || !root.backend || root.service.status !== "local")
            return 0;
        const id = root.backend.notifySend(summary, body, args ?? []);
        root.service.expectDelivery(id, summary, body);
        return id;
    }

    // The notification center's explicit consent button calls this. It is
    // refused unless the access state is Unspecified and no request exists in
    // this process, and it is never called from a timer, binding or startup.
    function requestMirrorAccess(): bool {
        return root.service.requestAccess();
    }

    // Explicit user action from the denied state. It opens Windows' notification
    // access settings page; no access request is issued from here.
    function openNotificationAccessSettings(): void {
        root.service.noteSettingsOpened();
        NotificationSettings.openAccessSettings();
    }

    function normalize(value): string {
        if (value === undefined || value === null)
            return "";
        let path = String(value).replace(/\\/g, "/");
        while (path.length > 1 && path.endsWith("/"))
            path = path.slice(0, -1);
        return path;
    }

    readonly property Loader _nativeLoader: Loader {
        id: nativeLoader

        active: root.enabled
        source: root.enabled ? Qt.resolvedUrl("NativeNotificationBackend.qml") : ""
    }

    // Read-only view of the confined image cache used for pruning and the hard
    // file quota. The folder is empty while disabled or unconfined, and the
    // service never deletes anything outside imageCacheDirectory.
    readonly property FolderListModel _imageCacheFileModel: FolderListModel {
        folder: root.enabled && root.service.imageCacheDirectory !== ""
            ? Qt.resolvedUrl(root.service.imageCacheDirectory) : ""
        nameFilters: ["*.png"]
        showDirs: false
        showHidden: false
        showDotAndDotDot: false
        sortField: FolderListModel.Time
    }

    // The history file is written only after a successful load and only inside
    // the isolated profile. FileView performs no read when disabled because the
    // path stays empty.
    readonly property FileView _storage: FileView {
        id: storage

        printErrors: false
        path: root.enabled && root.service.pathConfined ? root.service.historyPath : ""

        onLoaded: {
            root.service.restoreHistory(text());
            root.service.pruneImageCacheFiles();
        }
        onLoadFailed: error => {
            if (error === FileViewError.FileNotFound) {
                root.service.restoreHistory("");
                root.service.pruneImageCacheFiles();
                Qt.callLater(() => storage.setText(root.service.serializeHistory()));
            } else {
                root.service.failHistory("The notification history could not be read from the isolated profile.");
            }
        }
    }

    readonly property Timer _saveTimer: Timer {
        id: saveTimer

        interval: 1000
        onTriggered: {
            if (!root.enabled || !root.service.pathConfined || !root.service.historyLoaded)
                return;
            storage.setText(root.service.serializeHistory());
        }
    }

    Connections {
        target: root.service
        function onHistoryChanged(): void {
            if (!root.enabled || !root.service.historyLoaded)
                return;
            saveTimer.restart();
        }
    }
}
