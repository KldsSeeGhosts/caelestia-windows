import QtQuick

// Windows adaptation of the original services/NotifData.qml record consumed by
// modules/notifications/*. It is a pure QtObject: no Quickshell import, no
// compositor fullscreen query, no image copy or cache window and no process
// call. NotificationsService injects service, expiry configuration and the
// source notification; the facade owns persistence. A notification image is
// used only when the service accepts it as an allowlisted image://icon theme
// name or as a file inside the staged shell assets directory; otherwise it
// stays empty and the original card shows its fallback icon. The app icon goes
// through the same allowlist, and the body is sanitized of Markdown/HTML images
// before the original Markdown-rendering UI can load them.
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
    // Latch Windows identity for this record's lifetime. Replacement hints
    // cannot turn a native toast into a local record and bypass dismissal consent.
    property bool _wasMirrored: false
    readonly property bool mirrored: record._wasMirrored
    property bool imageSourceRejected: false
    property string imageSourceError: ""
    property bool hasFullscreen: false
    // Monotonic arrival order assigned by the service. Delivery confirmation
    // only accepts a record received after the send that is being checked.
    property int arrivalSequence: 0

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
        record.updateBody(source.body);
        record.updateAppIcon(source.appIcon);
        record.appName = String(source.appName ?? "");
        record.updateImage(source.image);
        record.hints = source.hints ?? ({});
        record.expireTimeout = Number.isFinite(source.expireTimeout)
            ? source.expireTimeout : (record.service?.defaultExpireTimeout ?? 5000);
        record.urgency = Number.isInteger(source.urgency) ? source.urgency : 1;
        record.resident = source.resident === true;
        record.hasActionIcons = source.hasActionIcons === true;
        record._wasMirrored = record.mirrored
            || (record.service?.isSystemNotification(source) ?? false);
        record.local = !record.mirrored;
        record.syncActions();
    }

    // The service owns the body filter. The original popup/sidebar render the
    // body as Markdown, so Markdown/HTML images are reduced to alt text before
    // this record exposes it. Without the service the body stays empty rather
    // than leaking an unfiltered Markdown source; records are only constructed
    // by the service (or its fixture).
    function updateBody(value): void {
        const raw = String(value ?? "");
        record.body = record.service && typeof record.service.sanitizeBody === "function"
            ? record.service.sanitizeBody(raw) : "";
    }

    // Quickshell.iconPath() turns the app icon into image://icon/<value>, which
    // also reaches QIcon::fromTheme. Only a theme name or a staged asset path is
    // kept; anything else becomes "" so the original fallback icon renders.
    function updateAppIcon(value): void {
        const raw = String(value ?? "");
        if (raw === "") {
            record.appIcon = "";
            return;
        }
        const result = record.service ? record.service.validateAppIcon(raw) : null;
        record.appIcon = result && result.accepted ? String(result.value) : "";
    }

    // The service owns the single source-trust decision. A rejected source is
    // dropped from this record entirely, so the original card shows its
    // existing fallback icon and no file is ever opened. An accepted source is
    // the validated UI URL: image:// for a provider, file:/// for a staged
    // asset.
    function updateImage(source): void {
        const raw = String(source ?? "");
        if (raw === "") {
            record.image = "";
            record.imageSourceRejected = false;
            record.imageSourceError = "";
            return;
        }

        const result = record.service ? record.service.validateImageSource(raw) : null;
        if (!result || !result.accepted) {
            record.image = "";
            record.imageSourceRejected = true;
            record.imageSourceError = String(result?.reason ?? "No notification image validator is available.");
            record.service?.reportRejectedImageSource(raw, record.imageSourceError);
            return;
        }

        record.image = result.canonical;
        record.imageSourceRejected = false;
        record.imageSourceError = "";
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
            // Restored history: re-apply the body filter and the app-icon
            // allowlist even though the service already validated the entry.
            record.updateBody(record.body);
            record.updateAppIcon(record.appIcon);
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
                record.updateBody(record.notification.body);
        }

        function onAppIconChanged(): void {
            if (record.notification)
                record.updateAppIcon(record.notification.appIcon);
        }

        function onAppNameChanged(): void {
            if (record.notification)
                record.appName = String(record.notification.appName ?? "");
        }

        function onImageChanged(): void {
            if (!record.notification)
                return;
            record.updateImage(record.notification.image);
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
            record._wasMirrored = record.mirrored
                || (record.service?.isSystemNotification(record.notification) ?? false);
            record.local = !record.mirrored;
            record.syncActions();
        }
    }
}
