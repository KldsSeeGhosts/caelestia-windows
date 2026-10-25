import QtQuick
import Quickshell.Services.Notifications

// Loaded by URL only after Notifs.enabled. Constructing NotificationServer
// claims the per-session notification bus mutex or starts the backend's own
// bounded five-second claim retry (server.cpp claimSession), and connects the
// local delivery signal. Construction sends no system access request.
//
// mirrorSystemNotifications is set to false at construction, before the
// post-reload hook applies it. At the pinned backend the default is true
// (qml.hpp line 112); leaving it there would construct the system mirror,
// request notification-listener access and start reading real toasts. Mirroring
// is enabled only by the service's setMirroring() after the explicit consent
// button produced an Allowed status.
//
// requestAccess() is the single consent path. It is invoked only from
// NotificationsService.requestAccess(), which the original notification-center
// button calls while the state is Unspecified; nothing in this wrapper calls it.
// The pinned backend itself only raises an OS prompt when Windows reports
// Unspecified, and GetAccessStatus is read from inside its worker.
//
// The pinned backend does not publish whether the claim succeeded, is retrying,
// or was forwarded (server.cpp lines 55-91 only log and retry internally), so
// ownership stays "unknown". The service keeps the explicit "contended" state
// for a backend revision that exposes it.
QtObject {
    id: root

    readonly property bool ready: started
    property bool started: false

    readonly property string ownership: "unknown"

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

    // Explicit consent path. The service calls this at most once per process.
    function requestAccess(): void {
        server.requestSystemNotificationAccess();
    }

    // Called only after Windows reports Allowed. The backend's own setter also
    // reads the access status and never prompts for Allowed/Denied/Unavailable.
    function setMirroring(enabled): void {
        server.mirrorSystemNotifications = enabled === true;
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
