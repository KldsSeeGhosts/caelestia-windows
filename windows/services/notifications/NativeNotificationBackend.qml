import QtQuick
import Quickshell.Services.Notifications

// Loaded by URL only after Notifs.enabled. Constructing NotificationServer
// claims the per-session notification bus mutex or starts the backend's own
// bounded five-second claim retry (server.cpp claimSession), and connects the
// local delivery signal. Construction sends no system access request.
//
// mirrorSystemNotifications is set to false at construction, before the
// post-reload hook applies it, and the property is never written true. At the
// pinned backend the default is true (qml.hpp line 112); leaving it there would
// construct the system mirror, request notification-listener access and let a
// local dismiss remove a real Windows notification. That path stays out of this
// slice.
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

        // Backend default is true. This slice must never enable mirroring.
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
