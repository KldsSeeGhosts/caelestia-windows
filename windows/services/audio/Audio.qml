pragma Singleton

import QtQuick
import Quickshell
import Caelestia.Config
import qs.components.misc
import qs.services
import Caelestia.Windows.Audio

AudioService {
    id: root

    // These flags belong only to the child shell process. Importing Audio with
    // audio disabled never resolves/creates the native backend or its tracker.
    enabled: Quickshell.env("CAELESTIA_WINDOWS_AUDIO") === "1"
    controlsEnabled: enabled && Quickshell.env("CAELESTIA_WINDOWS_AUDIO_CONTROLS") === "1"
    maxVolume: GlobalConfig.services.maxVolume
    audioIncrement: GlobalConfig.services.audioIncrement
    backend: nativeLoader.item?.backend ?? null
    backendError: nativeLoader.status === Loader.Error ? "The Windows audio backend component failed to load." : ""

    visualiserBars: GlobalConfig.services.visualiserBars
    cavaProvider: cavaLoader.item
    beatProvider: beatLoader.item

    readonly property Loader _nativeLoader: Loader {
        id: nativeLoader

        active: root.enabled
        source: root.enabled ? Qt.resolvedUrl("NativeAudioBackend.qml") : ""
    }

    // Caelestia's volume keys are Hyprland exec binds on Linux. On Windows the
    // same XF86 keys become shell GlobalShortcuts over the default output, so
    // the OSD and the audio facade observe one write path. Every action still
    // requires CAELESTIA_WINDOWS_AUDIO_CONTROLS=1.
    readonly property list<QtObject> _shortcuts: [
        CustomShortcut {
            name: "volumeUp"
            description: "Raise the output volume"
            onPressed: root.incrementVolume(root.audioIncrement)
        },
        CustomShortcut {
            name: "volumeDown"
            description: "Lower the output volume"
            onPressed: root.decrementVolume(root.audioIncrement)
        },
        CustomShortcut {
            name: "volumeMute"
            description: "Mute or unmute the output"
            onPressed: root.setMuted(!root.muted)
        }
    ]
    // Original Caelestia CavaProvider/BeatTracker over WASAPI loopback. The
    // native Service types do not expose their ref count to QML, so defer
    // construction until a component that consumes analysis is present: the
    // configured background visualiser surface, or the open dashboard (its
    // media panel and the beat-driven Dashboard card). While neither exists,
    // AudioService returns its unavailable fallbacks, so every consumer
    // binding still resolves (zero bars, zero BPM) without a provider thread.
    readonly property bool dashboardVisible: {
        if (!root.enabled)
            return false;
        for (const screen of Quickshell.screens) {
            if (!GlobalConfig.forScreen(screen.name).dashboard.enabled)
                continue;
            const state = ShellState.forScreen(screen);
            if (state && state.dashboard === true)
                return true;
        }
        return false;
    }
    readonly property bool visualiserVisible: {
        if (!root.enabled)
            return false;
        // The background window owns the only background visualiser consumer.
        for (const screen of Quickshell.screens) {
            if (!GlobalConfig.forScreen(screen.name).background.visualiser.enabled)
                continue;
            if (ShellState.componentsFor(screen)?.background)
                return true;
        }
        return false;
    }
    readonly property bool cavaRequested: root.enabled
        && (root.visualiserVisible || root.dashboardVisible)
    readonly property bool beatRequested: root.enabled && root.dashboardVisible

    readonly property Loader _cavaLoader: Loader {
        id: cavaLoader

        active: root.cavaRequested
        sourceComponent: CavaProvider {
            bars: root.visualiserBars
        }
    }

    readonly property Loader _beatLoader: Loader {
        id: beatLoader

        active: root.beatRequested
        sourceComponent: BeatTracker {}
    }
}
