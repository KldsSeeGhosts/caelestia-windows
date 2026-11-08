pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Effects
import Caelestia.Config
import Caelestia.I18n
import qs.components
import qs.components.effects
import qs.services
import "EditorLogic.js" as Logic

// The editor's toolbar and its colour and size popover (windows.capture.ui =
// "shell"). The sizes, order and placement are the classic tool's: 44 px tall,
// 6 px padding, 30 px buttons, 10 px below the selection or above it or inside
// it, 6 px from the screen edge, draggable. EditorLogic.js computes every
// rectangle, and this file draws them with Caelestia components.
//
// The surfaces are glass: a blur of the frozen frame under them, a tint of
// surfaceContainer, an outline edge and an elevation shadow.
Item {
    id: root

    // The EditorState, the selection and the area the bar may use. All are
    // rectangles in this item's coordinates, which are the screen's.
    required property var editor
    required property var region
    required property var work
    // The frozen frame. The glass blurs the part of it under a surface.
    required property Item backdrop
    // An export is under way. Nothing responds until it ends.
    property bool busy

    signal copyRequested
    signal saveRequested
    signal closeRequested

    readonly property var layout: Logic.barLayout({
        clearArmed: editor.clearArmed,
        copyWidth: Logic.LABEL_EXTRA + copyMetrics.advanceWidth,
        clearWidth: Logic.LABEL_EXTRA + clearMetrics.advanceWidth
    })
    readonly property var barPlace: Logic.barPosition(work, region, layout, editor.barPosition)
    readonly property var ink: Logic.inkPopover()
    readonly property var inkAnchor: Logic.itemRect(layout, "color")
    readonly property var inkPlace: Logic.popoverPosition(work,
        { x: barPlace.x, y: barPlace.y, width: layout.width, height: layout.height },
        { x: barPlace.x + inkAnchor.x, y: barPlace.y + inkAnchor.y, width: inkAnchor.width, height: inkAnchor.height }, ink)

    enabled: !busy
    opacity: busy ? 0.6 : 1

    TextMetrics {
        id: copyMetrics

        font: Tokens.font.body.medium
        text: Tr.tr("Copy")
    }

    TextMetrics {
        id: clearMetrics

        font: Tokens.font.body.small
        text: Tr.tr("Clear all?")
    }

    // ---- bar -----------------------------------------------------------

    Glass {
        id: bar

        objectName: "editorToolbar"
        x: root.barPlace.x
        y: root.barPlace.y
        width: root.layout.width
        height: root.layout.height

        // Empty space on the bar moves it. The buttons are above this area.
        MouseArea {
            id: dragArea

            property point origin
            property point grab

            anchors.fill: parent
            cursorShape: pressed ? Qt.SizeAllCursor : Qt.ArrowCursor

            onPressed: mouse => {
                root.editor.inkOpen = false;
                grab = mapToItem(root, mouse.x, mouse.y);
                origin = Qt.point(bar.x, bar.y);
            }
            onPositionChanged: mouse => {
                if (!pressed)
                    return;
                const now = mapToItem(root, mouse.x, mouse.y);
                root.editor.barPosition = { x: origin.x + now.x - grab.x, y: origin.y + now.y - grab.y };
            }
        }

        // The selection highlight glides to the chosen tool.
        StyledRect {
            id: indicator

            readonly property var target: Logic.itemRect(root.layout, "tool:" + root.editor.tool)

            x: target ? target.x : 0
            y: target ? target.y : 0
            width: target ? target.width : 0
            height: target ? target.height : 0
            radius: Tokens.rounding.small
            color: Colours.palette.m3secondaryContainer

            Behavior on x {
                Anim {
                    type: Anim.DefaultSpatial
                }
            }
        }

        Repeater {
            model: root.layout.items.filter(item => item.id === "separator")

            Rectangle {
                required property var modelData

                x: modelData.x
                y: modelData.y
                width: modelData.width
                height: modelData.height
                color: Qt.alpha(Colours.palette.m3outline, 0.5)
            }
        }

        Repeater {
            model: Logic.TOOLS

            Cell {
                id: toolCell

                required property var modelData
                readonly property bool selected: root.editor.tool === modelData.id

                cellId: "tool:" + modelData.id
                objectName: "editorTool-" + modelData.id
                name: modelData.label
                icon: modelData.icon
                iconRotation: modelData.rotation ?? 0
                iconColor: selected ? Colours.palette.m3onSecondaryContainer : Colours.palette.m3onSurface
                onClicked: root.editor.setTool(modelData.id)
            }
        }

        Cell {
            cellId: "color"
            objectName: "editorColor"
            name: Tr.tr("Color and line size")
            highlighted: root.editor.inkOpen
            onClicked: root.editor.toggleInk()

            // The dot shows the colour, and its size the line size. It has a ring
            // so it reads on any colour.
            Rectangle {
                readonly property real d: Logic.dotDiameter(root.editor.size)

                anchors.centerIn: parent
                width: d + 5
                height: width
                radius: width / 2
                color: Qt.alpha(Colours.palette.m3outline, 0.5)

                Rectangle {
                    anchors.centerIn: parent
                    width: parent.d + 3
                    height: width
                    radius: width / 2
                    color: Colours.palette.m3surfaceContainer

                    Rectangle {
                        anchors.centerIn: parent
                        width: parent.parent.d
                        height: width
                        radius: width / 2
                        color: root.editor.color
                    }
                }
            }
        }

        Cell {
            cellId: "undo"
            objectName: "editor-undo"
            name: Tr.tr("Undo")
            icon: "undo"
            disabled: !root.editor.canUndo
            onClicked: root.editor.undo()
        }

        Cell {
            cellId: "redo"
            objectName: "editor-redo"
            name: Tr.tr("Redo")
            icon: "redo"
            disabled: !root.editor.canRedo
            onClicked: root.editor.redo()
        }

        Cell {
            cellId: "clear"
            objectName: "editor-clear"
            name: root.editor.clearArmed ? Tr.tr("Click again to clear all") : Tr.tr("Clear all")
            icon: "delete"
            iconColor: root.editor.clearArmed ? Colours.palette.m3error : Colours.palette.m3onSurface
            fill: root.editor.clearArmed ? Qt.alpha(Colours.palette.m3error, 0.15) : "transparent"
            label: root.editor.clearArmed ? Tr.tr("Clear all?") : ""
            labelFont: Tokens.font.body.small
            labelColor: Colours.palette.m3error
            onClicked: root.editor.pressClear()
            onExited: root.editor.disarmClear()
        }

        Cell {
            cellId: "save"
            objectName: "editor-save"
            name: Tr.tr("Save")
            icon: "download"
            onClicked: root.saveRequested()
        }

        Cell {
            cellId: "copy"
            objectName: "editor-copy"
            name: Tr.tr("Copy annotated image")
            icon: "content_copy"
            iconColor: Colours.palette.m3onPrimary
            fill: Colours.palette.m3primary
            stateColor: Colours.palette.m3onPrimary
            label: Tr.tr("Copy")
            labelFont: Tokens.font.body.medium
            labelColor: Colours.palette.m3onPrimary
            onClicked: root.copyRequested()
        }

        Cell {
            cellId: "close"
            objectName: "editor-close"
            name: Tr.tr("Close")
            icon: "close"
            onClicked: root.closeRequested()
        }
    }

    // ---- colour and size popover ---------------------------------------

    Glass {
        id: popover

        objectName: "editorInkPopover"
        x: root.inkPlace.x
        y: root.inkPlace.y
        width: root.ink.width
        height: root.ink.height
        visible: root.editor.inkOpen

        // A press on the popover's own space is not a click outside.
        MouseArea {
            anchors.fill: parent
        }

        StyledRect {
            x: root.ink.divider.x
            y: root.ink.divider.y
            width: root.ink.divider.width
            height: root.ink.divider.height
            color: Qt.alpha(Colours.palette.m3outline, 0.5)
        }

        StyledRect {
            x: root.ink.track.x
            y: root.ink.track.y
            width: root.ink.track.width
            height: root.ink.track.height
            radius: Tokens.rounding.small
            color: Colours.palette.m3surfaceContainerHigh
        }

        Repeater {
            model: root.ink.colors

            MouseArea {
                id: dot

                required property var modelData
                readonly property string value: Logic.COLORS[modelData.index]
                readonly property bool selected: root.editor.color === value

                objectName: "editorColor-" + modelData.index
                x: modelData.x
                y: modelData.y
                width: modelData.width
                height: modelData.height
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.editor.setColor(modelData.index)

                Accessible.role: Accessible.Button
                Accessible.name: dot.value

                // The chosen colour has a ring of foreground and surface colour.
                Rectangle {
                    anchors.centerIn: parent
                    visible: dot.selected
                    width: swatch.width + 7
                    height: width
                    radius: width / 2
                    color: Colours.palette.m3onSurface
                }

                Rectangle {
                    anchors.centerIn: parent
                    visible: dot.selected
                    width: swatch.width + 4
                    height: width
                    radius: width / 2
                    color: Colours.palette.m3surfaceContainer
                }

                Rectangle {
                    id: swatch

                    anchors.centerIn: parent
                    width: dot.containsMouse ? 22.4 : 20
                    height: width
                    radius: width / 2
                    color: dot.value
                    border.width: 1
                    border.color: Qt.alpha("black", 0.18)

                    Behavior on width {
                        Anim {
                            type: Anim.FastSpatial
                        }
                    }
                }
            }
        }

        Repeater {
            model: root.ink.sizes

            MouseArea {
                id: segment

                required property var modelData
                readonly property bool selected: root.editor.size === modelData.size

                objectName: "editorSize-" + modelData.label
                x: modelData.x
                y: modelData.y
                width: modelData.width
                height: modelData.height
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.editor.setSize(modelData.index)

                Accessible.role: Accessible.Button
                Accessible.name: modelData.label

                StyledRect {
                    anchors.fill: parent
                    radius: Tokens.rounding.small
                    color: segment.selected ? Colours.palette.m3primary
                        : (segment.containsMouse ? Qt.alpha(Colours.palette.m3surfaceContainerHighest, 0.8) : "transparent")
                }

                // A sample of the line in the chosen colour, then its letter.
                Row {
                    anchors.centerIn: parent
                    spacing: 8

                    Rectangle {
                        anchors.verticalCenter: parent.verticalCenter
                        width: 22
                        height: segment.modelData.size
                        radius: height / 2
                        color: root.editor.color
                    }

                    StyledText {
                        anchors.verticalCenter: parent.verticalCenter
                        text: segment.modelData.label
                        color: segment.selected ? Colours.palette.m3onPrimary : Colours.palette.m3onSurfaceVariant
                    }
                }
            }
        }
    }

    // ---- parts ---------------------------------------------------------

    // A glass surface: elevation, blurred backdrop, tint, edge and a top highlight.
    component Glass: Item {
        id: glass

        readonly property real cornerRadius: Tokens.rounding.large

        Elevation {
            anchors.fill: parent
            radius: glass.cornerRadius
            level: 3
        }

        ShaderEffectSource {
            id: copy

            anchors.fill: parent
            visible: false
            live: true
            sourceItem: root.backdrop
            sourceRect: Qt.rect(glass.x, glass.y, glass.width, glass.height)
        }

        Item {
            id: shape

            anchors.fill: parent
            layer.enabled: true
            visible: false

            Rectangle {
                anchors.fill: parent
                radius: glass.cornerRadius
            }
        }

        MultiEffect {
            anchors.fill: parent
            source: copy
            blurEnabled: true
            blur: 1
            blurMax: 32
            maskEnabled: true
            maskSource: shape
            maskThresholdMin: 0.5
            maskSpreadAtMin: 1
        }

        StyledRect {
            anchors.fill: parent
            radius: glass.cornerRadius
            color: Qt.alpha(Colours.palette.m3surfaceContainer, 0.88)
            border.width: 1
            border.color: Qt.alpha(Colours.palette.m3outline, 0.6)
        }

        Rectangle {
            x: glass.cornerRadius
            y: 1
            width: glass.width - glass.cornerRadius * 2
            height: 1
            color: Qt.alpha(Colours.palette.m3onSurface, 0.07)
        }
    }

    // A bar button placed where EditorLogic.barLayout() puts the item `cellId`.
    component Cell: BarButton {
        required property string cellId
        readonly property var spot: Logic.itemRect(root.layout, cellId)

        x: spot ? spot.x : 0
        y: spot ? spot.y : 0
        width: spot ? spot.width : 0
        height: spot ? spot.height : 0
    }

    // A 30 px button. `label` makes it a pill with an icon and text.
    component BarButton: StyledRect {
        id: button

        property string name
        property string icon
        property real iconRotation
        property color iconColor: Colours.palette.m3onSurface
        property color fill: "transparent"
        property color stateColor: Colours.palette.m3onSurface
        property bool highlighted
        property bool disabled
        property string label
        property font labelFont: Tokens.font.body.medium
        property color labelColor: Colours.palette.m3onSurface
        default property alias content: extra.data

        signal clicked
        // The pointer left the button. Clear disarms on it, as the classic tool does.
        signal exited

        radius: Tokens.rounding.small
        color: highlighted ? Qt.alpha(Colours.palette.m3surfaceContainerHighest, 0.8) : fill
        opacity: disabled ? 0.3 : 1

        Accessible.role: Accessible.Button
        Accessible.name: name
        Accessible.onPressAction: button.clicked()

        StateLayer {
            objectName: button.objectName + "-layer"
            color: button.stateColor
            disabled: button.disabled
            onClicked: button.clicked()
            onExited: button.exited()
        }

        Row {
            anchors.centerIn: parent
            spacing: 6

            MaterialIcon {
                anchors.verticalCenter: parent.verticalCenter
                visible: button.icon !== ""
                text: button.icon
                rotation: button.iconRotation
                color: button.iconColor
                fontStyle: Tokens.font.icon.medium
            }

            StyledText {
                anchors.verticalCenter: parent.verticalCenter
                visible: button.label !== ""
                text: button.label
                font: button.labelFont
                color: button.labelColor
            }
        }

        Item {
            id: extra

            anchors.fill: parent
        }
    }
}
