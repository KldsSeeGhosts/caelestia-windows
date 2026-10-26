//@ pragma AppId org.caelestia.windows-combined-prototype
//@ pragma DefaultEnv QS_NO_RELOAD_POPUP=1
//@ pragma DefaultEnv QSG_RENDER_LOOP=threaded

import QtQuick
import Quickshell
import Quickshell.Io
import Caelestia
import Caelestia.Config
import Caelestia.Services
import Caelestia.Windows
import qs.components
import qs.services
import qs.modules.drawers
import qs.modules.launcher.services

// Combined read-only prototype: the original bar with its drawers, popouts,
// OSD, notification list, apps launcher and media dashboard panel, wired to
// the reviewed Windows service facades exactly as the bounded M2 slices stage
// them. Every service observes only; every control, write, dispatch, launch,
// mirror and tiling path stays off. The window keeps the bounded M1 geometry
// and isolation: no AppBar, desktop takeover, taskbar change or autostart.
ShellRoot {
    id: root

    readonly property bool live: Quickshell.env("CAELESTIA_COMBINED_LIVE") === "1"
    readonly property bool smoke: Quickshell.env("CAELESTIA_SHELL_SMOKE") === "1"
    readonly property int initialScreenIndex: Number(Quickshell.env("CAELESTIA_SHELL_SCREEN") || "0")
    property int screenIndex: initialScreenIndex
    readonly property ShellScreen selectedScreen: Quickshell.screens[screenIndex] ?? null
    readonly property string sessionMode: Quickshell.env("CAELESTIA_SHELL_SESSION_MODE") || "Disabled"
    readonly property int inset: 80
    readonly property int previewWidth: Math.min(900, (selectedScreen?.width ?? 1060) - inset * 2)
    readonly property int previewHeight: Math.min(620, (selectedScreen?.height ?? 780) - inset * 2)

    settings.watchFiles: false

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
        for (const name of ["audio", "battery", "bluetooth", "brightness", "media", "network", "apps", "tray", "notifications"])
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

    WindowsFocusGuard {
        id: focusGuard
        target: win.contentItem
        active: !root.smoke && (win.screenState?.session ?? false)
        onOutcome: status => console.log("CAELESTIA_SHELL_FOCUS", status)
        onDismissRequested: win.screenState.session = false
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

    // The shell window is frameless and stays above other windows, so an
    // ordinary window carries the preview's controls: it has a taskbar entry,
    // moves, and closing it ends the preview.
    property bool shellShown: true

    LazyLoader {
        active: !root.smoke

        FloatingWindow {
            title: "Caelestia preview"
            implicitWidth: 360
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
                            { icon: "north", text: "Top edge opens media" }
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
                services: root.serviceStates(), focusStatus: focusGuard.status
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
        // Local delivery through the reviewed facade, for trying the original
        // notification popup. It never touches the Windows Action Center.
        function notify(summary: string, body: string): string {
            const id = Notifs.enabled
                ? Notifs.postLocalTest(summary, body, ["-a", "Caelestia Windows", "-t", "6000"]) : 0;
            return JSON.stringify({ id: id });
        }
    }

    Component.onCompleted: {
        if (!selectedScreen) {
            console.error("CAELESTIA_COMBINED_FAIL: requested screen does not exist", screenIndex);
            // Quickshell attaches the engine exit handler after creation.
            Qt.callLater(() => Qt.exit(1));
        }
    }

    Timer {
        id: check
        property int step
        property var popoutQueue: []
        property string popoutName: ""
        property bool popoutsStarted: false

        running: root.smoke && root.selectedScreen !== null
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
                const entries = ["taskbarLogo", "taskbarClock", "taskbarTray", "taskbarStatusIcons", "taskbarPowerButton"]
                    .map(name => CUtils.findChild(win.contentItem, name));
                if (entries.some(entry => !entry) || win.bar.implicitWidth < win.bar.contentWidth - 1
                        || panels.session.offsetScale > 0.01
                        || panels.session.width <= 0 || panels.session.height <= 0) {
                    root.fail("original bar entries or session drawer did not open");
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
                root.capturePhase("launcher");
                win.screenState.launcher = false;
                win.screenState.dashboard = true;
            } else if (step === 8) {
                if (!panels.dashboard.visible || panels.dashboard.offsetScale >= 1) {
                    root.fail("media dashboard panel did not open");
                    return;
                }
                const details = CUtils.findChild(win.contentItem, "combinedMediaDetails");
                if (!details || details.implicitHeight <= 0) {
                    root.fail("original media details did not load");
                    return;
                }
                root.capturePhase("dashboard");
                win.screenState.dashboard = false;
                if (Notifs.enabled && Notifs.postLocalTest(
                        "Caelestia Windows",
                        "Combined prototype local notification " + Date.now(),
                        ["-a", "Caelestia Windows", "-t", "6000"]) <= 0) {
                    root.fail("local notification delivery was refused");
                    return;
                }
            } else if (step === 9) {
                if (Notifs.enabled && Notifs.popups.filter(n => !n.closed).length < 1) {
                    root.fail("notification popup did not render");
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
        interval: 40000
        onTriggered: {
            console.error("CAELESTIA_COMBINED_FAIL: timeout");
            Qt.exit(1);
        }
    }
}
