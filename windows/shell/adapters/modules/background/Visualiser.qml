pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Window
import Quickshell
import Caelestia.Config
import qs.services

// Connect to the original visualiser only when the Windows audio visualiser
// provider supplies the upstream cava contract. Never synthesize audio bars.
Loader {
    id: root
    required property ShellScreen screen
    required property Item wallpaper
    // #214: the visualiser blur reads the wallpaper loader, so it is window
    // owned too. Unloading it while the background tree has no window keeps
    // its effect out of a move between QQuickWindows.
    active: Config.background.visualiser.enabled && ("cava" in Audio) && Window.window !== null
    sourceComponent: VisualiserContent {
        screen: root.screen
        wallpaper: root.wallpaper
    }
}
