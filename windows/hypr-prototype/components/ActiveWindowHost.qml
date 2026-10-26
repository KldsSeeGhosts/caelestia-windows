import QtQuick
import Caelestia.Config
import qs.services
import qs.modules.bar.components

// Loaded only after the observation backend is ready. The original bar
// ActiveWindow component is used unmodified. It only needs a `bar` host object
// for popout placement and height math and the typed `Brightness.Monitor`
// property, which it never reads; the hypr-prototype Brightness adapter
// supplies that type because the portable build excludes the upstream service.
Item {
    id: root

    readonly property real spacing: Tokens.spacing.medium
    readonly property real vPadding: Tokens.padding.large
    readonly property QtObject popouts: QtObject {
        property bool hasCurrent: false
        property string currentName: ""
        property real currentCenter: 0
    }

    implicitWidth: activeWindow.implicitWidth
    implicitHeight: activeWindow.implicitHeight

    // Probe for the smoke harness only. The original component remains the
    // source of the title text.
    readonly property string activeWindowTitle: activeWindow.windowTitle

    ActiveWindow {
        id: activeWindow

        bar: root
        monitor: null
        colour: Colours.palette.m3primary
    }
}
