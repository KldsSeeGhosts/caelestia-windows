pragma Singleton

import QtQuick
import Quickshell
import Caelestia.Config

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

    readonly property Loader _nativeLoader: Loader {
        id: nativeLoader

        active: root.enabled
        source: root.enabled ? Qt.resolvedUrl("NativeAudioBackend.qml") : ""
    }
}
