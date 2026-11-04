pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Caelestia.Config
import qs.components
import qs.services

// OpenUsage's capsule segments (Views/CapsuleSegments.swift): a 28 dp capsule
// track with a 2 dp inset and a raised thumb that springs to the chosen
// segment. Labels are 13 dp, medium when chosen.
Rectangle {
    id: root
    objectName: "quotaSegments"

    // [{ key, label }]
    property var model: []
    property string current: ""
    property string family: ""
    readonly property int index: Math.max(0, model.findIndex(m => m.key === current))
    readonly property real segment: (width - inset * 2) / Math.max(1, model.length)
    readonly property int inset: 2
    readonly property color hairline: Qt.alpha(Colours.palette.m3onSurface, Colours.light ? 0.05 : 0.06)

    signal activated(string key)

    implicitHeight: 28
    radius: height / 2
    color: Colours.palette.m3surfaceContainerHigh

    Item {
        id: thumb
        objectName: "quotaSegmentPill"
        x: root.inset + root.segment * root.index
        y: root.inset
        width: root.segment
        height: root.height - root.inset * 2

        // The thumb's soft shadow: black 12%, 1 dp down.
        Rectangle {
            anchors.fill: parent
            anchors.topMargin: 1
            anchors.bottomMargin: -1
            radius: height / 2
            color: Qt.alpha(Colours.palette.m3shadow, 0.12)
        }
        Rectangle {
            anchors.fill: parent
            radius: height / 2
            color: Colours.light ? Colours.palette.m3surfaceContainerLowest : Colours.palette.m3surfaceBright
            border.width: 1
            border.color: root.hairline
        }

        // OpenUsage springs the thumb (response 0.42, damping 0.8); Caelestia's
        // expressive spatial curve is its closest equivalent.
        Behavior on x {
            Anim {
                type: Anim.DefaultSpatial
            }
        }
    }
    Row {
        x: root.inset
        y: root.inset
        Repeater {
            model: root.model
            delegate: AbstractButton {
                id: segment

                required property var modelData
                readonly property bool selected: root.current === modelData.key

                objectName: "quotaSegment"
                width: root.segment
                height: root.height - root.inset * 2
                hoverEnabled: true
                onClicked: root.activated(modelData.key)
                // Windows AbstractButton activates on Space, not Return/Enter.
                Keys.onReturnPressed: segment.click()
                Keys.onEnterPressed: segment.click()
                Accessible.name: modelData.label
                Accessible.checkable: true
                Accessible.checked: selected
                background: Rectangle {
                    radius: height / 2
                    color: "transparent"
                    border.width: segment.activeFocus ? 2 : 0
                    border.color: Colours.palette.m3primary
                }
                contentItem: StyledText {
                    text: segment.modelData.label
                    horizontalAlignment: Text.AlignHCenter
                    verticalAlignment: Text.AlignVCenter
                    elide: Text.ElideRight
                    color: segment.selected ? Colours.palette.m3onSurface : Colours.palette.m3onSurfaceVariant
                    font.family: root.family
                    font.pixelSize: 13
                    font.weight: segment.selected ? Font.Medium : Font.Normal

                    Behavior on color {
                        ColorAnimation {
                            duration: 180
                            easing.type: Easing.InOutQuad
                        }
                    }
                }
            }
        }
    }
}
