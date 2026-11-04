pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Caelestia.Config
import qs.components
import qs.services

// A full-width pill track with a raised pill under the chosen segment. The pill
// slides; nothing else moves.
Rectangle {
    id: root
    objectName: "quotaSegments"

    // [{ key, label }]
    property var model: []
    property string current: ""
    property string family: ""
    readonly property int index: Math.max(0, model.findIndex(m => m.key === current))
    readonly property real segment: (width - inset * 2) / Math.max(1, model.length)
    readonly property int inset: 4

    signal activated(string key)

    implicitHeight: 40
    radius: height / 2
    color: Colours.palette.m3surfaceContainerHigh

    Rectangle {
        objectName: "quotaSegmentPill"
        x: root.inset + root.segment * root.index
        y: root.inset
        width: root.segment
        height: root.height - root.inset * 2
        radius: height / 2
        color: Colours.light ? Colours.palette.m3surfaceContainerLowest : Colours.palette.m3surface
        border.width: 1
        border.color: Qt.alpha(Colours.palette.m3outlineVariant, 0.6)

        Behavior on x {
            Anim {
                type: Anim.Emphasized
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
                    color: !segment.selected && segment.hovered ? Qt.alpha(Colours.palette.m3onSurface, 0.06) : "transparent"
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
                    font.pixelSize: 15
                    font.weight: segment.selected ? Font.Bold : Font.Medium
                }
            }
        }
    }
}
