//@ pragma AppId org.caelestia.windows-notifications-prototype
//@ pragma DefaultEnv QS_NO_RELOAD_POPUP=1
//@ pragma DefaultEnv QSG_RENDER_LOOP=threaded

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Caelestia
import Caelestia.Config
import qs.components
import qs.components.containers
import qs.services
import qs.modules.notifications as NotificationUI
import qs.modules.sidebar as Sidebar

// A separate bounded M2 host for the original Caelestia notification popup
// list. It stages the original modules/notifications Content/Notification
// components and the original NotifData contract, but only with the local
// delivery opt-in. System notification mirroring, access requests, IPC
// mutations, shortcuts, DnD state and every other shell controller stay
// unloaded.
ShellRoot {
    id: root

    readonly property bool smoke: Quickshell.env("CAELESTIA_SHELL_SMOKE") === "1"
    readonly property int screenIndex: Number(Quickshell.env("CAELESTIA_SHELL_SCREEN") || "0")
    readonly property ShellScreen selectedScreen: Quickshell.screens[screenIndex] ?? null
    readonly property int previewWidth: Math.min(920, (selectedScreen?.width ?? 800) - 160)
    readonly property int previewHeight: Math.min(620, (selectedScreen?.height ?? 780) - 160)

    property var initialNotificationState: null
    property bool failed: false
    property int phase: 0
    property int waitTicks: 0
    property int restoredCount: 0
    property var restoredIds: []
    property bool runB: false
    property int postedId: 0
    property string postedRecordId: ""
    property string testSummary: "Caelestia Windows local notification"
    property string testBody: "Local delivery test " + Date.now()

    settings.watchFiles: false

    // Required by the original modules/notifications/Content.qml. All other
    // panels stay absent; the host only renders the notification list.
    readonly property ScreenState notificationScreenState: ScreenState {
        modelData: root.selectedScreen
    }

    // Sidebar notification expansion state. The original sidebar components
    // require this PersistentProperties object; the bounded host stages only
    // the notification dock, not the rest of the sidebar.
    readonly property var notificationProps: Sidebar.Props {}

    // Content only reads these when the matching screenState flag is true. The
    // bounded host leaves every flag false and supplies inert placeholders so
    // the original required properties are still satisfied.
    readonly property Item osdPlaceholder: Item {
        visible: false
        y: root.previewHeight
    }
    readonly property Item sessionPlaceholder: Item {
        visible: false
        y: root.previewHeight
    }
    readonly property Item utilitiesPlaceholder: Item {
        visible: false
        y: root.previewHeight
    }

    function notificationState(): var {
        const profile = Notifs.profileRoot.toLowerCase();
        const history = Notifs.historyPath.toLowerCase();
        const posted = root.postedId > 0
            ? (Notifs.liveRecordForNotificationId(root.postedId)
                ?? (root.postedRecordId !== "" ? Notifs.findRecordById(root.postedRecordId) : null))
            : null;
        return {
            enabled: Notifs.enabled,
            status: Notifs.status,
            reason: Notifs.reason,
            backendLoaded: Notifs.backendLoaded,
            nativeRequested: Notifs.nativeRequested,
            mirroringOff: Notifs.mirroringOff,
            mirrorSystemNotifications: Notifs.mirrorSystemNotifications,
            systemMirrorActive: Notifs.systemMirrorActive,
            systemNotificationAccess: Notifs.systemNotificationAccess,
            ownership: Notifs.ownership,
            ownershipKnown: Notifs.ownershipKnown,
            contended: Notifs.contended,
            deliveryUnconfirmed: Notifs.deliveryUnconfirmed,
            historyLoaded: Notifs.loaded,
            historyError: Notifs.historyError,
            pathConfined: Notifs.pathConfined,
            pathError: Notifs.pathError,
            historyPath: Notifs.historyPath,
            historyInsideProfile: profile !== "" && history.startsWith(profile + "/"),
            listCount: Notifs.list.length,
            popupCount: Notifs.popups.length,
            notClosedCount: Notifs.notClosed.length,
            notificationIds: Notifs.list.map(n => String(n.notificationId)),
            summaries: Notifs.list.map(n => String(n.summary)),
            restoredCount: root.restoredCount,
            restoredIds: root.restoredIds,
            runMode: root.runB ? "expire-dismiss" : "persist",
            postedId: root.postedId,
            postedRecordId: root.postedRecordId,
            postedPresent: posted !== null,
            postedPopup: posted?.popup ?? false,
            postedLocal: posted?.local ?? false,
            postedActions: posted?.actions?.length ?? 0,
            postedSummary: posted?.summary ?? "",
            historyContainsPosted: root.postedRecordId !== ""
                ? Notifs.historyContains(root.postedRecordId) : false,
            localDismissals: Notifs.localDismissals,
            protectedDismissals: Notifs.protectedDismissals,
            unconfirmedDeliveries: Notifs.unconfirmedDeliveries,
            confirmedDeliveries: Notifs.confirmedDeliveries,
            deliveryConfirmation: Notifs.deliveryConfirmation,
            lastSendRefusal: Notifs.lastSendRefusal,
            rejectedImageSources: Notifs.rejectedImageSources,
            lastImageSourceError: Notifs.lastImageSourceError,
            uiLoaded: contentHost.item !== null,
            dockLoaded: dockHost.item !== null,
            contentWidth: contentHost.item?.width ?? 0,
            contentHeight: contentHost.item?.height ?? 0,
            contentImplicitHeight: contentHost.item?.implicitHeight ?? 0,
            contentVisible: contentHost.item?.visible ?? false
        };
    }

    function fail(message: string): void {
        root.failed = true;
        console.error("CAELESTIA_NOTIFICATIONS_FAIL: " + message);
        Qt.exit(1);
    }

    function checkPolicy(state): void {
        const requested = Quickshell.env("CAELESTIA_SHELL_SCALE");
        const accessOk = state.enabled
            ? state.systemNotificationAccess === 0
            : state.systemNotificationAccess === -1;
        if ((requested !== "native" && Math.abs(win.devicePixelRatio - Number(requested)) > 0.01)
                || win.width !== root.previewWidth || win.height !== root.previewHeight
                || bodyFont.status !== FontLoader.Ready || iconFont.status !== FontLoader.Ready
                || state.enabled !== (Quickshell.env("CAELESTIA_WINDOWS_NOTIFICATIONS") === "1")
                || !state.mirroringOff || state.mirrorSystemNotifications !== false
                || state.systemMirrorActive !== false || !accessOk) {
            root.fail("UI, fonts, DPI, opt-in or mirroring policy");
            return;
        }
    }

    function checkInitial(state): void {
        root.checkPolicy(state);
        if (root.failed)
            return;

        if (state.enabled) {
            if (!state.nativeRequested || !state.backendLoaded) {
                root.fail("local mode did not activate the native backend loader");
                return;
            }
            if (state.status !== "local") {
                root.fail("local service did not settle: " + state.status + " (" + state.reason + ")");
                return;
            }
            if (!state.historyLoaded) {
                root.fail("local mode did not load the isolated history");
                return;
            }
            if (!state.pathConfined || !state.historyInsideProfile) {
                root.fail("notification history is outside the isolated profile");
                return;
            }
            if (!state.uiLoaded || !state.dockLoaded) {
                root.fail("original notification components did not load");
                return;
            }
        } else {
            if (state.status !== "disabled" || state.nativeRequested || state.backendLoaded
                    || state.uiLoaded || state.dockLoaded || state.listCount !== 0 || state.popupCount !== 0) {
                root.fail("disabled mode constructed the backend, original UI or records");
                return;
            }
        }

        root.restoredCount = Notifs.list.length;
        root.restoredIds = Notifs.list.map(n => String(n.notificationId));
        root.runB = root.restoredCount > 0;
        root.initialNotificationState = root.notificationState();

        console.log("CAELESTIA_NOTIFICATIONS_SCREEN", JSON.stringify({
            index: root.screenIndex, name: win.screen.name,
            x: win.screen.x, y: win.screen.y, dpr: win.devicePixelRatio,
            width: win.width, height: win.height
        }));
        console.log("CAELESTIA_NOTIFICATIONS_INITIAL", JSON.stringify(root.initialNotificationState));
    }

    function checkArrival(state): void {
        if (!state.postedPresent || !state.postedLocal || !state.postedPopup) {
            root.fail("local notification did not appear in the original popup list");
            return;
        }
        if (state.postedActions < 1) {
            root.fail("local notification action contract is empty");
            return;
        }
        if (state.uiLoaded !== true || state.dockLoaded !== true || state.status !== "local") {
            root.fail("original list/service state is not settled after arrival");
            return;
        }
    }

    function checkExpired(): void {
        const state = root.notificationState();
        if (!state.postedPresent || state.postedPopup) {
            root.fail("notification popup did not expire while remaining in the list: "
                + JSON.stringify(state));
            return;
        }
        if (state.listCount !== root.restoredCount + 1) {
            root.fail("expired notification left the list instead of only the popup");
            return;
        }
    }

    function checkDismissed(): void {
        const state = root.notificationState();
        if (state.listCount !== root.restoredCount) {
            root.fail("local dismiss did not remove only the test notification");
            return;
        }
        if (state.localDismissals < 1) {
            root.fail("local dismiss counter did not advance");
            return;
        }
        if (state.protectedDismissals !== 0) {
            root.fail("a real Windows notification was targeted for dismissal");
            return;
        }
    }

    function finalize(): void {
        const state = root.notificationState();
        root.checkPolicy(state);
        if (root.failed)
            return;

        if (!state.enabled) {
            if (state.status !== "disabled" || state.nativeRequested || state.backendLoaded
                    || state.uiLoaded || state.dockLoaded || state.listCount !== 0 || state.popupCount !== 0) {
                root.fail("disabled mode changed during smoke");
                return;
            }
        } else {
            if (state.status !== "local" || !state.pathConfined
                    || !state.historyInsideProfile) {
                root.fail("local service state changed during smoke");
                return;
            }
            if (state.protectedDismissals !== 0) {
                root.fail("real Windows notification dismissal was attempted");
                return;
            }
            if (!root.runB) {
                if (state.listCount !== root.restoredCount + 1 || state.popupCount !== 1) {
                    root.fail("persist run did not retain one popped-up local notification");
                    return;
                }
                if (!state.historyContainsPosted) {
                    root.fail("persist run lost the local notification from history");
                    return;
                }
            } else {
                if (state.listCount !== root.restoredCount || state.popupCount !== 0) {
                    root.fail("expire/dismiss run did not return to the restored list");
                    return;
                }
                if (state.historyContainsPosted) {
                    root.fail("dismissed local notification survived in history");
                    return;
                }
                for (const id of root.restoredIds) {
                    if (!Notifs.historyContainsNotificationId(id)) {
                        root.fail("restored notification was lost during the run: " + id);
                        return;
                    }
                }
            }
        }

        console.log("CAELESTIA_NOTIFICATIONS_FINAL", JSON.stringify(state));
        const path = Quickshell.env("CAELESTIA_SHELL_SCREENSHOT");
        CUtils.saveItem(win.contentItem, Qt.resolvedUrl(path), () => {
            console.log("CAELESTIA_NOTIFICATIONS_CAPTURE", path);
            console.log("CAELESTIA_NOTIFICATIONS_PASS", CUtils.qtVersion);
            Qt.quit();
        }, () => {
            console.error("CAELESTIA_NOTIFICATIONS_FAIL: screenshot");
            Qt.exit(1);
        });
    }

    FontLoader {
        id: bodyFont
        source: Quickshell.shellPath("assets/google-sans-flex/GoogleSansFlex-VariableFont_GRAD,ROND,opsz,slnt,wdth,wght.ttf")
    }
    FontLoader {
        id: iconFont
        source: Quickshell.shellPath("assets/material-symbols-rounded/MaterialSymbolsRounded.ttf")
    }

    StyledWindow {
        id: win

        name: "notifications-prototype"
        screen: root.selectedScreen
        visible: root.selectedScreen !== null
        implicitWidth: root.previewWidth
        implicitHeight: root.previewHeight
        anchors.top: true
        anchors.left: true
        margins.top: 80
        margins.left: 80
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Top
        WlrLayershell.keyboardFocus: root.smoke ? WlrKeyboardFocus.None : WlrKeyboardFocus.OnDemand
        mask: root.smoke ? noInput : null
        color: Colours.palette.m3surface

        StyledRect {
            anchors.fill: parent
            color: Colours.palette.m3surface
        }

        Region { id: noInput }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 24
            spacing: 12

            RowLayout {
                Layout.fillWidth: true

                StyledText {
                    text: "Caelestia Windows notifications"
                    font: Tokens.font.body.large
                    Layout.fillWidth: true
                }
                StyledText {
                    text: Notifs.status
                    font: Tokens.font.label.medium
                    color: Colours.palette.m3onSurfaceVariant
                }
            }

            StyledText {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: Notifs.reason
                color: Colours.palette.m3onSurfaceVariant
                font: Tokens.font.body.small
            }

            StyledRect {
                Layout.fillWidth: true
                implicitHeight: 1
                color: Colours.palette.m3outlineVariant
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 16

                // The original sidebar notification center (dock). It shows
                // Notifs.list, so a restored notification is visible after a
                // restart even though only new deliveries pop up.
                StyledRect {
                    Layout.fillHeight: true
                    Layout.preferredWidth: Math.max(300, Math.round(root.previewWidth * 0.38))
                    color: Colours.palette.m3surfaceContainerLow
                    radius: Tokens.rounding.large

                    Loader {
                        id: dockHost
                        active: Notifs.enabled
                        anchors.fill: parent
                        anchors.margins: 12
                        sourceComponent: Sidebar.NotifDock {
                            props: root.notificationProps
                            screenState: root.notificationScreenState
                        }
                    }
                }

                Item {
                    id: notificationArea

                    Layout.fillWidth: true
                    Layout.fillHeight: true

                    StyledText {
                        anchors.centerIn: parent
                        text: Notifs.enabled ? "No notifications yet." : "Local notifications are disabled."
                        color: Colours.palette.m3onSurfaceVariant
                        font: Tokens.font.body.medium
                        visible: Notifs.popups.length === 0
                    }

                    // The original popup list. It is instantiated only with the
                    // local opt-in; disabled mode never loads the original UI
                    // or the native server.
                    Loader {
                        id: contentHost
                        active: Notifs.enabled
                        anchors.fill: parent
                        sourceComponent: NotificationUI.Content {
                            screenState: root.notificationScreenState
                            osdPanel: root.osdPlaceholder
                            sessionPanel: root.sessionPlaceholder
                            utilitiesPanel: root.utilitiesPlaceholder
                        }
                    }
                }
            }
        }

        Shortcut {
            sequence: "Escape"
            enabled: !root.smoke
            onActivated: Qt.quit()
        }
    }

    IpcHandler {
        target: "prototype"
        function state(): string {
            return JSON.stringify(root.notificationState());
        }
        function quit(): void { Qt.quit(); }
    }

    Component.onCompleted: {
        if (!selectedScreen)
            Qt.callLater(() => Qt.exit(1));
    }

    Timer {
        id: check
        running: root.smoke && root.selectedScreen !== null
        repeat: true
        interval: 1000
        onTriggered: {
            if (root.failed)
                return;

            if (Notifs.enabled) {
                if (!Notifs.loaded || Notifs.status === "initializing")
                    return;
            }

            if (root.phase === 0) {
                const state = root.notificationState();
                root.checkInitial(state);
                if (root.failed)
                    return;
                root.initialNotificationState = state;
                if (Notifs.enabled) {
                    // A replacement send has no local replace path in this
                    // slice. It must be refused before notifySend rather than
                    // left pending and reported as forwarded/unconfirmed.
                    const refused = Notifs.postLocalTest(root.testSummary, root.testBody, ["-r", "999"]);
                    if (refused !== 0 || Notifs.lastSendRefusal.indexOf("Replacement") < 0) {
                        root.fail("a replacement send was not refused: " + Notifs.lastSendRefusal);
                        return;
                    }
                    const args = root.runB
                        ? ["-a", "Caelestia Windows", "-t", "1200", "-A", "default=Open"]
                        : ["-a", "Caelestia Windows", "-t", "60000", "-A", "default=Open"];
                    root.postedId = Notifs.postLocalTest(root.testSummary, root.testBody, args);
                    if (root.postedId <= 0) {
                        root.fail("local notifySend did not return an id; another notification owner may be active");
                        return;
                    }
                }
                root.phase = 1;
                return;
            }

            if (!Notifs.enabled) {
                root.finalize();
                return;
            }

            if (root.phase === 1) {
                if (Notifs.deliveryUnconfirmed) {
                    root.fail("local notification was not delivered; another notification owner may be active");
                    return;
                }
                const record = Notifs.liveRecordForNotificationId(root.postedId);
                if (!record) {
                    if (++root.waitTicks > 5) {
                        root.fail("local notification was not delivered; another notification owner may be active");
                        return;
                    }
                    return;
                }
                root.waitTicks = 0;
                root.postedRecordId = String(record.recordId ?? "");
                root.checkArrival(root.notificationState());
                if (root.failed)
                    return;
                root.phase = 2;
                return;
            }

            if (root.phase === 2) {
                if (!root.runB) {
                    root.phase = 3;
                    return;
                }
                const record = Notifs.liveRecordForNotificationId(root.postedId);
                if (record && record.popup) {
                    if (++root.waitTicks > 6) {
                        root.fail("notification popup did not expire");
                        return;
                    }
                    return;
                }
                root.waitTicks = 0;
                root.checkExpired();
                if (root.failed)
                    return;
                Notifs.dismiss(record);
                root.phase = 3;
                return;
            }

            if (root.phase === 3) {
                if (root.runB) {
                    if (Notifs.liveRecordForNotificationId(root.postedId)) {
                        if (++root.waitTicks > 3) {
                            root.fail("local dismiss did not remove the test notification");
                            return;
                        }
                        return;
                    }
                    root.waitTicks = 0;
                    root.checkDismissed();
                    if (root.failed)
                        return;
                }
                root.phase = 4;
                return;
            }

            if (root.phase === 4) {
                root.phase = 5;
                return;
            }

            root.finalize();
        }
    }

    Timer {
        running: root.smoke
        interval: 20000
        onTriggered: {
            console.error("CAELESTIA_NOTIFICATIONS_FAIL: timeout", Notifs.status,
                Notifs.reason, JSON.stringify(root.notificationState()));
            Qt.exit(1);
        }
    }
}
