import QtQuick

// Windows adaptation of the original services/NotifData.qml record consumed by
// modules/notifications/*. It is a pure QtObject: no Quickshell import, no
// compositor fullscreen query, no hidden native image-cache window and no
// process call. NotificationsService injects service, expiry configuration and
// the source notification; the facade owns persistence and any host-provided
// image cache.
//
// close() keeps the original hover lock contract: a locked card is marked
// closed but is only removed (and only then dismissed) when the last lock is
// released. Dismissal is delegated to the service: a local record is closed
// locally, and a Windows-toast-backed record removes the real toast only when
// the separate dismissal opt-in is present. Actions are routed through the
// service so app-open on a mirrored record can stay disabled.
QtObject {
    id: record

    property var service: null
    property string recordId: ""
    property bool popup: false
    property bool closed: false
    property var locks: new Set()
    property date time: new Date()
    property int ageMins: 0

    property var notification: null
    property string notificationId: ""
    property string summary: ""
    property string body: ""
    property string appIcon: ""
    property string appName: ""
    property string image: ""
    property var hints: ({})
    property real expireTimeout: 5000
    property int urgency: 1
    property bool resident: false
    property bool hasActionIcons: false
    property var actions: []
    property var historicalActions: []
    property bool local: false
    // True only for a record delivered from a real Windows toast, identified by
    // the backend's x-windows-toast-id / x-windows-aumid hints. Its app name and
    // icon are the original UI fields; no extra visual state is added.
    property bool mirrored: false
    property bool imageCachePending: false
    property bool hasFullscreen: false

    readonly property string timeStr: {
        if (record.ageMins < 1)
            return record.translate("now", "now");

        const hours = Math.floor(record.ageMins / 60);
        const days = Math.floor(hours / 24);

        if (days > 0)
            return record.translateCtx("%1d", "abbreviated notification age, days").arg(days);
        if (hours > 0)
            return record.translateCtx("%1h", "abbreviated notification age, hours").arg(hours);
        return record.translateCtx("%1m", "abbreviated notification age, minutes").arg(record.ageMins);
    }

    function translate(text, fallback): string {
        return record.service?.translator?.tr(text) ?? fallback;
    }

    function translateCtx(text, context): string {
        return record.service?.translator?.trCtx(text, context) ?? text;
    }

    readonly property Timer timeStrTimer: Timer {
        running: !record.closed
        repeat: true
        interval: 5000
        onTriggered: record.updateTimeStr()
    }

    readonly property Timer timer: Timer {
        running: !record.closed && record.popup
        repeat: false
        interval: {
            const configured = record.expireTimeout > 0
                ? record.expireTimeout
                : (record.hasFullscreen
                    ? (record.service?.fullscreenExpireTimeout ?? 2000)
                    : (record.service?.defaultExpireTimeout ?? 5000));
            return Math.max(1, Math.round(configured));
        }
        onTriggered: record.service?.handleExpiry(record)
    }

    readonly property ComponentsConnections _connections: ComponentsConnections {
        record: record
    }

    function syncFromNotification(): void {
        const source = record.notification;
        if (!source)
            return;

        record.notificationId = String(source.id ?? record.notificationId);
        record.summary = String(source.summary ?? "");
        record.body = String(source.body ?? "");
        record.appIcon = String(source.appIcon ?? "");
        record.appName = String(source.appName ?? "");
        record.image = String(source.image ?? "");
        record.hints = source.hints ?? ({});
        record.expireTimeout = Number.isFinite(source.expireTimeout)
            ? source.expireTimeout : (record.service?.defaultExpireTimeout ?? 5000);
        record.urgency = Number.isInteger(source.urgency) ? source.urgency : 1;
        record.resident = source.resident === true;
        record.hasActionIcons = source.hasActionIcons === true;
        record.local = !record.service?.isSystemNotification(source);
        record.mirrored = !record.local;
        record.syncActions();
        record.imageCachePending = record.service?.needsImageCache(record) ?? false;
    }

    function syncActions(): void {
        if (record.notification) {
            const sourceActions = record.notification.actions ?? [];
            record.actions = Array.prototype.map.call(sourceActions, action => {
                const identifier = String(action.identifier ?? "");
                return {
                    identifier: identifier,
                    text: String(action.text ?? ""),
                    // App-open on a mirrored toast activates/launches the source
                    // app, so the original action row shows it with the existing
                    // disabled styling until that separate opt-in is present.
                    disabled: record.service?.isActionDisabled(record, identifier) ?? false,
                    invoke: () => record.service
                        ? record.service.invokeAction(record, action)
                        : action.invoke()
                };
            });
            return;
        }

        record.actions = (record.historicalActions ?? []).map(action => ({
            identifier: String(action.identifier ?? ""),
            text: String(action.text ?? ""),
            disabled: false,
            invoke: () => record.service?.invokeHistoricalAction(record, action.identifier)
        }));
    }

    function updateTimeStr(): void {
        const diff = Date.now() - record.time.getTime();
        const minutes = Math.floor(diff / 60000);
        record.ageMins = minutes;

        if (minutes < 1) {
            record.timeStrTimer.interval = 5000;
        } else {
            const hours = Math.floor(minutes / 60);
            const days = Math.floor(hours / 24);

            if (days > 0)
                record.timeStrTimer.interval = 3600000;
            else if (hours > 0)
                record.timeStrTimer.interval = 300000;
            else
                record.timeStrTimer.interval = minutes < 10 ? 30000 : 60000;
        }
    }

    function lock(item): void {
        record.locks.add(item);
    }

    function unlock(item): void {
        record.locks.delete(item);
        if (record.closed)
            record.close();
    }

    function close(): void {
        if (record.closed) {
            if ((record.locks?.size ?? 0) === 0)
                record.service?.removeRecord(record, true);
            return;
        }

        record.closed = true;
        if ((record.locks?.size ?? 0) === 0)
            record.service?.removeRecord(record, true);
    }

    Component.onCompleted: {
        if (record.notification) {
            record.syncFromNotification();
        } else {
            record.syncActions();
        }
    }

    // Kept as a separate component so the record can own the Connections
    // object without a nested block capturing the record id in its handlers.
    component ComponentsConnections: Connections {
        required property var record

        target: record.notification
        ignoreUnknownSignals: true

        function onClosed(reason): void {
            if (!record || record.closed)
                return;
            // The backend has already removed its object. Keep the original
            // record fields for a locked card, but never call dismiss on the
            // closed native object.
            record.closed = true;
            record.notification = null;
            record.actions = [];
            record.service?.removeRecord(record, false);
        }

        function onSummaryChanged(): void {
            if (record.notification)
                record.summary = String(record.notification.summary ?? "");
        }

        function onBodyChanged(): void {
            if (record.notification)
                record.body = String(record.notification.body ?? "");
        }

        function onAppIconChanged(): void {
            if (record.notification)
                record.appIcon = String(record.notification.appIcon ?? "");
        }

        function onAppNameChanged(): void {
            if (record.notification)
                record.appName = String(record.notification.appName ?? "");
        }

        function onImageChanged(): void {
            if (!record.notification)
                return;
            record.image = String(record.notification.image ?? "");
            record.imageCachePending = record.service?.needsImageCache(record) ?? false;
        }

        function onExpireTimeoutChanged(): void {
            const source = record.notification;
            if (source)
                record.expireTimeout = Number.isFinite(source.expireTimeout)
                    ? source.expireTimeout : (record.service?.defaultExpireTimeout ?? 5000);
        }

        function onUrgencyChanged(): void {
            const source = record.notification;
            if (source)
                record.urgency = Number.isInteger(source.urgency) ? source.urgency : 1;
        }

        function onResidentChanged(): void {
            if (record.notification)
                record.resident = record.notification.resident === true;
        }

        function onHasActionIconsChanged(): void {
            if (record.notification)
                record.hasActionIcons = record.notification.hasActionIcons === true;
        }

        function onActionsChanged(): void {
            record.syncActions();
        }

        function onHintsChanged(): void {
            if (!record.notification)
                return;
            record.hints = record.notification.hints ?? ({});
            record.mirrored = record.service?.isSystemNotification(record.notification) ?? false;
            record.local = !record.mirrored;
            record.syncActions();
        }
    }
}
