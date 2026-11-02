import QtQuick
import Quickshell.Services.Notifications

// Loaded by URL only after Notifs.enabled. Constructing the native
// notification server claims the per-session notification bus mutex on a
// dedicated thread or waits there for the current owner to release or abandon
// it (server.cpp claimSession), and connects the local delivery signal.
// Construction sends no system access request.
//
// mirrorSystemNotifications is set to false at construction, before the
// post-reload hook applies it. At the pinned backend the default is true
// (qml.hpp line 112); leaving it there would construct the system mirror,
// request notification-listener access and start reading real toasts. Mirroring
// is enabled only by the service's setMirroring() after a non-prompting query
// or the explicit consent button produces an Allowed status.
//
// requestAccess() is the single consent path. It is invoked only from
// NotificationsService.requestAccess(), which the original notification-center
// button calls while the state is Unspecified; nothing in this wrapper calls it.
// The pinned backend raises the OS prompt asynchronously on the UI thread when
// Windows reports Unspecified, and its worker only reads the result.
//
// The pinned backend exposes a non-prompting refreshAccessStatus() query, a
// process-lifetime accessRequested latch and an activateMirrored() path that
// does not dismiss the real toast. Uses remain feature-detected for older
// backends; absent activation is refused rather than dismissing the toast.
//
// Session-bus ownership is real mutex ownership, not the existence of a named
// object: the backend's lock thread waits without polling and publishes "owner"
// once it holds the mutex and "contended" while another shell does.
QtObject {
    id: root

    readonly property bool ready: started
    property bool started: false

    readonly property string ownership: server.ownership

    signal notificationReceived(var notification)

    // QtObject has no default property, so the native server is the value of an
    // explicit property rather than a bare child object.
    readonly property NotificationServer nativeServer: NotificationServer {
        id: server

        keepOnReload: false
        actionsSupported: true
        bodyHyperlinksSupported: true
        bodyImagesSupported: true
        bodyMarkupSupported: true
        imageSupported: true
        persistenceSupported: true

        // Backend default is true. Mirroring starts off in every mode.
        mirrorSystemNotifications: false

        onNotification: notification => {
            // The original Notifs.qml tracks every delivered notification so
            // the native server keeps it in trackedNotifications.
            notification.tracked = true;
            root.notificationReceived(notification);
        }
    }

    readonly property bool mirrorSystemNotifications: server.mirrorSystemNotifications
    readonly property bool systemMirrorActive: server.systemMirrorActive
    readonly property int systemNotificationAccess: server.systemNotificationAccess
    // Process-lifetime consent latch published by the consent-fix revision; a
    // reloaded service reconciles with it instead of re-asking.
    readonly property bool accessRequested: server.accessRequested === true

    // Explicit consent path. The service calls this at most once per process.
    function requestAccess(): void {
        server.requestSystemNotificationAccess();
    }

    // Non-prompting query for startup and bounded denied polling.
    function refreshAccessStatus(): void {
        if (typeof server.refreshAccessStatus === "function")
            server.refreshAccessStatus();
    }

    // Called only after Windows reports Allowed. The backend's own setter also
    // reads the access status and never prompts for Allowed/Denied/Unavailable.
    function setMirroring(enabled): void {
        server.mirrorSystemNotifications = enabled === true;
    }

    // Activates a mirrored record's source app without dismissing the real
    // Windows toast. Older backends without this member are refused by the
    // service rather than using the auto-closing generic action path.
    function activateMirrored(id): bool {
        if (typeof server.activateMirrored !== "function")
            return false;
        return server.activateMirrored(id) === true;
    }

    function notifySend(summary, body, args): int {
        return server.notifySend(summary, body, args ?? []);
    }

    // The post-reload hook that connects the server can run during object
    // completion. A zero-interval timer marks the facade ready on the next
    // event-loop turn without inventing a native claim signal.
    readonly property Timer _readyTimer: Timer {
        interval: 0
        running: true
        onTriggered: root.started = true
    }
}
