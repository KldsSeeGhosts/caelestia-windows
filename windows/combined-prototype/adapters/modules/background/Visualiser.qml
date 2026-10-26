pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Caelestia.Config
import qs.services

// Connect to the original visualiser only when the Windows audio visualiser
// provider supplies the upstream cava contract. Never synthesize audio bars.
Loader {
    id: root
    required property ShellScreen screen
    required property Item wallpaper
    active: Config.background.visualiser.enabled && ("cava" in Audio)
    sourceComponent: VisualiserContent {
        screen: root.screen
        wallpaper: root.wallpaper
    }
}
