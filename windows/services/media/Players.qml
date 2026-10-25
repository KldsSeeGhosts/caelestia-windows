pragma Singleton

import QtQuick
import Quickshell
import Caelestia.Config

PlayersService {
    id: root

    // These flags belong only to the child shell process. Importing Players
    // with media disabled never resolves/creates the native GSMTC backend or
    // starts session observation. Controls are a separate opt-in: observation
    // without them never sends a transport command from the staged UI.
    enabled: Quickshell.env("CAELESTIA_WINDOWS_MEDIA") === "1"
    controlsEnabled: enabled && Quickshell.env("CAELESTIA_WINDOWS_MEDIA_CONTROLS") === "1"
    defaultPlayer: GlobalConfig.services.defaultPlayer
    playerAliases: GlobalConfig.services.playerAliases.values
    backend: nativeLoader.item ?? null
    backendError: nativeLoader.status === Loader.Error ? "The Windows media backend component failed to load." : ""

    readonly property Loader _nativeLoader: Loader {
        id: nativeLoader

        active: root.enabled
        source: root.enabled ? Qt.resolvedUrl("NativeMediaBackend.qml") : ""
    }
}
