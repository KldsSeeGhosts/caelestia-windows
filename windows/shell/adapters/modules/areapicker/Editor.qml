pragma ComponentBehavior: Bound

import QtQuick
import qs.components
import qs.services
import "EditorLogic.js" as Logic

// The editor's interface on the screen that holds the selection: the wash
// outside it, the drawing surface over it and the toolbar. Picker.qml loads it
// when a selection is made. The frozen frame and the annotation layer are not
// here, because they are what gets exported (see Picker.qml).
//
// The wash is 55% black, as in the classic tool, and fades in as the picker's
// tint fades out.
Item {
    id: root

    objectName: "captureEditor"

    // The EditorState, the selection in screen coordinates ({ x, y, width,
    // height }) and the frozen frame the toolbar's glass blurs.
    required property var editor
    required property var region
    required property Item backdrop
    // An export is under way.
    property bool busy
    property bool canFinish
    property bool savedOriginal

    property bool present

    signal copyRequested
    signal saveRequested
    signal doneRequested
    signal closeRequested

    readonly property var area: ({ x: 0, y: 0, width: width, height: height })

    anchors.fill: parent
    opacity: present ? 1 : 0

    Component.onCompleted: present = true

    Behavior on opacity {
        Anim {
            type: Anim.Standard
        }
    }

    // Four rectangles around the selection.
    Repeater {
        model: [
            { x: 0, y: 0, w: root.width, h: root.region.y },
            { x: 0, y: root.region.y + root.region.height, w: root.width, h: root.height - root.region.y - root.region.height },
            { x: 0, y: root.region.y, w: root.region.x, h: root.region.height },
            { x: root.region.x + root.region.width, y: root.region.y, w: root.width - root.region.x - root.region.width, h: root.region.height }
        ]

        Rectangle {
            required property var modelData

            objectName: "captureEditorWash"
            x: modelData.x
            y: modelData.y
            width: Math.max(0, modelData.w)
            height: Math.max(0, modelData.h)
            color: Qt.rgba(0, 0, 0, 0.55)
        }
    }

    // The drawing surface covers the selection. A press that starts a stroke may
    // leave it, and the stroke goes on being drawn, clipped to the selection.
    MouseArea {
        id: canvas

        objectName: "captureEditorCanvas"
        x: root.region.x
        y: root.region.y
        width: root.region.width
        height: root.region.height
        enabled: !root.busy
        cursorShape: root.editor.tool === "select" ? Qt.ArrowCursor : (root.editor.tool === "text" ? Qt.IBeamCursor : Qt.CrossCursor)
        acceptedButtons: Qt.LeftButton | Qt.RightButton

        // The first click while a popover is open only closes it. A click while
        // text is active commits that text and starts nothing else. Right click
        // erases the topmost annotation at the point.
        onPressed: mouse => {
            if (mouse.button === Qt.RightButton) {
                if (root.editor.textEditing)
                    root.editor.commitText();
                else if (root.editor.inkOpen || root.editor.toolMenu >= 0)
                    root.editor.closePopovers();
                else
                    root.editor.eraseAt(mouse.x, mouse.y);
                return;
            }
            if (root.editor.inkOpen || root.editor.toolMenu >= 0)
                root.editor.closePopovers();
            else if (root.editor.textEditing)
                root.editor.commitText();
            else
                root.editor.pressAt(mouse.x, mouse.y);
        }
        onPositionChanged: mouse => root.editor.moveTo(mouse.x, mouse.y, !!(mouse.modifiers & Qt.ShiftModifier))
        onReleased: mouse => {
            if (mouse.button === Qt.LeftButton)
                root.editor.releaseAt();
        }
        onCanceled: root.editor.abandon()
    }

    // The selected annotation's bounds, deliberately light so it does not read
    // as part of the image. It never enters the exported item.
    Rectangle {
        objectName: "captureEditorSelection"
        visible: root.editor.selectionBounds !== null && !root.editor.textEditing
        x: root.region.x + (root.editor.selectionBounds?.x ?? 0)
        y: root.region.y + (root.editor.selectionBounds?.y ?? 0)
        width: root.editor.selectionBounds?.width ?? 0
        height: root.editor.selectionBounds?.height ?? 0
        color: "transparent"
        border.width: 1
        border.color: Qt.alpha(Colours.palette.m3primary, 0.85)
    }

    // Inline text placement. The input itself is not exported; committing it
    // creates a text annotation in the annotation layer.
    Item {
        x: root.region.x
        y: root.region.y
        width: root.region.width
        height: root.region.height
        visible: root.editor.textEditing

        TextInput {
            id: textInput

            objectName: "captureEditorTextInput"
            visible: root.editor.textEditing
            x: root.editor.textEdit?.x ?? 0
            y: root.editor.textEdit?.y ?? 0
            width: Math.max(24, contentWidth + 6)
            height: Math.max(Logic.textPixelSize(root.editor.textEdit?.size ?? root.editor.size) * 1.25, contentHeight + 2)
            text: root.editor.textEdit?.text ?? ""
            color: root.editor.textEdit?.color ?? root.editor.color
            font.pixelSize: Logic.textPixelSize(root.editor.textEdit?.size ?? root.editor.size)
            selectionColor: Qt.alpha(Colours.palette.m3primary, 0.35)
            selectedTextColor: Colours.palette.m3onSurface
            clip: false
            activeFocusOnTab: false

            onVisibleChanged: {
                if (visible)
                    forceActiveFocus();
            }
            onTextEdited: root.editor.updateText(text)
            Keys.onReturnPressed: event => {
                root.editor.commitText();
                event.accepted = true;
            }
            Keys.onEnterPressed: event => {
                root.editor.commitText();
                event.accepted = true;
            }
            Keys.onEscapePressed: event => {
                root.editor.cancelText();
                event.accepted = true;
            }
        }
    }

    EditorToolbar {
        objectName: "captureEditorToolbar"
        anchors.fill: parent
        editor: root.editor
        region: root.region
        work: root.area
        backdrop: root.backdrop
        busy: root.busy
        canFinish: root.canFinish
        savedOriginal: root.savedOriginal
        onCopyRequested: root.copyRequested()
        onSaveRequested: root.saveRequested()
        onDoneRequested: root.doneRequested()
        onCloseRequested: root.closeRequested()
    }
}
