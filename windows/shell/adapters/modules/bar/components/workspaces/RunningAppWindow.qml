import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import Caelestia.Config
import qs.components
import qs.services

Item {
    id: root
    required property var window
    property bool keyboardSelected: false
    property bool actionsEnabled: true
    signal activateRequested
    signal minimizeRequested
    signal closeRequested

    // Window actions stay out of the way until the row is pointed at or
    // reached by keyboard. They remain focusable while hidden so Tab works.
    readonly property bool showActions: hover.hovered || keyboardSelected || minimizeAction.hasFocus
        || closeAction.hasFocus || activateLayer.activeFocus
    // A minimized window is just dimmed; a second line is only spent on a
    // window that lives on another desktop.
    readonly property string subtitle: {
        const desktop = window?.desktop ?? 0;
        return desktop && desktop !== (Hypr.focusedWorkspace?.id ?? desktop) ? qsTr("Desktop %1").arg(desktop) : "";
    }

    height: Math.max(details.implicitHeight, minimizeAction.implicitHeight) + Tokens.padding.extraSmall

    HoverHandler {
        id: hover
    }

    StyledRect {
        anchors.fill: parent
        radius: Tokens.rounding.medium
        // The first row is selected as the menu opens, so keep it a quiet tint.
        color: root.keyboardSelected ? Colours.layer(Colours.palette.m3surfaceContainerHigh, 2) : "transparent"
    }

    StateLayer {
        id: activateLayer
        objectName: "runningAppActivate"
        radius: Tokens.rounding.medium
        enabled: root.actionsEnabled
        onClicked: root.activateRequested()
        activeFocusOnTab: true
        Keys.onReturnPressed: root.activateRequested()
        Keys.onSpacePressed: root.activateRequested()
        ToolTip.visible: containsMouse && titleText.truncated
        ToolTip.delay: 500
        ToolTip.text: root.window?.title ?? ""
        Accessible.role: Accessible.Button
        Accessible.name: "Switch to " + (root.window?.title ?? "window")
        Accessible.onPressAction: root.activateRequested()
    }

    RowLayout {
        anchors.fill: parent
        anchors.leftMargin: Tokens.padding.small
        anchors.rightMargin: Tokens.padding.extraSmall
        spacing: Tokens.spacing.small

        ColumnLayout {
            id: details
            Layout.fillWidth: true
            Layout.alignment: Qt.AlignVCenter
            spacing: 0

            StyledText {
                id: titleText
                Layout.fillWidth: true
                text: root.window?.title ?? ""
                font: Tokens.font.body.small
                // The focused window is the only one in the accent colour.
                color: root.window?.active ? Colours.palette.m3primary : Colours.palette.m3onSurface
                elide: Text.ElideRight
                opacity: root.window?.minimized ? 0.6 : 1
            }
            StyledText {
                Layout.fillWidth: true
                visible: text.length > 0
                text: root.subtitle
                color: Colours.palette.m3onSurfaceVariant
                elide: Text.ElideRight
            }
        }

        Action {
            id: minimizeAction
            objectName: "runningAppMinimize"
            icon: "minimize"
            label: "Minimize"
            enabled: root.actionsEnabled && !(root.window?.minimized ?? true)
            onClicked: root.minimizeRequested()
        }
        Action {
            id: closeAction
            objectName: "runningAppClose"
            icon: "close"
            label: "Close"
            enabled: root.actionsEnabled
            onClicked: root.closeRequested()
        }
    }

    component Action: Item {
        id: action
        required property string icon
        required property string label
        signal clicked
        readonly property bool hasFocus: layer.activeFocus
        Layout.alignment: Qt.AlignVCenter
        implicitWidth: glyph.implicitHeight + Tokens.padding.extraSmall * 2
        implicitHeight: implicitWidth
        opacity: root.showActions ? (enabled ? 1 : 0.38) : 0

        Behavior on opacity { Anim {} }

        MaterialIcon {
            id: glyph
            anchors.centerIn: parent
            text: action.icon
            color: Colours.palette.m3onSurfaceVariant
        }
        StateLayer {
            id: layer
            objectName: action.objectName + "Button"
            radius: Tokens.rounding.full
            enabled: action.enabled
            onClicked: action.clicked()
            activeFocusOnTab: true
            Keys.onReturnPressed: action.clicked()
            Keys.onSpacePressed: action.clicked()
            ToolTip.visible: containsMouse
            ToolTip.delay: 500
            ToolTip.text: action.label
            Accessible.role: Accessible.Button
            Accessible.name: action.label
            Accessible.onPressAction: action.clicked()
        }
    }
}
