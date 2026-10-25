pragma Singleton

import QtQuick

// Fixed opaque values from the upstream Colours.M3Palette defaults.
// Wallpaper analysis, theme files, and compositor rules are unavailable in M1.
QtObject {
    readonly property bool available: false
    readonly property bool light: false

    // Upstream Colours.layer() with the fixed opaque M1 palette: transparency
    // is off, so every layer returns the input colour unchanged. Original
    // controls such as FilledSlider call this helper.
    function layer(c: color, level: var): color {
        return c;
    }

    readonly property QtObject tPalette: palette
    readonly property QtObject palette: QtObject {
        readonly property color m3background: "#191114"
        readonly property color m3surface: "#191114"
        readonly property color m3surfaceContainer: "#261d20"
        readonly property color m3onSurface: "#efdfe2"
        readonly property color m3onSurfaceVariant: "#d5c2c6"
        readonly property color m3inverseSurface: "#efdfe2"
        readonly property color m3inverseOnSurface: "#372e30"
        readonly property color m3outline: "#9e8c91"
        readonly property color m3outlineVariant: "#514347"
        readonly property color m3shadow: "#000000"
        readonly property color m3scrim: "#000000"
        readonly property color m3primary: "#ffb0ca"
        readonly property color m3onPrimary: "#541d34"
        readonly property color m3primaryContainer: "#6f334a"
        readonly property color m3onPrimaryContainer: "#ffd9e3"
        readonly property color m3secondary: "#e2bdc7"
        readonly property color m3onSecondary: "#422932"
        readonly property color m3secondaryContainer: "#5a3f48"
        readonly property color m3onSecondaryContainer: "#ffd9e3"
        readonly property color m3tertiary: "#f0bc95"
        readonly property color m3error: "#ffb4ab"
    }
}
