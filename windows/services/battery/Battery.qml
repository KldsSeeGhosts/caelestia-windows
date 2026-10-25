pragma Singleton

import QtQuick
import Quickshell

BatteryService {
    id: root

    // These flags belong only to the child shell process. Importing Battery
    // with power status disabled never resolves/creates the native backend.
    enabled: Quickshell.env("CAELESTIA_WINDOWS_BATTERY") === "1"
    backend: nativeLoader.item ?? null
    backendError: nativeLoader.status === Loader.Error ? "The Windows power backend component failed to load." : ""

    readonly property Loader _nativeLoader: Loader {
        id: nativeLoader

        active: root.enabled
        source: root.enabled ? Qt.resolvedUrl("NativePowerBackend.qml") : ""
    }
}
