import QtQuick
import QtQuick.Controls
import Quickshell
import Caelestia.Config
import qs.components
import qs.services as Services

// Keep upstream workspace content and motion intact. Only the Windows graph
// adds the desktop-control state from the Windows Hypr service; the running
// applications are the bar's own activeWindow entry.
Column {
    id: root

    required property ShellScreen screen
    required property bool fullscreen

    readonly property bool controlAvailable: Services.Hypr.workspaceControlAvailable
    readonly property string controlNotice: Services.Hypr.workspaceControlNotice

    // Column's implicitWidth is read-only. WorkspacesContent already reserves
    // the bar's inner width, so assigning it would prevent this adapter from
    // loading.

    WorkspacesContent {
        id: workspaceContent
        screen: root.screen
        fullscreen: root.fullscreen
        // 0.5 is the opacity upstream already uses for inactive/special
        // workspace content (modules/bar/components/workspaces/Workspaces.qml:
        // opacity: root.onSpecial ? 0.5 : 1). Keeping the component's own
        // children enabled would leave its click area live, so the overlay
        // below sits above it while the capability is unavailable.
        opacity: root.controlAvailable ? 1 : 0.5

        Behavior on opacity {
            Anim {}
        }

        // Overlay on top of the original click area while the capability is
        // unavailable: it consumes clicks and wheel input and owns the hover
        // tooltip that explains the published reason. With observation off the
        // workspaces are placeholders, so the original wheel path is left alone
        // and its dispatch stays refused by the service gate.
        MouseArea {
            anchors.fill: parent
            z: 1
            visible: !root.fullscreen && !root.controlAvailable
            enabled: visible
            acceptedButtons: Qt.AllButtons
            hoverEnabled: true

            onWheel: event => event.accepted = Services.Hypr.enabled

            ToolTip.visible: containsMouse
            ToolTip.delay: 500
            ToolTip.text: root.controlNotice
        }
    }
}
