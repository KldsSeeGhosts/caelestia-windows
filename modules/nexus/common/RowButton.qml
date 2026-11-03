pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Caelestia.Config
import qs.components
import qs.services

ConnectedRect {
    id: root

    property alias icon: iconLabel.text
    property alias text: label.text
    property alias subtext: subLabel.text
    property string trailingIcon
    property alias disabled: stateLayer.disabled

    readonly property alias iconLabel: iconLabel
    readonly property alias label: label
    readonly property alias subLabel: subLabel

    signal clicked(event: MouseEvent)

    // Windows port (#210): keyboard focus and activation. Upstream rows only
    // activate through the StateLayer's MouseArea. Focus shows as the state
    // layer at M3's focus opacity under a FocusRing, and Enter/Space play the
    // press ripple. A
    // row faded out (DialogRowButton while its dialog is open) or disabled
    // leaves the tab chain.
    function activate(): void {
        if (root.disabled || root.opacity === 0)
            return;
        stateLayer.press(width / 2, height / 2);
        root.clicked(null);
    }

    activeFocusOnTab: !disabled && opacity > 0
    Keys.onPressed: event => {
        if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
            event.accepted = true;
            if (!event.isAutoRepeat)
                activate();
        }
    }
    Accessible.role: Accessible.Button
    Accessible.name: text
    Accessible.onPressAction: activate()

    Layout.fillWidth: true
    implicitHeight: row.implicitHeight + Tokens.padding.medium * 2

    StateLayer {
        id: stateLayer

        stateOpacity: root.activeFocus && !root.disabled ? 0.1 : containsMouse ? 0.08 : 0 // Windows port (#210)
        onClicked: e => root.clicked(e)
    }

    FocusRing { // Windows port (#210)
        showing: root.activeFocus && !root.disabled
        topLeftRadius: root.topLeftRadius
        topRightRadius: root.topRightRadius
        bottomLeftRadius: root.bottomLeftRadius
        bottomRightRadius: root.bottomRightRadius
    }

    RowLayout {
        id: row

        anchors.left: parent.left
        anchors.right: parent.right
        anchors.verticalCenter: parent.verticalCenter
        anchors.margins: Tokens.padding.largeIncreased

        spacing: Tokens.spacing.medium
        opacity: root.disabled ? 0.5 : 1

        Behavior on opacity {
            Anim {}
        }

        MaterialIcon {
            id: iconLabel

            color: Colours.palette.m3onSurfaceVariant
            fontStyle: Tokens.font.icon.medium
            fill: 1
        }

        Column {
            id: column

            Layout.fillWidth: true
            spacing: 0

            StyledText {
                id: label

                anchors.left: parent.left
                anchors.right: parent.right

                font: Tokens.font.body.small
                elide: Text.ElideRight
            }

            StyledText {
                id: subLabel

                anchors.left: parent.left
                anchors.right: parent.right

                visible: text
                color: Colours.palette.m3outline
                font: Tokens.font.label.small
                elide: Text.ElideRight
            }
        }

        Loader {
            asynchronous: true
            active: root.trailingIcon
            visible: active

            sourceComponent: MaterialIcon {
                text: root.trailingIcon
                color: Colours.palette.m3onSurfaceVariant
                fontStyle: Tokens.font.icon.medium
            }
        }
    }
}
