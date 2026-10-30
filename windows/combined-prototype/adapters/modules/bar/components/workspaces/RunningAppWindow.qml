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

    height: details.implicitHeight + Tokens.padding.medium * 2

    RowLayout {
        anchors.fill: parent
        spacing: Tokens.spacing.small

        StyledRect {
            Layout.fillWidth: true
            Layout.fillHeight: true
            radius: Tokens.rounding.medium
            color: root.keyboardSelected ? Colours.palette.m3primaryContainer : "transparent"

            Column {
                id: details
                anchors.verticalCenter: parent.verticalCenter
                x: Tokens.padding.small
                width: parent.width - x * 2
                StyledText {
                    width: parent.width
                    text: root.window?.title ?? ""
                    elide: Text.ElideRight
                }
                StyledText {
                    width: parent.width
                    text: (root.window?.desktop ? "Desktop " + root.window.desktop : "Desktop")
                        + (root.window?.minimized ? ", minimized" : "")
                    color: Colours.palette.m3onSurfaceVariant
                    font: Tokens.font.body.small
                    elide: Text.ElideRight
                }
            }
            StateLayer {
                radius: Tokens.rounding.medium
                enabled: root.actionsEnabled
                onClicked: root.activateRequested()
                activeFocusOnTab: true
                Keys.onReturnPressed: root.activateRequested()
                Keys.onSpacePressed: root.activateRequested()
                ToolTip.visible: containsMouse
                ToolTip.text: root.window?.title ?? ""
                Accessible.role: Accessible.Button
                Accessible.name: "Switch to " + (root.window?.title ?? "window")
                Accessible.onPressAction: root.activateRequested()
            }
        }

        Action {
            icon: "minimize"
            label: "Minimize"
            enabled: root.actionsEnabled && !(root.window?.minimized ?? true)
            onClicked: root.minimizeRequested()
        }
        Action {
            icon: "close"
            label: "Close"
            enabled: root.actionsEnabled
            onClicked: root.closeRequested()
        }
    }

    component Action: Item {
        required property string icon
        required property string label
        signal clicked
        implicitWidth: Tokens.font.body.small.pointSize * 2 + Tokens.padding.small
        implicitHeight: implicitWidth

        MaterialIcon {
            anchors.centerIn: parent
            text: parent.icon
            opacity: parent.enabled ? 1 : 0.5
        }
        StateLayer {
            radius: Tokens.rounding.full
            enabled: parent.enabled
            onClicked: parent.clicked()
            activeFocusOnTab: true
            Keys.onReturnPressed: parent.clicked()
            Keys.onSpacePressed: parent.clicked()
            ToolTip.visible: containsMouse
            ToolTip.text: parent.label
            Accessible.role: Accessible.Button
            Accessible.name: parent.label
            Accessible.onPressAction: parent.clicked()
        }
    }
}
