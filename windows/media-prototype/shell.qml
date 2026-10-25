//@ pragma AppId org.caelestia.windows-media-prototype
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
import qs.modules.dashboard.media as PlayerUI

// A separate bounded M2 host for the original dashboard player details. Other
// services, global shortcuts, IPC mutations, lyrics, artwork capture and all
// shell controllers stay unloaded.
ShellRoot {
    id: root

    readonly property bool smoke: Quickshell.env("CAELESTIA_SHELL_SMOKE") === "1"
    readonly property int screenIndex: Number(Quickshell.env("CAELESTIA_SHELL_SCREEN") || "0")
    readonly property ShellScreen selectedScreen: Quickshell.screens[screenIndex] ?? null
    readonly property int previewWidth: Math.min(560, (selectedScreen?.width ?? 800) - 160)
    readonly property int previewHeight: Math.min(460, (selectedScreen?.height ?? 780) - 160)
    property var initialMediaState: null
    property bool failed: false

    settings.watchFiles: false

    function mediaState(): var {
        const active = Players.active;
        return {
            status: Players.status, reason: Players.reason, enabled: Players.enabled,
            controlsEnabled: Players.controlsEnabled,
            backendLoaded: Players.backend !== null,
            nativeRequested: Players.nativeRequested,
            nativeReady: Players.nativeReady, backendReady: Players.backendReady,
            ready: Players.ready, noSessions: Players.noSessions,
            sessionsObserved: Players.sessionsObserved, lastError: Players.lastError,
            playerCount: Players.playerCount,
            players: Players.list.map(player => Players.getIdentity(player)),
            activeIdentity: active ? Players.getIdentity(active) : "",
            activeTitle: active?.trackTitle ?? "", activeArtist: active?.trackArtist ?? "",
            activeAlbum: active?.trackAlbum ?? "",
            activeArtUrl: Players.getArtUrl(active),
            activeIsPlaying: active?.isPlaying ?? false,
            position: active?.position ?? 0, length: active?.length ?? 0,
            positionSupported: active?.positionSupported ?? false,
            lengthSupported: active?.lengthSupported ?? false,
            canControl: Players.canControl(active), canPlay: Players.canPlay(active),
            canPause: Players.canPause(active),
            canTogglePlaying: Players.canTogglePlaying(active),
            canSeek: Players.canSeek(active), canGoNext: Players.canGoNext(active),
            canGoPrevious: Players.canGoPrevious(active),
            canSetShuffle: Players.canSetShuffle(active),
            canSetLoop: Players.canSetLoop(active),
            stopSupported: Players.stopSupported, raiseSupported: Players.raiseSupported,
            quitSupported: Players.quitSupported,
            openUriSupported: Players.openUriSupported,
            volumeSupported: Players.volumeSupported,
            canStop: Players.canStop(active), canRaise: Players.canRaise(active),
            canQuit: Players.canQuit(active), canOpenUri: Players.canOpenUri(active),
            canSetVolume: Players.canSetVolume(active),
            playerLoaded: playerHost.item !== null,
            playerControlsEnabled: playerHost.item?.controlsEnabled ?? false
        };
    }

    function fail(message: string): void {
        root.failed = true;
        console.error("CAELESTIA_MEDIA_FAIL: " + message);
        Qt.exit(1);
    }

    function checkInitialState(state): void {
        const requested = Quickshell.env("CAELESTIA_SHELL_SCALE");
        if ((requested !== "native" && Math.abs(win.devicePixelRatio - Number(requested)) > 0.01)
                || win.width !== root.previewWidth || win.height !== root.previewHeight
                || bodyFont.status !== FontLoader.Ready || iconFont.status !== FontLoader.Ready
                || state.enabled !== (Quickshell.env("CAELESTIA_WINDOWS_MEDIA") === "1")
                || state.controlsEnabled !== (state.enabled
                    && Quickshell.env("CAELESTIA_WINDOWS_MEDIA_CONTROLS") === "1")) {
            root.fail("UI, fonts, DPI or service opt-in policy");
            return;
        }
        if (state.enabled) {
            if (!state.nativeRequested) {
                root.fail("enabled mode did not activate the native backend loader");
                return;
            }
            if (!state.playerLoaded || playerHost.item === null) {
                root.fail("original player component did not load");
                return;
            }
            if (state.playerControlsEnabled !== (state.controlsEnabled && state.ready)) {
                root.fail("original component control hook is not guarded by the service");
                return;
            }
        } else {
            // Disabled construction: no native loader, facade, or component.
            if (state.status !== "disabled" || state.nativeRequested
                    || state.backendLoaded || state.playerLoaded
                    || playerHost.item !== null) {
                root.fail("disabled mode constructed the backend or original component");
                return;
            }
        }
        root.initialMediaState = state;
        console.log("CAELESTIA_MEDIA_SCREEN", JSON.stringify({
            index: root.screenIndex, name: win.screen.name,
            x: win.screen.x, y: win.screen.y, dpr: win.devicePixelRatio,
            width: win.width, height: win.height
        }));
        console.log("CAELESTIA_MEDIA_INITIAL", JSON.stringify(state));
    }

    function checkSettledState(state): void {
        if (!state.enabled) {
            if (state.status !== "disabled") {
                root.fail("disabled service did not settle: " + state.status);
                return;
            }
            return;
        }
        if (["no-sessions", "observed", "unavailable"].indexOf(state.status) < 0) {
            root.fail("enabled service did not settle: " + state.status);
            return;
        }
        // Smoke is always read-only: the launcher must never pass the control
        // opt-in, and no request may be advertised as available.
        if (state.controlsEnabled) {
            root.fail("smoke run enabled playback controls");
            return;
        }
        if (state.playerLoaded !== true || state.playerControlsEnabled !== false) {
            root.fail("original component is not loaded with controls disabled");
            return;
        }
        const healthy = state.status === "no-sessions" || state.status === "observed";
        if (state.ready !== healthy || state.nativeReady !== healthy
                || state.backendReady !== healthy) {
            root.fail("backend readiness and settled status disagree");
            return;
        }
        if (healthy) {
            if (state.lastError !== "") {
                root.fail("healthy scan retained an error");
                return;
            }
            if (state.status === "no-sessions") {
                if (!state.noSessions || state.sessionsObserved || state.playerCount !== 0
                        || state.activeIdentity !== "" || state.players.length !== 0) {
                    root.fail("healthy empty scan invented sessions");
                    return;
                }
            } else if (!state.sessionsObserved || state.noSessions
                    || state.playerCount !== state.players.length || state.playerCount <= 0
                    || state.activeIdentity === ""
                    || state.players.indexOf(state.activeIdentity) < 0) {
                root.fail("observed sessions are inconsistent");
                return;
            }
        } else {
            if (state.lastError === "") {
                root.fail("unavailable backend did not expose an operation/HRESULT");
                return;
            }
            // Native snapshots may survive a failed scan; they must be hidden
            // and must not be selectable or controllable.
            if (state.playerCount !== 0 || state.players.length !== 0
                    || state.activeIdentity !== "" || state.noSessions
                    || state.sessionsObserved) {
                root.fail("unavailable backend exposed stale sessions");
                return;
            }
        }
        for (const gate of ["canControl", "canPlay", "canPause", "canTogglePlaying",
            "canSeek", "canGoNext", "canGoPrevious", "canSetShuffle", "canSetLoop",
            "canStop", "canRaise", "canQuit", "canOpenUri", "canSetVolume"]) {
            if (state[gate] !== false) {
                root.fail("read-only capability gate is true: " + gate);
                return;
            }
        }
        if (state.stopSupported || state.raiseSupported || state.quitSupported
                || state.openUriSupported || state.volumeSupported) {
            root.fail("unsupported action is advertised as supported");
            return;
        }
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

        name: "media-prototype"
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
                    text: "Caelestia Windows media"
                    font: Tokens.font.body.large
                    Layout.fillWidth: true
                }
                StyledText {
                    text: Players.status
                    font: Tokens.font.label.medium
                    color: Colours.palette.m3onSurfaceVariant
                }
            }

            StyledText {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: Players.reason
                color: Colours.palette.m3onSurfaceVariant
                font: Tokens.font.body.small
            }

            StyledRect {
                Layout.fillWidth: true
                implicitHeight: 1
                color: Colours.palette.m3outlineVariant
            }

            Flickable {
                id: viewport
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                contentWidth: width
                contentHeight: playerHost.item ? Math.max(playerHost.item.implicitHeight, 1) : 0
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar {}

                // The original dashboard player details component. It is
                // instantiated only with the observation opt-in; the control
                // hook stays false unless a non-smoke run also opted into
                // playback requests. Native capability flags still gate each
                // action inside the component.
                Loader {
                    id: playerHost
                    active: Players.enabled
                    width: viewport.width
                    height: item ? Math.max(item.implicitHeight, 0) : 0
                    sourceComponent: PlayerUI.Details {
                        objectName: "windowsMediaDetails"
                        width: parent ? parent.width : 0
                        controlsEnabled: Players.controlsEnabled && Players.ready
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
            return JSON.stringify(root.mediaState());
        }
        function quit(): void { Qt.quit(); }
    }

    Component.onCompleted: {
        if (!selectedScreen)
            Qt.callLater(() => Qt.exit(1));
    }

    Timer {
        id: check
        property int step
        running: root.smoke && root.selectedScreen !== null
        repeat: true
        interval: 1000
        onTriggered: {
            if (root.failed)
                return;
            // Wait for the native worker's first scan (or its failure) before
            // judging the settled state; the timeout below bounds the wait.
            if (Players.enabled && Players.status === "loading")
                return;
            const state = root.mediaState();
            if (step === 0) {
                root.checkInitialState(state);
                if (root.failed || root.initialMediaState === null)
                    return;
            } else if (step === 1) {
                root.checkSettledState(state);
                if (root.failed)
                    return;
            } else if (step === 2) {
                console.log("CAELESTIA_MEDIA_FINAL", JSON.stringify(state));
                const path = Quickshell.env("CAELESTIA_SHELL_SCREENSHOT");
                CUtils.saveItem(win.contentItem, Qt.resolvedUrl(path), () => {
                    console.log("CAELESTIA_MEDIA_CAPTURE", path);
                    console.log("CAELESTIA_MEDIA_PASS", CUtils.qtVersion);
                    Qt.quit();
                }, () => {
                    console.error("CAELESTIA_MEDIA_FAIL: screenshot");
                    Qt.exit(1);
                });
            }
            step++;
        }
    }

    Timer {
        running: root.smoke
        interval: 15000
        onTriggered: {
            console.error("CAELESTIA_MEDIA_FAIL: timeout", Players.status, Players.reason);
            Qt.exit(1);
        }
    }
}
