import QtQuick
import QtQuick.Controls
import Quickshell
import Caelestia.Config
import qs.components
import qs.services as Services

// Keep upstream workspace content and motion intact. Only the Windows graph
// adds the bounded running-app pill below it and the desktop-control state
// from the Windows Hypr service.
Column {
    id: root

    required property ShellScreen screen
    required property bool fullscreen

    readonly property Item owningBar: parent?.parent ?? null
    readonly property bool controlAvailable: Services.Hypr.workspaceControlAvailable
    readonly property string controlNotice: Services.Hypr.workspaceControlNotice
    readonly property real rowSize: Tokens.sizes.bar.innerWidth - Tokens.padding.small
    readonly property real appBudget: {
        const bar = owningBar;
        if (!bar || !bar.height)
            return rowSize * 5 + Tokens.padding.small * 2;
        const entries = bar.children.filter(c => c.entryId && c.entryId !== "spacer" && c.item !== root);
        // The active title already elides to its available height. Reserve a
        // useful title area rather than depending on that reciprocal binding.
        const used = entries.reduce((sum, entry) => sum + (entry.entryId === "activeWindow"
            ? rowSize * 3 : (entry.item?.nonAnimHeight ?? entry.implicitHeight)), 0);
        const free = bar.height - used - workspaceContent.implicitHeight
            - bar.vPadding * 2 - bar.spacing * (bar.children.length - 1) - spacing;
        const rows = Math.max(1, Math.min(5,
            Math.floor((free - Tokens.padding.small * 2) / rowSize)));
        return rows * rowSize + Tokens.padding.small * 2;
    }

    spacing: runningApps.implicitHeight > 0 ? Tokens.spacing.medium : 0
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

    RunningApps {
        id: runningApps
        maximumHeight: root.appBudget
        rowSize: root.rowSize
        edgeItem: root.owningBar
        visible: !root.fullscreen
        onInteractionStarted: root.owningBar?.popouts.close()
    }
}
