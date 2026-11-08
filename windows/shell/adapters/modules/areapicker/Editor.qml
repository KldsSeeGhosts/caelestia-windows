pragma ComponentBehavior: Bound

import QtQuick
import qs.components
import qs.services

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

    property bool present

    signal copyRequested
    signal saveRequested
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
        cursorShape: Qt.CrossCursor
        acceptedButtons: Qt.LeftButton

        // The first click while the popover is open only closes it.
        onPressed: mouse => {
            if (root.editor.inkOpen)
                root.editor.inkOpen = false;
            else
                root.editor.pressAt(mouse.x, mouse.y);
        }
        onPositionChanged: mouse => root.editor.moveTo(mouse.x, mouse.y)
        onReleased: root.editor.releaseAt()
        onCanceled: root.editor.abandon()
    }

    EditorToolbar {
        objectName: "captureEditorToolbar"
        anchors.fill: parent
        editor: root.editor
        region: root.region
        work: root.area
        backdrop: root.backdrop
        busy: root.busy
        onCopyRequested: root.copyRequested()
        onSaveRequested: root.saveRequested()
        onCloseRequested: root.closeRequested()
    }
}
