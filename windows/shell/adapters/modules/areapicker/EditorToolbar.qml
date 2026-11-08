pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Effects
import Caelestia.Config
import Caelestia.I18n
import qs.components
import qs.components.controls
import qs.components.effects
import qs.services
import "EditorLogic.js" as Logic

// The editor's toolbar and its colour and size popover (windows.capture.ui =
// "shell"). Every button is a Caelestia control (IconButton, IconTextButton,
// TextButton, ButtonBase) with the shell's fonts, padding and state layers. The
// sizes come from those controls and from Tokens. EditorLogic.js takes the
// measured sizes, decides where everything goes (below, above or inside the
// selection, clamped to the screen, draggable) and rounds each position to a
// whole device pixel, so text stays sharp at any display scaling.
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

    // The device pixel ratio of the screen this toolbar is on.
    readonly property real dpr: editor.scale > 0 ? editor.scale : 1
    readonly property var metrics: ({
        scale: dpr,
        padding: Tokens.padding.small,
        spacing: Tokens.spacing.extraSmall,
        groupSpacing: Tokens.spacing.small,
        separatorSpacing: Tokens.spacing.small,
        separatorInset: Tokens.spacing.small,
        gap: Tokens.spacing.small,
        margin: Tokens.spacing.small
    })
    readonly property var buttonSize: ({ width: probe.implicitWidth, height: probe.implicitHeight })

    readonly property var layout: Logic.barLayout({
        metrics: metrics,
        button: buttonSize,
        clear: { width: clearButton.implicitWidth, height: clearButton.implicitHeight },
        copy: { width: copyButton.implicitWidth, height: copyButton.implicitHeight }
    })
    readonly property var barPlace: Logic.barPosition(work, region, layout, editor.barPosition, metrics)
    readonly property var ink: Logic.inkPopover({
        metrics: metrics,
        cell: buttonSize,
        segment: { width: segmentProbe.implicitWidth, height: segmentProbe.implicitHeight }
    })
    readonly property var inkAnchor: Logic.itemRect(layout, "color")
    readonly property var inkPlace: Logic.popoverPosition(work,
        { x: barPlace.x, y: barPlace.y, width: layout.width, height: layout.height },
        { x: barPlace.x + inkAnchor.x, y: barPlace.y + inkAnchor.y, width: inkAnchor.width, height: inkAnchor.height },
        ink, metrics)

    enabled: !busy
    opacity: busy ? 0.6 : 1

    // Unseen copies of a button and a segment. Their implicit sizes are what
    // the layout measures, so every icon button on the bar has the same size.
    IconButton {
        id: probe

        visible: false
        type: IconButton.Text
        icon: "edit"
    }

    TextButton {
        id: segmentProbe

        visible: false
        type: TextButton.Tonal
        text: "M"
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

        // The chosen tool has a tonal container that glides to it.
        StyledRect {
            id: indicator

            readonly property var target: Logic.itemRect(root.layout, "tool:" + root.editor.tool)

            x: target ? target.x : 0
            y: target ? target.y : 0
            width: target ? target.width : 0
            height: target ? target.height : 0
            radius: Tokens.rounding.medium
            color: Colours.palette.m3secondaryContainer

            Behavior on x {
                Anim {
                    type: Anim.DefaultSpatial
                }
            }
        }

        // The colour button has a container while its popover is open.
        StyledRect {
            readonly property var target: Logic.itemRect(root.layout, "color")

            visible: root.editor.inkOpen
            x: target ? target.x : 0
            y: target ? target.y : 0
            width: target ? target.width : 0
            height: target ? target.height : 0
            radius: Tokens.rounding.medium
            color: Colours.palette.m3surfaceContainerHighest
        }

        Repeater {
            model: root.layout.items.filter(item => item.id === "separator")

            Rectangle {
                required property var modelData

                x: modelData.x
                y: modelData.y
                width: modelData.width
                height: modelData.height
                color: Colours.palette.m3outlineVariant
            }
        }

        Repeater {
            model: Logic.TOOLS

            BarIcon {
                id: toolButton

                required property var modelData
                readonly property bool selected: root.editor.tool === modelData.id

                cellId: "tool:" + modelData.id
                objectName: "editorTool-" + modelData.id
                tip: modelData.label
                icon: modelData.icon
                checked: selected
                activeOnColour: Colours.palette.m3onSecondaryContainer
                onClicked: root.editor.setTool(modelData.id)

                // Material Symbols has no plain diagonal line, so the dash is turned.
                label.rotation: modelData.rotation ?? 0
            }
        }

        BarIcon {
            cellId: "color"
            objectName: "editorColor"
            tip: Tr.tr("Colour and size")
            onClicked: root.editor.toggleInk()

            // The dot shows the colour, and its size the line size. Its edge keeps
            // it visible on any colour.
            Rectangle {
                anchors.centerIn: parent
                width: Logic.dotDiameter(root.editor.size, root.buttonSize.height, root.dpr)
                height: width
                radius: width / 2
                color: root.editor.color
                border.width: 1 / root.dpr
                border.color: Colours.palette.m3outline
            }
        }

        BarIcon {
            cellId: "undo"
            objectName: "editor-undo"
            tip: Tr.tr("Undo")
            icon: "undo"
            disabled: !root.editor.canUndo
            onClicked: root.editor.undo()
        }

        BarIcon {
            cellId: "redo"
            objectName: "editor-redo"
            tip: Tr.tr("Redo")
            icon: "redo"
            disabled: !root.editor.canRedo
            onClicked: root.editor.redo()
        }

        // One button for both states, so the pointer stays on the same control
        // while it grows. A second control swapped in would make the first lose
        // the pointer and disarm at once.
        BarText {
            id: clearButton

            readonly property bool armed: root.editor.clearArmed

            cellId: "clear"
            objectName: "editor-clear"
            tip: armed ? Tr.tr("Click again to clear") : Tr.tr("Clear all")
            icon: "delete"
            text: armed ? Tr.tr("Clear all?") : ""
            spacing: armed ? Tokens.spacing.small : 0
            horizontalPadding: armed ? Tokens.padding.small : Tokens.padding.extraSmall / 2
            type: armed ? IconTextButton.Filled : IconTextButton.Text
            inactiveColour: Colours.palette.m3error
            inactiveOnColour: armed ? Colours.palette.m3onError : Colours.palette.m3onSurfaceVariant
            implicitWidth: Math.max(probe.implicitWidth,
                iconLabel.implicitWidth + (armed ? spacing + label.implicitWidth : 0) + horizontalPadding * 2)
            onClicked: root.editor.pressClear()

            // Moving off the button disarms it, as the classic tool does.
            Connections {
                target: clearButton.stateLayer

                function onExited(): void {
                    root.editor.disarmClear();
                }
            }
        }

        BarIcon {
            cellId: "save"
            objectName: "editor-save"
            tip: Tr.tr("Save")
            icon: "download"
            onClicked: root.saveRequested()
        }

        BarText {
            id: copyButton

            cellId: "copy"
            objectName: "editor-copy"
            tip: Tr.tr("Copy")
            icon: "content_copy"
            text: Tr.tr("Copy")
            type: IconTextButton.Filled
            onClicked: root.copyRequested()
        }

        BarIcon {
            cellId: "close"
            objectName: "editor-close"
            tip: Tr.tr("Close")
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

        Rectangle {
            x: root.ink.divider.x
            y: root.ink.divider.y
            width: root.ink.divider.width
            height: root.ink.divider.height
            color: Colours.palette.m3outlineVariant
        }

        Repeater {
            model: root.ink.colors

            ButtonBase {
                id: dot

                required property var modelData
                readonly property string value: Logic.COLORS[modelData.index]
                readonly property bool selected: root.editor.color === value

                objectName: "editorColor-" + modelData.index
                x: modelData.x
                y: modelData.y
                width: modelData.width
                height: modelData.height
                implicitWidth: modelData.width
                implicitHeight: modelData.height
                type: ButtonBase.Text
                isRound: true
                inactiveOnColour: Colours.palette.m3onSurface
                activeOnColour: Colours.palette.m3onSurface
                onClicked: root.editor.setColor(modelData.index)

                Accessible.role: Accessible.Button
                Accessible.name: dot.value
                Accessible.onPressAction: dot.clicked()

                // The chosen colour has a ring in the foreground colour.
                Rectangle {
                    anchors.fill: parent
                    visible: dot.selected
                    radius: width / 2
                    color: "transparent"
                    border.width: Tokens.spacing.extraSmall / 2
                    border.color: Colours.palette.m3onSurface
                }

                Rectangle {
                    anchors.centerIn: parent
                    width: parent.width - Tokens.spacing.extraSmall * 2
                    height: width
                    radius: width / 2
                    color: dot.value
                    border.width: 1 / root.dpr
                    border.color: Colours.palette.m3outline
                }
            }
        }

        Repeater {
            model: root.ink.sizes

            TextButton {
                id: segment

                required property var modelData
                readonly property bool selected: root.editor.size === modelData.size

                objectName: "editorSize-" + modelData.label
                x: modelData.x
                y: modelData.y
                width: modelData.width
                height: modelData.height
                type: TextButton.Tonal
                checked: selected
                text: modelData.label
                onClicked: root.editor.setSize(modelData.index)

                ToolTip.visible: hovered
                ToolTip.delay: 500
                ToolTip.text: [Tr.tr("Thin line"), Tr.tr("Medium line"), Tr.tr("Thick line")][modelData.index] ?? ""
                Accessible.role: Accessible.Button
                Accessible.name: ToolTip.text
                Accessible.onPressAction: segment.clicked()
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
            height: 1 / root.dpr
            color: Qt.alpha(Colours.palette.m3onSurface, 0.07)
        }
    }

    // An IconButton placed where EditorLogic.barLayout() puts the item `cellId`.
    component BarIcon: IconButton {
        id: button

        required property string cellId
        // The tooltip and the accessible name.
        property string tip
        readonly property var spot: Logic.itemRect(root.layout, cellId)

        x: spot ? spot.x : 0
        y: spot ? spot.y : 0
        width: spot ? spot.width : implicitWidth
        height: spot ? spot.height : implicitHeight
        type: IconButton.Text

        ToolTip.visible: hovered
        ToolTip.delay: 500
        ToolTip.text: tip
        Accessible.role: Accessible.Button
        Accessible.name: tip
        Accessible.onPressAction: button.clicked()
    }

    // An IconTextButton placed like BarIcon. It takes the height of the icon
    // buttons and their icon size, so a row of both reads as one.
    component BarText: IconTextButton {
        id: button

        required property string cellId
        property string tip
        readonly property var spot: Logic.itemRect(root.layout, cellId)

        x: spot ? spot.x : 0
        y: spot ? spot.y : 0
        width: spot ? spot.width : implicitWidth
        height: spot ? spot.height : implicitHeight
        iconLabel.fontStyle: Tokens.font.icon.medium
        verticalPadding: Tokens.padding.extraSmall / 2
        implicitHeight: Math.max(probe.implicitHeight, Math.max(iconLabel.implicitHeight, label.implicitHeight) + verticalPadding * 2)

        ToolTip.visible: hovered
        ToolTip.delay: 500
        ToolTip.text: tip
        Accessible.role: Accessible.Button
        Accessible.name: tip
        Accessible.onPressAction: button.clicked()
    }
}
