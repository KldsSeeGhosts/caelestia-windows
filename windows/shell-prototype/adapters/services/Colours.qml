pragma Singleton

import QtQuick

// Fixed opaque values from the upstream Colours.M3Palette defaults.
// Wallpaper analysis, theme files, and compositor rules are unavailable in the
// bounded prototypes. The full M3Palette surface is mirrored so original
// components (launcher rows, search bar, buttons, scroll bars) resolve every
// token without a wallpaper-derived palette.
QtObject {
    readonly property bool available: false
    readonly property bool light: false
    readonly property QtObject tPalette: palette
    readonly property QtObject palette: QtObject {
        readonly property color m3primary_paletteKeyColor: "#a8627b"
        readonly property color m3secondary_paletteKeyColor: "#8e6f78"
        readonly property color m3tertiary_paletteKeyColor: "#986e4c"
        readonly property color m3neutral_paletteKeyColor: "#807477"
        readonly property color m3neutral_variant_paletteKeyColor: "#837377"
        readonly property color m3background: "#191114"
        readonly property color m3onBackground: "#efdfe2"
        readonly property color m3surface: "#191114"
        readonly property color m3surfaceDim: "#191114"
        readonly property color m3surfaceBright: "#403739"
        readonly property color m3surfaceContainerLowest: "#130c0e"
        readonly property color m3surfaceContainerLow: "#22191c"
        readonly property color m3surfaceContainer: "#261d20"
        readonly property color m3surfaceContainerHigh: "#31282a"
        readonly property color m3surfaceContainerHighest: "#3c3235"
        readonly property color m3onSurface: "#efdfe2"
        readonly property color m3surfaceVariant: "#514347"
        readonly property color m3onSurfaceVariant: "#d5c2c6"
        readonly property color m3inverseSurface: "#efdfe2"
        readonly property color m3inverseOnSurface: "#372e30"
        readonly property color m3outline: "#9e8c91"
        readonly property color m3outlineVariant: "#514347"
        readonly property color m3shadow: "#000000"
        readonly property color m3scrim: "#000000"
        readonly property color m3surfaceTint: "#ffb0ca"
        readonly property color m3primary: "#ffb0ca"
        readonly property color m3onPrimary: "#541d34"
        readonly property color m3primaryContainer: "#6f334a"
        readonly property color m3onPrimaryContainer: "#ffd9e3"
        readonly property color m3inversePrimary: "#8b4a62"
        readonly property color m3secondary: "#e2bdc7"
        readonly property color m3onSecondary: "#422932"
        readonly property color m3secondaryContainer: "#5a3f48"
        readonly property color m3onSecondaryContainer: "#ffd9e3"
        readonly property color m3tertiary: "#f0bc95"
        readonly property color m3onTertiary: "#48290c"
        readonly property color m3tertiaryContainer: "#b58763"
        readonly property color m3onTertiaryContainer: "#000000"
        readonly property color m3error: "#ffb4ab"
        readonly property color m3onError: "#690005"
        readonly property color m3errorContainer: "#93000a"
        readonly property color m3onErrorContainer: "#ffdad6"
        readonly property color m3success: "#B5CCBA"
        readonly property color m3onSuccess: "#213528"
        readonly property color m3successContainer: "#374B3E"
        readonly property color m3onSuccessContainer: "#D1E9D6"
        readonly property color m3primaryFixed: "#ffd9e3"
        readonly property color m3primaryFixedDim: "#ffb0ca"
        readonly property color m3onPrimaryFixed: "#39071f"
        readonly property color m3onPrimaryFixedVariant: "#6f334a"
        readonly property color m3secondaryFixed: "#ffd9e3"
        readonly property color m3secondaryFixedDim: "#e2bdc7"
        readonly property color m3onSecondaryFixed: "#2b151d"
        readonly property color m3onSecondaryFixedVariant: "#5a3f48"
        readonly property color m3tertiaryFixed: "#ffdcc3"
        readonly property color m3tertiaryFixedDim: "#f0bc95"
        readonly property color m3onTertiaryFixed: "#2f1500"
        readonly property color m3onTertiaryFixedVariant: "#623f21"
    }
}
