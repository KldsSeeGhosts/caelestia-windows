pragma Singleton

import QtQuick
import Quickshell
import Caelestia.Config
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

    // Original Caelestia CavaProvider/BeatTracker over WASAPI loopback. They
    // start only when an original ServiceRef references them, so the dashboard
    // media panel and background visualiser keep their upstream lifetime.
    readonly property Loader _cavaLoader: Loader {
        id: cavaLoader

        active: root.enabled
        sourceComponent: CavaProvider {
            bars: root.visualiserBars
        }
    }

    readonly property Loader _beatLoader: Loader {
        id: beatLoader

        active: root.enabled
        sourceComponent: BeatTracker {}
    }
}
