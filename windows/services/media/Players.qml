pragma Singleton

import QtQuick
import Quickshell
import Caelestia.Config
import qs.components.misc

PlayersService {
    id: root

    // These flags belong only to the child shell process. Importing Players
    // with media disabled never resolves/creates the native GSMTC backend or
    // starts session observation. Controls are a separate opt-in: observation
    // without them never sends a transport request from the staged UI.
    enabled: Quickshell.env("CAELESTIA_WINDOWS_MEDIA") === "1"
    controlsEnabled: enabled && Quickshell.env("CAELESTIA_WINDOWS_MEDIA_CONTROLS") === "1"
    defaultPlayer: GlobalConfig.services.defaultPlayer
    playerAliases: GlobalConfig.services.playerAliases.values
    backend: nativeLoader.item ?? null
    backendError: nativeLoader.status === Loader.Error ? "The Windows media backend component failed to load." : ""

    // Observable construction policy: false unless the observation opt-in
    // requests the native facade. The facade itself starts the GSMTC worker.
    readonly property bool nativeRequested: nativeLoader.active

    readonly property Loader _nativeLoader: Loader {
        id: nativeLoader

        active: root.enabled
        source: root.enabled ? Qt.resolvedUrl("NativeMediaBackend.qml") : ""
    }

    // The original services/Players.qml global shortcuts over the Windows
    // player facade. QtObject has no default property, so the shortcut objects
    // live in an explicit list; each still registers itself on construction.
    // Every action goes through the service's can* gates so the controls opt-in
    // and the native per-player capability flags are enforced here too.
    readonly property list<QtObject> _shortcuts: [
        CustomShortcut {
            name: "mediaToggle"
            description: "Toggle media playback"
            onPressed: {
                const active = root.active;
                if (root.canTogglePlaying(active))
                    active.togglePlaying();
            }
        },
        CustomShortcut {
            name: "mediaPrev"
            description: "Previous track"
            onPressed: {
                const active = root.active;
                if (root.canGoPrevious(active))
                    active.previous();
            }
        },
        CustomShortcut {
            name: "mediaNext"
            description: "Next track"
            onPressed: {
                const active = root.active;
                if (root.canGoNext(active))
                    active.next();
            }
        },
        CustomShortcut {
            name: "mediaStop"
            description: "Stop media playback"
            onPressed: {
                const active = root.active;
                // GSMTC has no stop; canStop() is always false at this backend,
                // so the shortcut stays registered but sends nothing.
                if (root.canStop(active))
                    active.stop();
            }
        }
    ]
}
