pragma Singleton

import QtQuick

// Fixed upstream default palette for the probe. The full Colours service also
// loads wallpaper analysis and Hyprland rules, which are not portable yet.
QtObject {
    readonly property bool light: false
    readonly property QtObject tPalette: palette
    readonly property QtObject palette: QtObject {
        readonly property color m3background: "#191114"
        readonly property color m3surfaceContainer: "#261d20"
        readonly property color m3onSurface: "#efdfe2"
        readonly property color m3onSurfaceVariant: "#d5c2c6"
        readonly property color m3outlineVariant: "#514347"
        readonly property color m3primary: "#ffb0ca"
        readonly property color m3secondary: "#e2bdc7"
        readonly property color m3tertiary: "#f0bc95"
    }
}
