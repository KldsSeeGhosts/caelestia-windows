import QtQuick
import Caelestia.Config

// Upstream Colours transparency math, independent of the scheme provider.
QtObject {
    readonly property color m3primary_paletteKeyColor: root.layer(root.palette.m3primary_paletteKeyColor)
    readonly property color m3secondary_paletteKeyColor: root.layer(root.palette.m3secondary_paletteKeyColor)
    readonly property color m3tertiary_paletteKeyColor: root.layer(root.palette.m3tertiary_paletteKeyColor)
    readonly property color m3neutral_paletteKeyColor: root.layer(root.palette.m3neutral_paletteKeyColor)
    readonly property color m3neutral_variant_paletteKeyColor: root.layer(root.palette.m3neutral_variant_paletteKeyColor)
    readonly property color m3background: root.layer(root.palette.m3background, 0)
    readonly property color m3onBackground: root.layer(root.palette.m3onBackground)
    readonly property color m3surface: root.layer(root.palette.m3surface, 0)
    readonly property color m3surfaceDim: root.layer(root.palette.m3surfaceDim, 0)
    readonly property color m3surfaceBright: root.layer(root.palette.m3surfaceBright, 0)
    readonly property color m3surfaceContainerLowest: root.layer(root.palette.m3surfaceContainerLowest)
    readonly property color m3surfaceContainerLow: root.layer(root.palette.m3surfaceContainerLow)
    readonly property color m3surfaceContainer: root.layer(root.palette.m3surfaceContainer)
    readonly property color m3surfaceContainerHigh: root.layer(root.palette.m3surfaceContainerHigh)
    readonly property color m3surfaceContainerHighest: root.layer(root.palette.m3surfaceContainerHighest)
    readonly property color m3onSurface: root.layer(root.palette.m3onSurface)
    readonly property color m3surfaceVariant: root.layer(root.palette.m3surfaceVariant, 0)
    readonly property color m3onSurfaceVariant: root.layer(root.palette.m3onSurfaceVariant)
    readonly property color m3inverseSurface: root.layer(root.palette.m3inverseSurface, 0)
    readonly property color m3inverseOnSurface: root.layer(root.palette.m3inverseOnSurface)
    readonly property color m3outline: root.layer(root.palette.m3outline)
    readonly property color m3outlineVariant: root.layer(root.palette.m3outlineVariant)
    readonly property color m3shadow: root.layer(root.palette.m3shadow)
    readonly property color m3scrim: root.layer(root.palette.m3scrim)
    readonly property color m3surfaceTint: root.layer(root.palette.m3surfaceTint)
    readonly property color m3primary: root.layer(root.palette.m3primary)
    readonly property color m3onPrimary: root.layer(root.palette.m3onPrimary)
    readonly property color m3primaryContainer: root.layer(root.palette.m3primaryContainer)
    readonly property color m3onPrimaryContainer: root.layer(root.palette.m3onPrimaryContainer)
    readonly property color m3inversePrimary: root.layer(root.palette.m3inversePrimary)
    readonly property color m3secondary: root.layer(root.palette.m3secondary)
    readonly property color m3onSecondary: root.layer(root.palette.m3onSecondary)
    readonly property color m3secondaryContainer: root.layer(root.palette.m3secondaryContainer)
    readonly property color m3onSecondaryContainer: root.layer(root.palette.m3onSecondaryContainer)
    readonly property color m3tertiary: root.layer(root.palette.m3tertiary)
    readonly property color m3onTertiary: root.layer(root.palette.m3onTertiary)
    readonly property color m3tertiaryContainer: root.layer(root.palette.m3tertiaryContainer)
    readonly property color m3onTertiaryContainer: root.layer(root.palette.m3onTertiaryContainer)
    readonly property color m3error: root.layer(root.palette.m3error)
    readonly property color m3onError: root.layer(root.palette.m3onError)
    readonly property color m3errorContainer: root.layer(root.palette.m3errorContainer)
    readonly property color m3onErrorContainer: root.layer(root.palette.m3onErrorContainer)
    readonly property color m3success: root.layer(root.palette.m3success)
    readonly property color m3onSuccess: root.layer(root.palette.m3onSuccess)
    readonly property color m3successContainer: root.layer(root.palette.m3successContainer)
    readonly property color m3onSuccessContainer: root.layer(root.palette.m3onSuccessContainer)
    readonly property color m3primaryFixed: root.layer(root.palette.m3primaryFixed)
    readonly property color m3primaryFixedDim: root.layer(root.palette.m3primaryFixedDim)
    readonly property color m3onPrimaryFixed: root.layer(root.palette.m3onPrimaryFixed)
    readonly property color m3onPrimaryFixedVariant: root.layer(root.palette.m3onPrimaryFixedVariant)
    readonly property color m3secondaryFixed: root.layer(root.palette.m3secondaryFixed)
    readonly property color m3secondaryFixedDim: root.layer(root.palette.m3secondaryFixedDim)
    readonly property color m3onSecondaryFixed: root.layer(root.palette.m3onSecondaryFixed)
    readonly property color m3onSecondaryFixedVariant: root.layer(root.palette.m3onSecondaryFixedVariant)
    readonly property color m3tertiaryFixed: root.layer(root.palette.m3tertiaryFixed)
    readonly property color m3tertiaryFixedDim: root.layer(root.palette.m3tertiaryFixedDim)
    readonly property color m3onTertiaryFixed: root.layer(root.palette.m3onTertiaryFixed)
    readonly property color m3onTertiaryFixedVariant: root.layer(root.palette.m3onTertiaryFixedVariant)

    id: root
    required property QtObject palette
    property bool light: false
    // Fixed-palette hosts have no wallpaper analyser; black is the neutral input.
    property real wallLuminance: 0
    readonly property bool enabled: Tokens.transparency.enabled
    readonly property real base: Math.max(0, Math.min(1, Tokens.transparency.base - (light ? 0.1 : 0)))
    readonly property real layers: Math.max(0, Math.min(1, Tokens.transparency.layers))

    function layer(c: color, level: var): color {
        if (!enabled)
            return c;
        if (level === 0)
            return Qt.alpha(c, base);
        const luminance = Math.sqrt(0.299 * c.r ** 2 + 0.587 * c.g ** 2 + 0.114 * c.b ** 2);
        const depth = level ?? 1;
        const offset = (!light || depth === 1 ? 1 : -depth / 2) * (light ? 0.2 : 0.3)
            * (1 - base) * (1 + wallLuminance * (light ? (depth === 1 ? 3 : 1) : 2.5));
        const scale = luminance > 0 ? (luminance + offset) / luminance : 0;
        return Qt.rgba(Math.max(0, Math.min(1, c.r * scale)),
            Math.max(0, Math.min(1, c.g * scale)), Math.max(0, Math.min(1, c.b * scale)), layers);
    }
}
