import QtQuick
import Quickshell
import qs.modules.bar.components.workspaces

// Loaded by URL only when the Windows Hyprland observation backend is ready.
// Keeping this import outside shell.qml means the disabled prototype never
// loads a component that imports Quickshell.Hyprland. The original Workspaces
// component is used unmodified; only the host screen is injected.
Workspaces {
    id: root

    property ShellScreen hostScreen: null

    screen: hostScreen
    fullscreen: false
}
