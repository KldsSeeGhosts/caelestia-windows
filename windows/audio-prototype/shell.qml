//@ pragma AppId org.caelestia.windows-audio-prototype
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
import qs.modules.bar.popouts as BarPopouts

// A separate bounded M2 host for the original audio controls. Other services,
// global shortcuts, visualizer capture and all shell controllers stay unloaded.
ShellRoot {
    id: root

    readonly property bool smoke: Quickshell.env("CAELESTIA_SHELL_SMOKE") === "1"
    readonly property int screenIndex: Number(Quickshell.env("CAELESTIA_SHELL_SCREEN") || "0")
    readonly property ShellScreen selectedScreen: Quickshell.screens[screenIndex] ?? null
    readonly property int previewWidth: Math.min(640, (selectedScreen?.width ?? 800) - 160)
    readonly property int previewHeight: Math.min(620, (selectedScreen?.height ?? 780) - 160)
    property var initialAudioState

    settings.watchFiles: false

    function audioState(): var {
        const node = n => n ? {
            id: n.id, name: n.name, description: n.description, ready: n.ready,
            controlAvailable: n.audio?.controlAvailable ?? false,
            stateAvailable: n.audio?.stateAvailable ?? false,
            controlError: n.audio?.controlError ?? "",
            volume: n.audio?.volume ?? null, muted: n.audio?.muted ?? null
        } : null;
        return {
            status: Audio.status, reason: Audio.reason, enabled: Audio.enabled,
            backendLoaded: Audio.backend !== null,
            controlsEnabled: Audio.controlsEnabled,
            outputAvailable: Audio.outputAvailable, inputAvailable: Audio.inputAvailable,
            outputControlsAvailable: Audio.outputControlsAvailable,
            inputControlsAvailable: Audio.inputControlsAvailable, lastError: Audio.lastError,
            sink: node(Audio.sink), source: node(Audio.source),
            sinks: Audio.sinks.map(node), sources: Audio.sources.map(node),
            // Do not record application stream metadata in committed evidence.
            streamCount: Audio.streams.length
        };
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

        name: "audio-prototype"
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

            StyledText {
                text: "Caelestia Windows audio"
                font: Tokens.font.body.large
            }
            StyledText {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: Audio.reason
                    + (!Audio.enabled || Audio.outputAvailable ? "" : "\n" + Audio.outputReason)
                    + (!Audio.enabled || Audio.inputAvailable ? "" : "\n" + Audio.inputReason)
                    + (Audio.controlsEnabled
                    ? "\nAudio changes require interaction with the controls below."
                    : "\nRead-only preview. Audio controls are disabled.")
                color: Colours.palette.m3onSurfaceVariant
            }

            Flickable {
                id: viewport
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                contentWidth: width
                contentHeight: audioContent.implicitHeight
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar {}

                BarPopouts.AudioPopout {
                    id: audioContent
                    objectName: "windowsAudioPopout"
                    width: viewport.width
                    popouts: BarPopouts.PopoutState {}
                    outputControlsEnabled: Audio.outputControlsAvailable
                    outputSelectionEnabled: Audio.sinks.some(node => Audio.canControl(node))
                    inputControlsEnabled: Audio.sources.some(node => Audio.canControl(node))
                    volumeAvailable: Audio.outputAvailable
                    nodeControlsAvailable: node => Audio.canControl(node)
                    settingsEnabled: false
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
            return JSON.stringify(root.audioState());
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
            if (Audio.status === "initializing")
                return;
            const state = root.audioState();
            if (step === 0) {
                const requested = Quickshell.env("CAELESTIA_SHELL_SCALE");
                if ((requested !== "native" && Math.abs(win.devicePixelRatio - Number(requested)) > 0.01)
                        || win.width !== root.previewWidth || win.height !== root.previewHeight
                        || bodyFont.status !== FontLoader.Ready || iconFont.status !== FontLoader.Ready
                        || Audio.controlsEnabled || audioContent.settingsEnabled
                        || audioContent.implicitHeight <= 0
                        || state.enabled !== (Quickshell.env("CAELESTIA_WINDOWS_AUDIO") === "1")) {
                    console.error("CAELESTIA_AUDIO_FAIL: UI, fonts, DPI or service policy");
                    Qt.exit(1);
                    return;
                }
                root.initialAudioState = state;
                console.log("CAELESTIA_AUDIO_SCREEN", JSON.stringify({
                    index: root.screenIndex, name: win.screen.name,
                    x: win.screen.x, y: win.screen.y, dpr: win.devicePixelRatio,
                    width: win.width, height: win.height
                }));
                console.log("CAELESTIA_AUDIO_INITIAL", JSON.stringify(state));
            } else if (step === 1) {
                // All public mutation routes must be inert in smoke/read-only mode.
                const requests = [
                    Audio.setVolume(0.17), Audio.setSourceVolume(0.23),
                    Audio.incrementVolume(), Audio.decrementSourceVolume(),
                    Audio.setMuted(true), Audio.setSourceMuted(true),
                    Audio.setAudioSink(Audio.sinks[0] ?? null),
                    Audio.setAudioSource(Audio.sources[0] ?? null),
                    Audio.cycleNextAudioOutput(),
                    Audio.setStreamVolume(Audio.streams[0] ?? null, 0.31),
                    Audio.setStreamMuted(Audio.streams[0] ?? null, true)
                ];
                if (requests.some(result => result !== false)) {
                    console.error("CAELESTIA_AUDIO_FAIL: read-only mutation guard");
                    Qt.exit(1);
                    return;
                }
            } else if (step === 2) {
                console.log("CAELESTIA_AUDIO_FINAL", JSON.stringify(state));
                const path = Quickshell.env("CAELESTIA_SHELL_SCREENSHOT");
                CUtils.saveItem(win.contentItem, Qt.resolvedUrl(path), () => {
                    console.log("CAELESTIA_AUDIO_CAPTURE", path);
                    console.log("CAELESTIA_AUDIO_PASS", CUtils.qtVersion);
                    Qt.quit();
                }, () => {
                    console.error("CAELESTIA_AUDIO_FAIL: screenshot");
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
            console.error("CAELESTIA_AUDIO_FAIL: timeout", Audio.status, Audio.reason);
            Qt.exit(1);
        }
    }
}
