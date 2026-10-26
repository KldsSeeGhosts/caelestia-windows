pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import qs.services
import qs.utils

// Windows adaptation of the upstream Colours singleton. It keeps the upstream
// palette contract and JSON schema but drops the Linux-only Hyprland rules and
// native ImageAnalyser. The profile-local scheme bridge writes scheme.json;
// this service watches that file and recolours the live shell.
//
// With no scheme file the palette stays at the upstream fixed defaults, so the
// shell remains usable when the generator could not be provisioned.
Singleton {
    id: root

    property string scheme: ""
    property string flavour: ""
    property bool currentLight: false
    readonly property bool light: currentLight
    readonly property real wallLuminance: 0

    // Upstream API kept for staged components. Previewing a wallpaper keeps
    // the current palette; only an applied wallpaper regenerates colours.
    property bool showPreview: false
    property bool previewLight: false
    readonly property M3Palette palette: current
    readonly property M3Palette tPalette: current
    readonly property M3Palette current: M3Palette {}
    readonly property M3Palette preview: M3Palette {}
    readonly property QtObject transparency: QtObject {
        readonly property bool enabled: false
        readonly property real base: 1
        readonly property real layers: 1
    }

    function getLuminance(c: color): real {
        if (c.r == 0 && c.g == 0 && c.b == 0)
            return 0;
        return Math.sqrt(0.299 * (c.r ** 2) + 0.587 * (c.g ** 2) + 0.114 * (c.b ** 2));
    }

    function alterColour(c: color, a: real, layer: int): color {
        const luminance = getLuminance(c);
        const offset = (!root.light || layer == 1 ? 1 : -layer / 2) * (root.light ? 0.2 : 0.3);
        const scale = luminance == 0 ? 1 : (luminance + offset) / luminance;
        return Qt.rgba(Math.max(0, Math.min(1, c.r * scale)), Math.max(0, Math.min(1, c.g * scale)), Math.max(0, Math.min(1, c.b * scale)), a);
    }

    // The prototype renders opaque surfaces, so layering is the identity. The
    // function is kept because staged upstream components call it.
    function layer(c: color, layer: var): color {
        return c;
    }

    function on(c: color): color {
        if (c.hslLightness < 0.5)
            return Qt.hsla(c.hslHue, c.hslSaturation, 0.9, 1);
        return Qt.hsla(c.hslHue, c.hslSaturation, 0.1, 1);
    }

    function load(data: string, isPreview: bool): void {
        let parsed;
        try {
            parsed = JSON.parse(data);
        } catch (error) {
            console.warn("CAELESTIA_SCHEME_INVALID " + String(error));
            return;
        }
        if (!parsed || !parsed.colours)
            return;

        const colours = isPreview ? preview : current;
        if (!isPreview) {
            root.scheme = String(parsed.name ?? "");
            root.flavour = String(parsed.flavour ?? "");
            root.currentLight = parsed.mode === "light";
        } else {
            root.previewLight = parsed.mode === "light";
        }

        let applied = 0;
        for (const [name, colour] of Object.entries(parsed.colours)) {
            const propName = name.startsWith("term") ? name : `m3${name}`;
            // QML objects expose known properties through lookup; unknown keys
            // from the scheme JSON (terminal, catppuccin aliases) are ignored.
            if (colours[propName] !== undefined) {
                colours[propName] = `#${colour}`;
                applied++;
            }
        }
        console.log(`CAELESTIA_SCHEME_LOADED name=${root.scheme || "fixed"} flavour=${root.flavour || "-"} mode=${root.currentLight ? "light" : "dark"} applied=${applied} primary=${root.palette.m3primary}`);
    }

    function setMode(mode: string): void {
        SchemeGenerator.setMode(mode, Wallpapers.actualCurrent);
    }

    // Kept for API compatibility with staged components; Hyprland is absent.
    function reloadHyprRules(): void {}
    function requestReloadHyprRules(): void {}

    FileView {
        id: schemeFile

        path: `${Paths.state}/scheme.json`
        watchChanges: true
        printErrors: false

        onLoaded: root.load(text(), false)
        onFileChanged: reload()
        onLoadFailed: root.showPreview = false
    }

    Connections {
        target: SchemeGenerator

        function onSchemeChanged(): void {
            schemeFile.reload();
        }

        // The first list call may create the default scheme file on a fresh
        // profile, so reload after it too.
        function onSchemeListChanged(): void {
            schemeFile.reload();
        }
    }

    Component.onCompleted: {
        if (SchemeGenerator.available)
            SchemeGenerator.refresh();
    }

    // Fixed defaults mirror the upstream M3Palette so every staged component
    // resolves before (or without) a generated scheme.
    component M3Palette: QtObject {
        property color m3primary_paletteKeyColor: "#a8627b"
        property color m3secondary_paletteKeyColor: "#8e6f78"
        property color m3tertiary_paletteKeyColor: "#986e4c"
        property color m3neutral_paletteKeyColor: "#807477"
        property color m3neutral_variant_paletteKeyColor: "#837377"
        property color m3background: "#191114"
        property color m3onBackground: "#efdfe2"
        property color m3surface: "#191114"
        property color m3surfaceDim: "#191114"
        property color m3surfaceBright: "#403739"
        property color m3surfaceContainerLowest: "#130c0e"
        property color m3surfaceContainerLow: "#22191c"
        property color m3surfaceContainer: "#261d20"
        property color m3surfaceContainerHigh: "#31282a"
        property color m3surfaceContainerHighest: "#3c3235"
        property color m3onSurface: "#efdfe2"
        property color m3surfaceVariant: "#514347"
        property color m3onSurfaceVariant: "#d5c2c6"
        property color m3inverseSurface: "#efdfe2"
        property color m3inverseOnSurface: "#372e30"
        property color m3outline: "#9e8c91"
        property color m3outlineVariant: "#514347"
        property color m3shadow: "#000000"
        property color m3scrim: "#000000"
        property color m3surfaceTint: "#ffb0ca"
        property color m3primary: "#ffb0ca"
        property color m3onPrimary: "#541d34"
        property color m3primaryContainer: "#6f334a"
        property color m3onPrimaryContainer: "#ffd9e3"
        property color m3inversePrimary: "#8b4a62"
        property color m3secondary: "#e2bdc7"
        property color m3onSecondary: "#422932"
        property color m3secondaryContainer: "#5a3f48"
        property color m3onSecondaryContainer: "#ffd9e3"
        property color m3tertiary: "#f0bc95"
        property color m3onTertiary: "#48290c"
        property color m3tertiaryContainer: "#b58763"
        property color m3onTertiaryContainer: "#000000"
        property color m3error: "#ffb4ab"
        property color m3onError: "#690005"
        property color m3errorContainer: "#93000a"
        property color m3onErrorContainer: "#ffdad6"
        property color m3success: "#B5CCBA"
        property color m3onSuccess: "#213528"
        property color m3successContainer: "#374B3E"
        property color m3onSuccessContainer: "#D1E9D6"
        property color m3primaryFixed: "#ffd9e3"
        property color m3primaryFixedDim: "#ffb0ca"
        property color m3onPrimaryFixed: "#39071f"
        property color m3onPrimaryFixedVariant: "#6f334a"
        property color m3secondaryFixed: "#ffd9e3"
        property color m3secondaryFixedDim: "#e2bdc7"
        property color m3onSecondaryFixed: "#2b151d"
        property color m3onSecondaryFixedVariant: "#5a3f48"
        property color m3tertiaryFixed: "#ffdcc3"
        property color m3tertiaryFixedDim: "#f0bc95"
        property color m3onTertiaryFixed: "#2f1500"
        property color m3onTertiaryFixedVariant: "#623f21"
        property color term0: "#353434"
        property color term1: "#ff4c8a"
        property color term2: "#ffbbb7"
        property color term3: "#ffdedf"
        property color term4: "#b3a2d5"
        property color term5: "#e98fb0"
        property color term6: "#ffba93"
        property color term7: "#eed1d2"
        property color term8: "#b39e9e"
        property color term9: "#ff80a3"
        property color term10: "#ffd3d0"
        property color term11: "#fff1f0"
        property color term12: "#dcbc93"
        property color term13: "#f9a8c2"
        property color term14: "#ffd1c0"
        property color term15: "#ffffff"
    }
}
