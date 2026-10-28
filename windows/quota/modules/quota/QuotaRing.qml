pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Shapes
import QtQuick.Controls
import qs.components
import qs.services
import "QuotaLogic.js" as Logic

AbstractButton {
    id: root
    objectName: "quotaRing"
    required property var group
    required property var summary
    required property bool saved
    required property bool selected
    required property bool revealed
    required property url iconSource
    required property string family
    required property Item tooltipBounds
    height: 56
    hoverEnabled: true
    Accessible.name: group.label + ", " + summary.map(s => s.label + " " + Math.round(s.remaining * 100) + "% remaining").join(", ")
    onClicked: Quota.selectGroup(group.provider)

    function colour(bucket): color {
        if (saved) return Colours.palette.m3outline;
        if (bucket.remaining <= 0.15) return Colours.palette.m3error;
        const category = Logic.windowCategory(bucket.label);
        return category === "primary" ? Colours.palette.m3primary
            : category === "tertiary" ? Colours.palette.m3tertiary : Colours.palette.m3secondary;
    }
    background: Item {}
    contentItem: Item {
        Item {
            id: ring
            width: 44; height: 44
            anchors.horizontalCenter: parent.horizontalCenter
            Repeater {
                model: Math.max(1, root.summary.length)
                delegate: Shape {
                    id: shape
                    required property int index
                    readonly property real r: index === 0 ? 20.5 : 15.5
                    readonly property var bucket: index < root.summary.length ? root.summary[index] : null
                    property real sweep: root.revealed && bucket ? bucket.remaining * 360 : 0
                    Behavior on sweep { Anim { type: Anim.Emphasized; duration: 500 } }
                    width: 44; height: 44
                    preferredRendererType: Shape.CurveRenderer
                    ShapePath {
                        strokeWidth: 3
                        strokeColor: Qt.alpha(Colours.palette.m3onSurface, 0.09)
                        fillColor: "transparent"
                        capStyle: ShapePath.RoundCap
                        PathAngleArc { centerX: 22; centerY: 22; radiusX: shape.r; radiusY: shape.r; startAngle: -90; sweepAngle: 360 }
                    }
                    ShapePath {
                        strokeWidth: 3
                        strokeColor: shape.bucket ? root.colour(shape.bucket) : "transparent"
                        fillColor: "transparent"
                        capStyle: ShapePath.RoundCap
                        PathAngleArc { centerX: 22; centerY: 22; radiusX: shape.r; radiusY: shape.r; startAngle: -90; sweepAngle: shape.sweep }
                    }
                }
            }
            Rectangle {
                anchors.centerIn: parent
                width: root.summary.length > 1 ? 25 : 35
                height: width; radius: width / 2
                color: root.selected ? Colours.palette.m3secondaryContainer
                    : root.hovered ? Qt.alpha(Colours.palette.m3onSurface, 0.06) : "transparent"
            }
            Image {
                anchors.centerIn: parent
                width: 16; height: 16
                source: root.iconSource
                sourceSize: Qt.size(32, 32)
                fillMode: Image.PreserveAspectFit
            }
            StyledText {
                anchors.centerIn: parent
                visible: !root.iconSource
                text: String(root.group.label).slice(0, 2)
                font.family: root.family; font.pixelSize: 11; font.weight: Font.DemiBold
                color: Colours.palette.m3onSurfaceVariant
            }
            Rectangle {
                anchors.centerIn: parent
                width: 47; height: 47; radius: 23.5
                color: "transparent"
                border.width: root.activeFocus ? 1.5 : 0
                border.color: Colours.palette.m3primary
            }
        }
        Rectangle {
            anchors.horizontalCenter: parent.horizontalCenter
            y: 52
            width: 4; height: 4; radius: 2
            visible: root.selected
            color: Colours.palette.m3onSurface
        }
    }
    QuotaToolTip {
        visible: root.hovered
        text: root.group.label + "\n"
            + (root.summary.length ? root.summary.map(s => s.title + ": " + Math.round(s.remaining * 100) + "% remaining").join("\n") : qsTr("No quota reading"))
            + (root.saved ? qsTr("\nSome readings are saved or unavailable.") : "")
            + qsTr("\nLowest remaining per window across accounts and scopes.")
        boundsItem: root.tooltipBounds
        family: root.family
    }
}
