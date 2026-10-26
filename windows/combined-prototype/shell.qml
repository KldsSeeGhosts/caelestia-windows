//@ pragma AppId org.caelestia.windows-combined-prototype
//@ pragma DefaultEnv QS_NO_RELOAD_POPUP=1
//@ pragma DefaultEnv QSG_RENDER_LOOP=threaded

import QtQuick
import Quickshell
import Quickshell.Io
import Caelestia
import Caelestia.Config
import Caelestia.Services
import Caelestia.State
import Caelestia.Windows
import Quickshell.Windows as Native
import qs.components
import qs.services
import qs.daemons
import qs.modules.drawers
import qs.modules.launcher.services
import qs.modules.background

// Original Caelestia modules over isolated Windows service facades.
// Live controls are explicit; smoke keeps every native write gate off.
ShellRoot {
    id: root

    readonly property bool live: Quickshell.env("CAELESTIA_COMBINED_LIVE") === "1"
    readonly property bool smoke: Quickshell.env("CAELESTIA_SHELL_SMOKE") === "1"
    readonly property bool backgroundSmoke: smoke && Quickshell.env("CAELESTIA_WINDOWS_BACKGROUND") === "1"
    readonly property int initialScreenIndex: Number(Quickshell.env("CAELESTIA_SHELL_SCREEN") || "0")
    property int screenIndex: initialScreenIndex
    readonly property ShellScreen selectedScreen: Quickshell.screens[screenIndex] ?? null
    readonly property string sessionMode: Quickshell.env("CAELESTIA_SHELL_SESSION_MODE") || "Disabled"
    readonly property int inset: 80
    readonly property int previewWidth: Math.min(900, (selectedScreen?.width ?? 1060) - inset * 2)
    readonly property int previewHeight: Math.min(620, (selectedScreen?.height ?? 780) - inset * 2)

    settings.watchFiles: false

    WindowsBackground {
        id: desktopBackground
    }

    // A quick desktop-level smoke, independent of the longer panel harness.
    Timer {
        running: root.backgroundSmoke
        interval: 10000
        onTriggered: {
            if (!desktopBackground.checkReady(root.selectedScreen)) {
                root.fail("desktop background or configured clock state not ready");
                return;
            }
            const path = Quickshell.env("CAELESTIA_SHELL_SCREENSHOT");
            const background = ShellState.componentsFor(root.selectedScreen)?.background;
            CUtils.saveItem(background.contentItem, Qt.resolvedUrl(path), () => {
                console.log("CAELESTIA_COMBINED_PASS background", CUtils.qtVersion);
                Qt.quit();
            }, () => root.fail("background smoke screenshot"));
        }
    }

    // One line per service for the harness. The state is the facade status;
    // every control flag is asserted separately so "read-only" is proven, not
    // assumed.
    function serviceStates(): var {
        const firstMonitor = Brightness.monitors.length > 0 ? Brightness.monitors[0] : null;
        return {
            audio: {
                enabled: Audio.enabled, status: Audio.status, controls: Audio.controlsEnabled,
                output: Audio.outputAvailable
            },
            battery: {
                enabled: WindowsBattery.enabled, status: WindowsBattery.status,
                hasBattery: WindowsBattery.hasBattery,
                profiles: WindowsBattery.profilesEnabled, profileWrites: WindowsBattery.profiles.writesPermitted
            },
            bluetooth: {
                enabled: WindowsBluetooth.enabled, status: WindowsBluetooth.status, controls: WindowsBluetooth.controlsEnabled
            },
            brightness: {
                enabled: Brightness.enabled, status: Brightness.status, controls: Brightness.controlsEnabled,
                monitors: Brightness.monitors.length,
                firstMonitorRoute: firstMonitor ? firstMonitor.route : "",
                firstMonitorKnown: firstMonitor ? firstMonitor.brightnessKnown : false
            },
            media: {
                enabled: Players.enabled, status: Players.status, controls: Players.controlsEnabled,
                players: Players.playerCount
            },
            network: {
                enabled: Nmcli.enabled, status: Nmcli.status, controls: Nmcli.controlsEnabled,
                commandsSent: Nmcli.commandsSent
            },
            apps: {
                enabled: Apps.enabled, status: Apps.status, launch: Apps.launchEnabled, count: Apps.count
            },
            hypr: {
                enabled: Hypr.enabled, status: Hypr.status, dispatch: Hypr.dispatchEnabled,
                monitors: Hypr.monitors.values.length, workspaces: Hypr.workspaces.values.length,
                activeWsId: Hypr.activeWsId, activeTitle: Hypr.activeToplevel?.title ?? ""
            },
            tiling: {
                mode: Tiling.mode, status: Tiling.status, backendEnabled: Tiling.backendEnabled,
                managed: Tiling.managedCount, failed: Tiling.failedCount,
                included: Tiling.includedPatterns.length, excluded: Tiling.excludedPatterns.length
            },
            tray: {
                enabled: WindowsTray.enabled, status: WindowsTray.status, activation: WindowsTray.activationEnabled,
                hook: Quickshell.env("QS_WINDOWS_TRAY_HOOK") ?? ""
            },
            notifications: {
                enabled: Notifs.enabled, status: Notifs.status, mirror: Notifs.mirrorOptIn,
                popups: Notifs.popups.filter(n => !n.closed).length
            },
            session: {
                mode: root.sessionMode, enabled: SessionManager.enabled === true,
                actions: SessionManager.actionsEnabled === true
            },
            // Windows utilities: the keep-awake helper and the ffmpeg recorder
            // are only ever active behind the Live gate, and neither may hold a
            // process during smoke.
            utilities: {
                keepAwakePermitted: idleInhibitor.permitted,
                inhibitIdle: RuntimeState.inhibitIdle,
                keepAwakeHeld: idleInhibitor.inhibiting,
                recorderPermitted: Recorder.permitted,
                recorderProbed: Recorder.probed,
                recorderAvailable: Recorder.available,
                recorderRunning: Recorder.running,
                recorderStatus: Recorder.status
            }
        };
    }

    function serviceLines(states): void {
        for (const name of Object.keys(states)) {
            const state = states[name];
            const parts = Object.keys(state).map(key => `${key}=${state[key]}`).join(" ");
            console.log(`CAELESTIA_COMBINED_SERVICE name=${name} ${parts}`);
        }
    }

    function sessionActionState(action): var {
        const state = SessionManager.sessionAction
            ? SessionManager.sessionAction(action) : null;
        return state ? {
            supported: state.supported === true,
            capability: state.capability === true,
            available: state.available === true,
            requiresConfirmation: state.requiresConfirmation === true
        } : null;
    }

    function sessionButtons(): var {
        const panels = ShellState.componentsFor(win.screen)?.panels;
        const content = panels?.session.children.find(c => c.item)?.item;
        if (!content)
            return [];
        return content.children.filter(c => c.icon).map(c => ({
            icon: c.icon, disabled: c.disabled === true
        }));
    }

    function sessionState(): var {
        const actions = {};
        for (const action of ["lock", "logout", "shutdown", "reboot", "suspend", "hibernate", "firmware"])
            actions[action] = root.sessionActionState(action);

        const result = SessionManager.lastResult ?? {};
        return {
            mode: root.sessionMode,
            enabled: SessionManager.enabled === true,
            actionsEnabled: SessionManager.actionsEnabled === true,
            available: SessionManager.available === true,
            backendLoaded: SessionManager.backend !== null && SessionManager.backend !== undefined,
            actions: actions,
            lastOutcome: result.outcome ?? "", lastAction: result.action ?? "",
            lastConsumed: result.consumed === true,
            lastDispatched: result.dispatched === true,
            lastRequested: result.requested === true,
            lastSucceeded: result.succeeded === true
        };
    }

    // The smoke boundary. Observation is the only enabled capability: every
    // service's control flag must be off, every probed write must be refused
    // by its facade, the tray hook must stay off and an unknown session
    // command must be consumed without a native call.
    function checkBoundary(states): bool {
        const controls = [
            states.audio.controls, states.battery.profileWrites, states.bluetooth.controls,
            states.brightness.controls, states.media.controls, states.network.controls,
            states.apps.launch, states.tray.activation, states.notifications.mirror
        ];
        if (controls.some(control => control === true))
            return false;
        if (states.hypr.dispatch !== false)
            return false;
        // Smoke never enables the tiler: at most the observe construction.
        if (states.tiling.backendEnabled !== false || states.tiling.status === "tiling")
            return false;
        if (states.tray.hook !== "0")
            return false;
        if (states.network.commandsSent !== 0)
            return false;
        if (SessionManager.exec(["caelestia-combined-unavailable-probe"]) !== true)
            return false;
        if (Audio.setMuted(true) !== false)
            return false;
        if (WindowsBluetooth.setRadioEnabled(true) !== false)
            return false;
        if (WindowsTray.activate(null) !== false)
            return false;
        if (Players.canControl(Players.active) !== false)
            return false;
        const firstMonitor = Brightness.monitors.length > 0 ? Brightness.monitors[0] : null;
        if (firstMonitor && Brightness.write(firstMonitor.screenName, 0.5) !== false)
            return false;
        // No idle-inhibit helper and no recorder process may exist in smoke,
        // even when the Live flags are supplied.
        if (states.utilities.keepAwakeHeld || states.utilities.recorderRunning
                || states.utilities.recorderProbed)
            return false;

        const session = root.sessionState();
        if (session.enabled !== true || session.actionsEnabled !== false
                || session.lastConsumed !== true || session.lastDispatched !== false
                || session.lastRequested !== false || session.lastSucceeded !== false)
            return false;
        for (const action of Object.keys(session.actions)) {
            const actionState = session.actions[action];
            if (!actionState || actionState.available !== false)
                return false;
        }
        return true;
    }

    // Every facade must be constructed through its observation opt-in and have
    // settled past its bounded initializing phase before any state is judged.
    function checkObservation(states): bool {
        for (const name of ["audio", "battery", "bluetooth", "brightness", "media", "network", "apps", "tray", "notifications", "hypr"])
            if (states[name].enabled !== true)
                return false;
        if (states.audio.status === "initializing" || states.audio.status === "disabled")
            return false;
        if (states.battery.status === "initializing" || states.battery.status === "disabled")
            return false;
        if (states.bluetooth.status === "initializing" || states.bluetooth.status === "disabled")
            return false;
        if (states.brightness.status === "loading" || states.brightness.status === "disabled")
            return false;
        if (states.media.status === "initializing" || states.media.status === "disabled")
            return false;
        if (states.network.status === "initializing" || states.network.status === "disabled")
            return false;
        if (states.apps.status === "scanning" || states.apps.status === "disabled")
            return false;
        if (states.tray.status === "initializing" || states.tray.status === "disabled")
            return false;
        if (states.notifications.status === "initializing" || states.notifications.status === "disabled")
            return false;
        if (states.hypr.status === "initializing" || states.hypr.status === "disabled"
                || states.hypr.status === "unavailable")
            return false;
        return true;
    }

    function fail(message: string): void {
        console.error("CAELESTIA_COMBINED_FAIL: " + message);
        Qt.exit(1);
    }

    function capturePhase(name: string): void {
        const path = Quickshell.env("CAELESTIA_SHELL_SCREENSHOT");
        const phasePath = path.replace(/\.png$/, "-" + name + ".png");
        CUtils.saveItem(win.contentItem, Qt.resolvedUrl(phasePath), () => {
            console.log("CAELESTIA_COMBINED_CAPTURE", phasePath);
        }, () => root.fail("screenshot " + name));
    }

    FontLoader {
        id: bodyFont
        source: Quickshell.shellPath("assets/google-sans-flex/GoogleSansFlex-VariableFont_GRAD,ROND,opsz,slnt,wdth,wght.ttf")
    }
    FontLoader {
        id: iconFont
        source: Quickshell.shellPath("assets/material-symbols-rounded/MaterialSymbolsRounded.ttf")
    }
    FontLoader {
        id: clockFont
        source: Quickshell.shellPath("assets/rubik/Rubik.ttf")
    }

    // Inspect the actual Windows platform font selection, including token axes.
    Item {
        visible: false
        Repeater {
            id: fontProbes
            model: ["headline", "title", "body", "label"]
            delegate: Text {
                required property string modelData
                text: "Performance Clear 01 46"
                font: Tokens.font[modelData].medium
            }
        }
    }

    // Original daemon position. The Windows adapter replaces the Wayland
    // IdleInhibitor with a lifetime-scoped child process. It starts nothing
    // until the keep-awake toggle is on, and never during smoke.
    IdleInhibit {
        id: idleInhibitor
    }

    WindowsFocusGuard {
        id: focusGuard
        target: win.contentItem
        active: !root.smoke && ((win.screenState?.session ?? false) || (win.screenState?.launcher ?? false))
        onOutcome: status => console.log("CAELESTIA_SHELL_FOCUS", status)
        onDismissRequested: {
            win.screenState.session = false;
            win.screenState.launcher = false;
        }
    }

    ContentWindow {
        id: win

        screen: root.selectedScreen
        visible: root.selectedScreen !== null && root.shellShown
        interactionEnabled: !root.smoke
        // Full screen is the upstream layout: anchored to every edge of the
        // monitor, with only the bar, border and open panels taking input.
        anchors.right: root.fullScreen
        anchors.bottom: root.fullScreen
        implicitWidth: root.previewWidth
        implicitHeight: root.previewHeight
        margins.left: root.fullScreen ? 0 : root.inset
        margins.top: root.fullScreen ? 0 : root.inset
    }

    property bool fullScreen: false

    // Full-screen bar reservation, opt-in: one left-anchored input-transparent
    // window whose exclusiveZone the backend maps to a native AppBar, so
    // maximized and tiled windows stop at the bar's width. Active only while
    // Full screen is on; hiding or destroying the window removes the AppBar
    // and restores the work area.
    Exclusions {
        screen: root.selectedScreen
        zone: win.bar.exclusiveZone
        active: root.fullScreen && root.selectedScreen !== null
    }

    // The shell window is frameless and stays above other windows, so an
    // ordinary window carries the preview's controls: it has a taskbar entry,
    // moves, and closing it ends the preview.
    property bool shellShown: true

    LazyLoader {
        active: !root.smoke

        FloatingWindow {
            title: "Caelestia preview"
            implicitWidth: 480
            implicitHeight: controls.implicitHeight + 40
            color: Colours.palette.m3surface
            onClosed: Qt.quit()

            Column {
                id: controls

                x: 20
                y: 20
                width: parent.width - 40
                spacing: 16

                StyledText {
                    text: "Caelestia preview"
                    font: Tokens.font.title.medium
                    color: Colours.palette.m3onSurface
                }

                StyledText {
                    width: parent.width
                    wrapMode: Text.WordWrap
                    text: root.live ? "Live controls" : "Read-only"
                    color: Colours.palette.m3onSurfaceVariant
                }

                Column {
                    spacing: 8

                    Repeater {
                        model: [
                            { icon: "ads_click", text: "Bar icons open their details" },
                            { icon: "south", text: "Bottom edge opens the launcher" },
                            { icon: "north", text: "Top edge opens the dashboard" }
                        ]

                        Row {
                            required property var modelData

                            spacing: 10

                            MaterialIcon {
                                text: parent.modelData.icon
                                color: Colours.palette.m3primary
                            }

                            StyledText {
                                text: parent.modelData.text
                                color: Colours.palette.m3onSurface
                            }
                        }
                    }
                }

                Row {
                    spacing: 8
                    PreviewButton { text: "Dashboard"; onActivated: win.screenState.dashboard = !win.screenState.dashboard }
                    PreviewButton { text: "Utilities"; onActivated: win.screenState.utilities = !win.screenState.utilities }
                    PreviewButton { text: "History"; onActivated: win.screenState.sidebar = !win.screenState.sidebar }
                }

                PreviewButton {
                    visible: root.live
                    text: "Choose wallpaper"
                    onActivated: Wallpapers.choose()
                }

                Column {
                    visible: SessionManager.confirmationPending
                    spacing: 8
                    StyledText { text: "Confirm Windows " + SessionManager.pendingAction + "?" }
                    Row {
                        spacing: 8
                        PreviewButton { text: "Confirm"; primary: true; onActivated: SessionManager.confirm() }
                        PreviewButton { text: "Cancel"; onActivated: SessionManager.cancelConfirmation() }
                    }
                }

                Row {
                    spacing: 8
                    visible: Quickshell.screens.length > 1

                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        text: "Show on"
                        color: Colours.palette.m3onSurfaceVariant
                    }

                    Repeater {
                        model: Quickshell.screens.length

                        PreviewButton {
                            required property int index

                            text: `Screen ${index + 1}`
                            selected: root.screenIndex === index
                            onActivated: root.screenIndex = index
                        }
                    }
                }

                Row {
                    spacing: 8

                    PreviewButton {
                        text: "Full screen"
                        selected: root.fullScreen
                        onActivated: root.fullScreen = !root.fullScreen
                    }

                    PreviewButton {
                        text: root.shellShown ? "Hide shell" : "Show shell"
                        onActivated: root.shellShown = !root.shellShown
                    }

                    PreviewButton {
                        text: "Close preview"
                        primary: true
                        onActivated: Qt.quit()
                    }
                }
            }
        }
    }

    component PreviewButton: StyledRect {
        id: button

        property alias text: label.text
        property bool primary
        property bool selected

        signal activated

        implicitWidth: label.implicitWidth + 28
        implicitHeight: label.implicitHeight + 16
        radius: Tokens.rounding.full
        color: primary ? Colours.palette.m3primary
            : selected ? Colours.palette.m3secondaryContainer
            : Colours.palette.m3surfaceContainerHigh

        StateLayer {
            color: button.primary ? Colours.palette.m3onPrimary : Colours.palette.m3onSurface
            onClicked: button.activated()
        }

        StyledText {
            id: label

            anchors.centerIn: parent
            color: button.primary ? Colours.palette.m3onPrimary
                : button.selected ? Colours.palette.m3onSecondaryContainer
                : Colours.palette.m3onSurface
        }
    }

    IpcHandler {
        target: "prototype"

        function state(): string {
            const panels = ShellState.componentsFor(win.screen)?.panels;
            return JSON.stringify({
                screen: win.screen?.name, x: win.screen?.x, y: win.screen?.y,
                dpr: win.devicePixelRatio, width: win.width, height: win.height,
                barWidth: win.bar.implicitWidth, barHovered: win.bar.isHovered,
                session: win.screenState?.session, sessionVisible: panels?.session.visible,
                launcher: win.screenState?.launcher, dashboard: win.screenState?.dashboard,
                osd: win.screenState?.osd,
                popout: panels?.popouts.currentName ?? "",
                popoutOpen: panels?.popouts.hasCurrent ?? false,
                services: root.serviceStates(), focusStatus: focusGuard.status,
                tiling: { mode: Tiling.mode, status: Tiling.status },
                toastsLoaded: panels?.toasts !== null && panels?.toasts !== undefined,
                fullScreen: root.fullScreen, barZone: win.bar.exclusiveZone
            });
        }
        function capture(): void {
            CUtils.saveItem(win.contentItem, Qt.resolvedUrl(Quickshell.env("CAELESTIA_SHELL_SCREENSHOT")));
        }
        function quit(): void { Qt.quit(); }
        function moveToScreen(index: int): bool {
            if (index < 0 || index >= Quickshell.screens.length)
                return false;
            root.screenIndex = index;
            return true;
        }
        // Harness handle for the full-screen toggle behind the same opt-in
        // as the control-window button, so a smoke run can prove the AppBar
        // reservation appears and disappears with it.
        function setFullScreen(on: bool): bool {
            root.fullScreen = on;
            return root.fullScreen === on;
        }
        // Local delivery through the reviewed facade, for trying the original
        // notification popup. It never touches the Windows Action Center.
        function notify(summary: string, body: string): string {
            const id = Notifs.enabled
                ? Notifs.postLocalTest(summary, body, ["-a", "Caelestia Windows", "-t", "6000"]) : 0;
            return JSON.stringify({ id: id });
        }
    }

    Component.onCompleted: {
        Hypr.logStartupStatus();
        Tiling.logStartupStatus();
        Native.SystemMonitor.active = true;
        Native.SystemStats.networkEnabled = true;
        if (!selectedScreen) {
            console.error("CAELESTIA_COMBINED_FAIL: requested screen does not exist", screenIndex);
            // Quickshell attaches the engine exit handler after creation.
            Qt.callLater(() => Qt.exit(1));
        }
    }

    Binding {
        target: Notifs
        property: "centerVisible"
        value: win.screenState?.sidebar ?? false
    }

    Component {
        id: smokeNotificationFactory
        SmokeNotification {}
    }

    Timer {
        id: check
        property int step
        property var popoutQueue: []
        property string popoutName: ""
        property bool popoutsStarted: false
        property var notification: null

        running: root.smoke && !root.backgroundSmoke && root.selectedScreen !== null
        repeat: true
        interval: 1200
        onTriggered: {
            const panels = ShellState.componentsFor(win.screen)?.panels;
            if (!panels || !win.screenState) {
                root.fail("missing original component graph");
                return;
            }

            // Wait for every enabled facade to settle past its bounded
            // initialization phase before judging any state.
            if (!root.checkObservation(root.serviceStates()))
                return;

            if (step === 0) {
                const requested = Quickshell.env("CAELESTIA_SHELL_SCALE");
                if ((requested !== "native" && Math.abs(win.devicePixelRatio - Number(requested)) > 0.01)
                        || win.width !== root.previewWidth || win.height !== root.previewHeight
                        || bodyFont.status !== FontLoader.Ready
                        || iconFont.status !== FontLoader.Ready
                        || clockFont.status !== FontLoader.Ready) {
                    root.fail("geometry, fonts or DPI");
                    return;
                }
                console.log("CAELESTIA_COMBINED_SCREEN", JSON.stringify({
                    index: root.screenIndex, name: win.screen.name,
                    x: win.screen.x, y: win.screen.y, dpr: win.devicePixelRatio
                }));
                for (let i = 0; i < fontProbes.count; ++i) {
                    const probe = fontProbes.itemAt(i);
                    console.log("CAELESTIA_COMBINED_FONT", probe.modelData, probe.fontInfo.family);
                    if (probe.fontInfo.family !== "Google Sans Flex") {
                        root.fail("unresolved " + probe.modelData + " font");
                        return;
                    }
                }
                console.log("CAELESTIA_COMBINED_GEOMETRY", win.screen.name,
                    win.screen.x, win.screen.y, win.width, win.height,
                    win.devicePixelRatio, win.contentItem.GraphicsInfo.api);
                const states = root.serviceStates();
                if (!root.checkBoundary(states)) {
                    root.fail("read-only service boundary");
                    return;
                }
                root.serviceLines(states);
                win.bar.isHovered = true;
                win.screenState.session = true;
            } else if (step === 1) {
                const entries = ["taskbarLogo", "taskbarWorkspaces", "taskbarActiveWindow", "taskbarClock", "taskbarTray", "taskbarStatusIcons", "taskbarPowerButton"]
                    .map(name => CUtils.findChild(win.contentItem, name));
                if (entries.some(entry => !entry) || win.bar.implicitWidth < win.bar.contentWidth - 1
                        || panels.session.offsetScale > 0.01
                        || panels.session.width <= 0 || panels.session.height <= 0) {
                    root.fail("original bar entries or session drawer did not open");
                    return;
                }
                const workspaces = CUtils.findChild(win.contentItem, "taskbarWorkspaces");
                const activeWindow = CUtils.findChild(win.contentItem, "taskbarActiveWindow");
                if (workspaces.implicitWidth <= 0 || workspaces.implicitHeight <= 0
                        || activeWindow.implicitWidth <= 0 || activeWindow.implicitHeight <= 0) {
                    root.fail("workspaces or active window entry did not lay out");
                    return;
                }
                const liveStates = root.serviceStates();
                if (liveStates.hypr.monitors < 1 || liveStates.hypr.activeWsId < 1) {
                    root.fail("Hypr observation did not settle behind the bar entries");
                    return;
                }
                const statusIcons = CUtils.findChild(win.contentItem, "taskbarStatusIcons");
                if (!statusIcons || statusIcons.implicitWidth <= 0 || statusIcons.implicitHeight <= 0) {
                    root.fail("status icons container did not lay out");
                    return;
                }
                const sessionButtons = root.sessionButtons();
                if (sessionButtons.length !== 4 || sessionButtons.some(button => !button.disabled)) {
                    root.fail("session actions are not disabled in smoke");
                    return;
                }
                console.log("CAELESTIA_COMBINED_SESSION_BUTTONS", JSON.stringify(sessionButtons));
                if (!panels.toasts) {
                    root.fail("original toast surface did not load");
                    return;
                }
                root.capturePhase("session");
                win.screenState.session = false;
            } else if (step === 2) {
                if (panels.session.visible || panels.session.offsetScale < 0.99) {
                    root.fail("original session close animation");
                    return;
                }
                win.screenState.session = false;
                if (!root.popoutsStarted) {
                    // Exercise every plugged-in status icon popout through the
                    // original popout content loader.
                    check.popoutQueue = ["audio", "network", "bluetooth", "battery"];
                    check.popoutsStarted = true;
                }
            } else if (step === 3) {
                if (check.popoutQueue.length === 0) {
                    panels.popouts.hasCurrent = false;
                    win.screenState.osd = true;
                    step = 6;
                    return;
                }
                check.popoutName = check.popoutQueue.shift();
                panels.popouts.currentName = check.popoutName;
                panels.popouts.currentCenter = win.height / 2;
                panels.popouts.hasCurrent = true;
            } else if (step === 4) {
                const popout = panels.popouts.current;
                if (!popout || popout.implicitWidth <= 0 || popout.implicitHeight <= 0) {
                    root.fail("popout did not load: " + check.popoutName);
                    return;
                }
                console.log("CAELESTIA_COMBINED_POPOUT", check.popoutName,
                    popout.implicitWidth, popout.implicitHeight);
                root.capturePhase("popout-" + check.popoutName);
                panels.popouts.hasCurrent = false;
            } else if (step === 5) {
                if (panels.popouts.hasCurrent) {
                    root.fail("popout did not close: " + check.popoutName);
                    return;
                }
                step = 2;
            } else if (step === 6) {
                if (panels.osd.offsetScale >= 1 || panels.osd.implicitHeight <= 0) {
                    root.fail("OSD did not open");
                    return;
                }
                root.capturePhase("osd");
                win.screenState.osd = false;
                win.screenState.launcher = true;
            } else if (step === 7) {
                if (!panels.launcher.visible || panels.launcher.offsetScale >= 1) {
                    root.fail("launcher did not open");
                    return;
                }
                const liveStates = root.serviceStates();
                const list = CUtils.findChild(win.contentItem, "combinedLauncherAppList");
                if (!list || list.count !== liveStates.apps.count) {
                    root.fail("launcher app list did not stage the catalog");
                    return;
                }
                WindowsCalculator.evalAsync("2*(3+4)^2");
                if (WindowsCalculator.result !== "98") {
                    root.fail("calculator"); return;
                }
                root.capturePhase("launcher");
                win.screenState.launcher = false;
                win.screenState.dashboardTab = 1;
                win.screenState.dashboard = true;
            } else if (step === 8) {
                if (!panels.dashboard.visible || panels.dashboard.offsetScale >= 1) {
                    root.fail("media dashboard panel did not open");
                    return;
                }
                const details = CUtils.findChild(win.contentItem, "combinedDashboardContent");
                if (!details || details.implicitHeight <= 0) {
                    root.fail("original media details did not load");
                    return;
                }
                root.capturePhase("dashboard");
                win.screenState.dashboardTab = 0;
            } else if (step === 9) {
                root.capturePhase("dashboard-dash");
                win.screenState.dashboardTab = 2;
            } else if (step === 10) {
                root.capturePhase("dashboard-performance");
                win.screenState.dashboardTab = 3;
            } else if (step === 11) {
                root.capturePhase("dashboard-weather");
                win.screenState.dashboard = false;
                win.screenState.utilities = true;
            } else if (step === 12) {
                if (!panels.utilities.visible || panels.utilities.implicitHeight <= 0) {
                    root.fail("utilities"); return;
                }
                // The original utilities cards are enabled in the combined
                // profile. Both Windows cards must lay out, and neither may
                // have started anything.
                const keepAwakeCard = CUtils.findChild(win.contentItem, "utilitiesKeepAwake");
                const recorderCard = CUtils.findChild(win.contentItem, "utilitiesScreenRecorder");
                const togglesCard = CUtils.findChild(win.contentItem, "utilitiesQuickToggles");
                if (!keepAwakeCard || !recorderCard || !togglesCard
                        || keepAwakeCard.implicitHeight <= 0 || recorderCard.implicitHeight <= 0) {
                    root.fail("utilities cards did not load");
                    return;
                }
                if (RuntimeState.inhibitIdle || Recorder.running || idleInhibitor.inhibiting) {
                    root.fail("utilities controls acted during smoke");
                    return;
                }
                console.log("CAELESTIA_COMBINED_UTILITIES", JSON.stringify({
                    height: panels.utilities.implicitHeight,
                    keepAwake: keepAwakeCard.implicitHeight,
                    recorder: recorderCard.implicitHeight,
                    toggles: togglesCard.implicitHeight
                }));
                root.capturePhase("utilities");
                win.screenState.utilities = false;
                Toaster.toast("Caelestia", "Original shell toast", "check");
                check.notification = smokeNotificationFactory.createObject(root);
                if (!check.notification || !Notifs.service.handleNotification(check.notification)) {
                    root.fail("notification fixture"); return;
                }
            } else if (step === 13) {
                if (!Notifs.popups.some(record => record.notification === check.notification)) {
                    root.fail("notification popup did not render"); return;
                }
                root.capturePhase("notification");
                win.screenState.sidebar = true;
            } else if (step === 14) {
                if (!panels.sidebar.visible || panels.sidebar.implicitWidth <= 0) {
                    root.fail("sidebar"); return;
                }
                root.capturePhase("sidebar");
            } else if (step === 15) {
                if (!Notifs.list.some(record => record.notification === check.notification)) {
                    root.fail("notification history did not retain the fixture");
                    return;
                }
                root.capturePhase("notification");
                root.serviceLines(root.serviceStates());
                const path = Quickshell.env("CAELESTIA_SHELL_SCREENSHOT");
                CUtils.saveItem(win.contentItem, Qt.resolvedUrl(path), () => {
                    console.log("CAELESTIA_COMBINED_CAPTURE", path);
                    console.log("CAELESTIA_COMBINED_PASS", CUtils.qtVersion);
                    Qt.quit();
                }, () => root.fail("screenshot final"));
            }
            step++;
        }
    }

    Timer {
        running: root.smoke
        interval: 55000
        onTriggered: {
            console.error("CAELESTIA_COMBINED_FAIL: timeout");
            Qt.exit(1);
        }
    }
}
