pragma Singleton

import QtQuick
import Quickshell

// Windows tray facade. Both opt-ins are read from the child shell process:
//   CAELESTIA_WINDOWS_TRAY=1             observe items read-only
//   CAELESTIA_WINDOWS_TRAY_ACTIVATION=1  additionally permit activate(),
//                                        secondaryActivate() and the native
//                                        context menu opened by display()
// Importing this singleton with both unset never resolves NativeTrayBackend and
// never constructs Quickshell.Services.SystemTray. Read-only prototype launches
// force QS_WINDOWS_TRAY_HOOK=0; the production launcher enables interception.
TrayService {
    id: root

    enabled: Quickshell.env("CAELESTIA_WINDOWS_TRAY") === "1"
    activationEnabled: enabled && Quickshell.env("CAELESTIA_WINDOWS_TRAY_ACTIVATION") === "1"
    backend: nativeLoader.item ?? null
    backendError: nativeLoader.status === Loader.Error ? "The Windows tray backend component failed to load." : ""

    // Observable construction policy: false unless the observation opt-in
    // requested the native facade.
    readonly property bool nativeRequested: nativeLoader.active

    readonly property Loader _nativeLoader: Loader {
        id: nativeLoader

        active: root.enabled
        source: root.enabled ? Qt.resolvedUrl("NativeTrayBackend.qml") : ""
    }
}
