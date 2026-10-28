pragma ComponentBehavior: Bound

import QtQuick
import Caelestia.Config
import qs.components
import qs.services

// Original overlay pill and motion, extracted from its native window without
// changing layout, colours, timings or the synthetic (not audio-level) bars.
Item {
    width: pill.width
    height: pill.height

    Rectangle {
        x: -3
        y: 2
        width: pill.width + 6
        height: pill.height + 6
        radius: pill.radius + 3
        color: Qt.rgba(0, 0, 0, 0.1)
        z: -1
    }
    Rectangle {
        id: pill
        anchors.centerIn: parent
        width: Math.max(112, listeningPanel.implicitWidth + 24)
        height: listeningPanel.implicitHeight + 22
        radius: height / 2
        color: colours.surface
        border.width: 1
        border.color: colours.border

        Behavior on width { Anim { type: Anim.Emphasized } }
        Behavior on color { CAnim {} }
        Behavior on border.color { CAnim {} }

        Item {
            id: listeningPanel
            anchors.centerIn: parent
            implicitWidth: listeningLayout.implicitWidth
            implicitHeight: listeningLayout.implicitHeight
            opacity: 1
            visible: true

            Row {
                id: listeningLayout
                anchors.centerIn: parent
                spacing: 12

                Badge {
                    icon: "mic"
                    badgeColor: colours.roseContainer
                    iconColor: colours.rose
                    pulsing: true
                }
                Row {
                    spacing: 2
                    anchors.verticalCenter: parent.verticalCenter
                    Repeater {
                        model: 5
                        Rectangle {
                            id: bar
                            required property int index
                            width: 3
                            height: 6
                            radius: 2
                            color: colours.rose
                            anchors.verticalCenter: parent.verticalCenter

                            SequentialAnimation on height {
                                running: Dictation.state === Dictation.listeningState
                                    || Dictation.state === Dictation.processingState
                                loops: Animation.Infinite
                                PauseAnimation { duration: bar.index * 150 }
                                NumberAnimation {
                                    from: 6
                                    to: 18
                                    duration: 450
                                    easing.type: Easing.InOutSine
                                }
                                NumberAnimation {
                                    from: 18
                                    to: 6
                                    duration: 450
                                    easing.type: Easing.InOutSine
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    QtObject {
        id: colours
        readonly property color surface: Colours.light ? "#FFFFFF" : "#2A2926"
        readonly property color border: Colours.light ? Qt.rgba(0, 0, 0, 0.1) : Qt.rgba(1, 1, 1, 0.12)
        readonly property color rose: "#993C1D"
        readonly property color roseContainer: "#FAECE7"
    }

    component Badge: Rectangle {
        id: badgeRoot
        property string icon
        property color badgeColor
        property color iconColor
        property bool pulsing: false
        width: 28
        height: 28
        radius: 14
        color: badgeColor
        border.width: 1
        border.color: Qt.alpha(iconColor, 0.35)

        MaterialIcon {
            anchors.centerIn: parent
            text: badgeRoot.icon
            color: badgeRoot.iconColor
            fontStyle: Tokens.font.icon.small
            fill: 1
        }
        SequentialAnimation on scale {
            running: badgeRoot.pulsing
            loops: Animation.Infinite
            NumberAnimation {
                from: 1
                to: 1.12
                duration: 700
                easing.type: Easing.InOutSine
            }
            NumberAnimation {
                from: 1.12
                to: 1
                duration: 700
                easing.type: Easing.InOutSine
            }
        }
    }
}
