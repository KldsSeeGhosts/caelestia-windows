import QtQuick
import Quickshell
import Quickshell.Io
import Caelestia.Config
import qs.services
import qs.utils

// Export resolved shell appearance for applications which opt in to it.
QtObject {
    id: root

    property string outputPath: `${Paths.state}/theme-tokens.json`
    property string bundledFontPath: Quickshell.shellPath("assets/google-sans-flex/GoogleSansFlex-VariableFont_GRAD,ROND,opsz,slnt,wdth,wght.ttf")
    property string bundledFontFamily: "Google Sans Flex"
    property var palette: Colours.palette
    property bool light: Colours.light
    property font uiFont: Tokens.font.body.medium
    property var rounding: Tokens.rounding

    readonly property string contents: JSON.stringify({
        version: 1,
        mode: root.light ? "light" : "dark",
        colours: {
            surface: String(root.palette.m3surface),
            surfaceContainerLow: String(root.palette.m3surfaceContainerLow),
            surfaceContainer: String(root.palette.m3surfaceContainer),
            surfaceContainerHigh: String(root.palette.m3surfaceContainerHigh),
            surfaceContainerHighest: String(root.palette.m3surfaceContainerHighest),
            onSurface: String(root.palette.m3onSurface),
            onSurfaceVariant: String(root.palette.m3onSurfaceVariant),
            primary: String(root.palette.m3primary),
            onPrimary: String(root.palette.m3onPrimary),
            primaryContainer: String(root.palette.m3primaryContainer),
            secondaryContainer: String(root.palette.m3secondaryContainer),
            outline: String(root.palette.m3outline),
            error: String(root.palette.m3error)
        },
        font: {
            family: root.uiFont.family,
            file: root.uiFont.family === root.bundledFontFamily ? root.bundledFontPath : null
        },
        radii: {
            small: root.rounding.small,
            normal: root.rounding.medium,
            large: root.rounding.large,
            full: root.rounding.full
        }
    }, null, 2) + "\n"

    onContentsChanged: writeTimer.restart()
    Component.onCompleted: writeTimer.restart()

    property FileView output: FileView {
        path: root.outputPath
        atomicWrites: true
    }
    property Timer writeTimer: Timer {
        interval: 0
        onTriggered: root.output.setText(root.contents)
    }
}
