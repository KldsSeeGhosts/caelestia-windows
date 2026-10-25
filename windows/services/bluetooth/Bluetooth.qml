pragma Singleton

import QtQuick
import Quickshell

BluetoothService {
    id: root

    // These flags belong only to the child shell process. Importing Bluetooth
    // with observation disabled never resolves/creates the native WinRT
    // backend, starts its worker, or observes an adapter or device. Controls are
    // a separate opt-in: observation without them never sends a radio,
    // discovery, pairing, connection or forget request from the staged UI.
    enabled: Quickshell.env("CAELESTIA_WINDOWS_BLUETOOTH") === "1"
    controlsEnabled: enabled && Quickshell.env("CAELESTIA_WINDOWS_BLUETOOTH_CONTROLS") === "1"
    backend: nativeLoader.item ?? null
    backendError: nativeLoader.status === Loader.Error ? "The Windows Bluetooth backend component failed to load." : ""

    // Observable construction policy: false unless the observation opt-in
    // requests the native facade. The facade itself starts the WinRT worker.
    readonly property bool nativeRequested: nativeLoader.active

    // The service is clock-injected so fixtures never wait on wall time. The
    // timer resets no native state by itself; tick() only expires bounded waits
    // and stops discovery/pairing that this process previously requested.
    readonly property Timer _clock: Timer {
        interval: 500
        repeat: true
        running: root.enabled
        triggeredOnStart: true

        onTriggered: root.tick(Date.now())
    }

    readonly property Loader _nativeLoader: Loader {
        id: nativeLoader

        active: root.enabled
        source: root.enabled ? Qt.resolvedUrl("NativeBluetoothBackend.qml") : ""
    }
}
