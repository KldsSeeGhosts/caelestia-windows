pragma Singleton
pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Caelestia.Config
import Caelestia.I18n

// Windows replacement for the original services/Notifs.qml singleton contract.
// The pure NotificationsService owns records, expiry, dismissal and history
// serialization; this facade adds only the opt-in, the native loader, and the
// isolated-profile FileView. It intentionally imports no HOME/XDG path object
// and never constructs the native server while disabled.
Singleton {
    id: root

    // Local delivery only. -NotificationsMode Local maps to this single opt-in;
    // there is no mirroring/interactive mode in this slice.
    readonly property bool enabled: Quickshell.env("CAELESTIA_WINDOWS_NOTIFICATIONS") === "1"

    // Quickshell's state/cache directories are the staged //@ pragma values
    // (profile/state and profile/cache). The profile root is their parent, and
    // the service refuses any state/cache path outside it. No upstream path
    // fallback exists here.
    readonly property string profileRoot: {
        const state = root.normalize(Quickshell.stateDir);
        const slash = state.lastIndexOf("/");
        return slash > 0 ? state.substring(0, slash) : "";
    }

    readonly property NotificationsService service: NotificationsService {
        enabled: root.enabled
        translator: Tr
        defaultExpireTimeout: GlobalConfig.notifs.defaultExpireTimeout
        fullscreenExpireTimeout: GlobalConfig.notifs.fullscreenExpireTimeout
        expirePopups: GlobalConfig.notifs.expire
        profileRoot: root.profileRoot
        stateDirectory: Quickshell.stateDir
        cacheDirectory: Quickshell.cacheDir
        backend: nativeLoader.item ?? null
        backendError: nativeLoader.status === Loader.Error
            ? "The Windows notification backend component failed to load." : ""
    }

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

    readonly property bool pathConfined: service.pathConfined
    readonly property string pathError: service.pathError
    readonly property string historyPath: service.historyPath
    readonly property string imageCacheDirectory: service.imageCacheDirectory
    readonly property string historyError: service.historyError

    readonly property int localDismissals: service.localDismissals
    readonly property int protectedDismissals: service.protectedDismissals
    readonly property int deliveredNotifications: service.deliveredNotifications
    readonly property int unconfirmedDeliveries: service.unconfirmedDeliveries
    readonly property var imageCacheRequests: service.imageCacheRequests

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

    // Only the bounded host/fixture calls this. The backend's local path is the
    // only delivery path staged in this slice; it never requests system access.
    function postLocalTest(summary, body, args): int {
        if (!root.enabled || !root.backend || root.service.status !== "local")
            return 0;
        const id = root.backend.notifySend(summary, body, args ?? []);
        root.service.expectDelivery(id);
        return id;
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

    // The history file is written only after a successful load and only inside
    // the isolated profile. FileView performs no read when disabled because the
    // path stays empty.
    readonly property FileView _storage: FileView {
        id: storage

        printErrors: false
        path: root.enabled && root.service.pathConfined ? root.service.historyPath : ""

        onLoaded: root.service.restoreHistory(text())
        onLoadFailed: error => {
            if (error === FileViewError.FileNotFound) {
                root.service.restoreHistory("");
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
