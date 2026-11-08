pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Window
import Quickshell
import Quickshell.Wayland
import Caelestia
import Caelestia.I18n
import Caelestia.Windows
import qs.components
import qs.components.effects
import qs.services
import qs.utils
import "CaptureLogic.js" as Logic
import "../../utils/FileUrls.js" as FileUrls

// Windows adaptation of upstream modules/areapicker/Picker.qml.
//
// The Hyprland-only parts are replaced:
// - Hypr.toplevelsForWs and lastIpcObject become the z-ordered window stack that
//   AreaPicker reads once from Hyprland.windowStack().
// - `hyprctl cursorpos` becomes this MouseArea's own pointer position. Until the
//   pointer enters a screen's window, that screen shows only the tint.
// - Hypr.options (border size and rounding) becomes the fixed 2 px outline and
//   square corners of the current capture tool.
// - Releasing a selection opens the editor over it (Editor.qml) and saves
//   nothing. Copy and Save in the editor export the composed item, the frozen
//   view plus the annotation layer, with CUtils.saveItem. Save writes
//   Pictures\Screenshots and Copy hands the image to Clipboard.copyImageFile.
MouseArea {
    id: root

    required property var owner
    required property ShellScreen screen

    // This screen in the shape the logic module expects. Logical pixels.
    readonly property var geometry: ({
        name: screen.name,
        x: screen.x,
        y: screen.y,
        width: width > 0 ? width : screen.width,
        height: height > 0 ? height : screen.height
    })
    readonly property bool hasContent: view.hasContent
    readonly property real dpr: Window.window ? Window.window.devicePixelRatio : screen.devicePixelRatio
    // The editor is shared by every screen's window. Only the screen that holds
    // the selection shows its toolbar and annotations.
    readonly property var editor: owner.editor
    readonly property bool editsHere: owner.editing && owner.editScreen === screen.name
    readonly property var editRegion: editsHere ? owner.editPlan.logical : ({ x: 0, y: 0, width: 0, height: 0 })

    // Topmost first, in this screen's own coordinates. Fixed at open.
    property var windows: []

    // Displayed selection. Animated unless the user is dragging.
    property real rsx
    property real rsy
    property real sw
    property real sh
    property real startX
    property real startY
    property bool dragging
    // Press state, set by pressAt and releaseAt. The handlers below take plain
    // coordinates so the fixture can drive them without window input.
    property bool down
    property real lastX
    property real lastY
    readonly property real borderWidth: 2
    readonly property bool showSelection: owner.allReady && !owner.editing && (containsMouse || down || owner.closing)

    function select(rect: var): void {
        rsx = rect.x;
        rsy = rect.y;
        sw = rect.width;
        sh = rect.height;
    }

    // Nothing selected: the tint covers the screen and the outline is hidden.
    function clearSelection(): void {
        select({ x: lastX, y: lastY, width: 0, height: 0 });
    }

    function hover(x: real, y: real): void {
        lastX = x;
        lastY = y;
        select(Logic.targetAt(windows, x, y, geometry).rect);
    }

    function targetForRelease(x: real, y: real): var {
        if (dragging)
            return Logic.spanRect(startX, startY, x, y, geometry);
        return Logic.targetAt(windows, x, y, geometry).rect;
    }

    // Releasing the pointer opens the editor over the selection. Nothing is
    // written here: only Copy and Save in the editor produce an image.
    function beginEdit(selection: var): void {
        // Nothing to cut from until the view is in a window.
        if (owner.saving || owner.closing || owner.editing || !view.Window.window)
            return;
        const plan = Logic.exportPlan(selection, geometry, dpr);
        if (!plan.valid)
            return;
        select(plan.logical);
        owner.startEditing(root, plan);
    }

    // Cut the selection out of the composed item, the frozen view plus the
    // annotation layer. saveItem grabs `composed` itself, so the tint, the wash,
    // the toolbar and any fade are never part of the image. `kind` is "copy" or
    // "save". Results go to the owner with this session's number, so a result
    // that arrives after the picker has closed is ignored. Callbacks use `o`,
    // never `root`, because this item may be gone by then.
    function exportEdit(kind: string): void {
        if (!editsHere || owner.saving || owner.closing || !composed.Window.window)
            return;
        // A stroke still under the pointer is not part of the image.
        editor.abandon();
        editor.inkOpen = false;
        owner.saving = true;
        const plan = owner.editPlan;
        const rect = Qt.rect(plan.logical.x, plan.logical.y, plan.logical.width, plan.logical.height);
        // What the thumbnail needs to draw this capture: the screen it was taken
        // on and the saved size in physical pixels.
        const info = { screen: screen.name, width: plan.crop.width, height: plan.crop.height, dpr: dpr };
        if (kind === "copy")
            saveToClipboard(rect, info);
        else
            saveToFile(rect, owner.saveRoot + "/Screenshots", true, info);
    }

    function saveToClipboard(rect: rect, info: var): void {
        // A hand-over file of its own, named by the plugin. The owner
        // deletes it as soon as the clipboard call returns, and when the save is
        // cancelled or invalidated.
        const o = owner;
        const session = o.session;
        const path = o.beginClipboard();
        if (!path) {
            o.saveFailed(session, Tr.tr("The image could not be saved."));
            return;
        }
        CUtils.saveItem(composed, FileUrls.fromLocalPath(path), rect, saved => o.copyFinished(session, saved, info),
            () => o.saveFailed(session, Tr.tr("The image could not be saved.")));
    }

    // Screenshots, then Pictures when that folder cannot be created or written.
    function saveToFile(rect: rect, directory: string, firstTry: bool, info: var): void {
        const o = owner;
        const session = o.session;
        const stem = Logic.fileStem(new Date(), "");
        const path = Logic.uniquePath(directory, stem, candidate => WindowsFiles.isFile(candidate));
        CUtils.saveItem(composed, FileUrls.fromLocalPath(path), rect, saved => o.fileFinished(session, saved, info), () => {
            if (session !== o.session)
                return;
            if (firstTry)
                root.saveToFile(rect, o.saveRoot, false, info);
            else
                o.saveFailed(session, Tr.tr("The image could not be saved."));
        });
    }

    objectName: "areaPicker"
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: owner.editing ? Qt.ArrowCursor : Qt.CrossCursor
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    focus: true
    opacity: owner.closing ? 0 : 1

    Component.onCompleted: {
        windows = Logic.screenWindows(owner.stack, geometry);
        clearSelection();
        forceActiveFocus();
    }

    onHasContentChanged: owner.noteContent(screen.name, hasContent)

    // A pointer that is already on the screen when the last frame arrives shows
    // its target at once, without waiting for a move.
    Connections {
        target: root.owner

        function onAllReadyChanged(): void {
            if (root.owner.allReady && root.containsMouse && !root.down)
                root.hover(root.mouseX, root.mouseY);
        }
    }

    // The pointer handlers delegate to these functions so the fixture can drive
    // the same logic without synthesising window input.
    function pressAt(button: int, x: real, y: real): void {
        if (owner.editing) {
            // The editor's own surfaces take their presses before this one. A left
            // press that gets here is outside the selection and the toolbar: it
            // closes an open popover, and otherwise ends the editor. A right
            // press does nothing. It is for the eraser, which comes later.
            if (button === Qt.LeftButton && !owner.saving && !owner.closing)
                owner.dismiss();
            return;
        }
        if (button === Qt.RightButton) {
            owner.cancel();
            return;
        }
        if (owner.saving || owner.closing || !owner.allReady)
            return;
        down = true;
        startX = x;
        startY = y;
        dragging = false;
    }

    function moveTo(x: real, y: real): void {
        if (owner.editing || owner.saving || owner.closing || !owner.allReady)
            return;
        if (down) {
            if (!dragging && Logic.isDrag(startX, startY, x, y))
                dragging = true;
            if (dragging) {
                lastX = x;
                lastY = y;
                select(Logic.spanRect(startX, startY, x, y, geometry));
            }
        } else {
            hover(x, y);
        }
    }

    function releaseAt(button: int, x: real, y: real): void {
        if (button !== Qt.LeftButton)
            return;
        const wasDown = down;
        down = false;
        if (!wasDown || owner.editing || owner.saving || owner.closing || !owner.allReady)
            return;
        beginEdit(targetForRelease(x, y));
    }

    onPressed: mouse => pressAt(mouse.button, mouse.x, mouse.y)
    onPositionChanged: mouse => moveTo(mouse.x, mouse.y)
    onReleased: mouse => releaseAt(mouse.button, mouse.x, mouse.y)

    onExited: {
        if (!down && !owner.saving)
            clearSelection();
    }

    function dismissByKey(): void {
        owner.dismiss();
    }

    Keys.onEscapePressed: dismissByKey()

    // The editor's shortcuts work from whichever screen's window has the focus.
    Keys.onPressed: event => {
        const modifiers = event.modifiers;
        if (owner.editorKey(event.key, !!(modifiers & Qt.ControlModifier), !!(modifiers & Qt.ShiftModifier), !!(modifiers & Qt.AltModifier)))
            event.accepted = true;
    }

    // What gets exported: the frozen desktop and the annotations over it, and
    // nothing else. The tint, the wash and the toolbar are siblings of this item.
    Item {
        id: composed

        objectName: "areaPickerComposed"
        anchors.fill: parent

        // The frozen desktop. It is never hidden: a Windows ScreencopyView does
        // not start capturing while invisible. It sits outside the fading
        // overlay, so the freeze appears at once and only the tint fades in.
        ScreencopyView {
            id: view

            objectName: "areaPickerView"
            anchors.fill: parent
            captureSource: root.screen
            live: false
        }

        Annotations {
            objectName: "areaPickerAnnotations"
            visible: root.editsHere
            x: root.editRegion.x
            y: root.editRegion.y
            width: root.editRegion.width
            height: root.editRegion.height
            strokes: root.editor.strokes
            draft: root.editor.draft
            revision: root.editor.revision
        }
    }

    Item {
        id: overlay

        objectName: "areaPickerOverlay"
        anchors.fill: parent
        opacity: root.owner.allReady && !root.owner.editing ? 1 : 0
        visible: opacity > 0

        StyledRect {
            id: tint

            objectName: "areaPickerTint"
            anchors.fill: parent
            color: Colours.palette.m3surfaceContainerHighest
            opacity: 0.3

            layer.enabled: true
            layer.effect: Mask {
                maskSource: selectionWrapper
                maskInverted: true
            }
        }

        Item {
            id: selectionWrapper

            anchors.fill: parent
            layer.enabled: true
            visible: false

            Rectangle {
                id: selectionRect

                x: root.rsx
                y: root.rsy
                implicitWidth: root.sw
                implicitHeight: root.sh
            }
        }

        Rectangle {
            id: border

            objectName: "areaPickerOutline"
            visible: root.showSelection && root.sw > 0 && root.sh > 0
            color: "transparent"
            border.width: root.borderWidth
            border.color: Colours.palette.m3primary

            x: selectionRect.x - root.borderWidth
            y: selectionRect.y - root.borderWidth
            implicitWidth: selectionRect.implicitWidth + root.borderWidth * 2
            implicitHeight: selectionRect.implicitHeight + root.borderWidth * 2

            Behavior on border.color {
                CAnim {}
            }
        }

        Behavior on opacity {
            Anim {
                type: Anim.Standard
            }
        }
    }

    // The other screens go dark while the editor is open, as the classic tool's
    // does, and a press on them ends it.
    Rectangle {
        objectName: "captureEditorOtherWash"
        anchors.fill: parent
        color: Qt.rgba(0, 0, 0, 0.55)
        opacity: root.owner.editing && !root.editsHere ? 1 : 0
        visible: opacity > 0

        Behavior on opacity {
            Anim {
                type: Anim.Standard
            }
        }
    }

    Loader {
        anchors.fill: parent
        active: root.editsHere

        sourceComponent: Editor {
            editor: root.editor
            region: root.editRegion
            backdrop: view
            busy: root.owner.saving
            onCopyRequested: root.exportEdit("copy")
            onSaveRequested: root.exportEdit("save")
            onCloseRequested: root.owner.cancel()
        }
    }

    Behavior on opacity {
        Anim {
            id: closeFade

            type: Anim.Standard

            onRunningChanged: {
                if (!running && root.owner.closing)
                    root.owner.finishClose();
            }
        }
    }

    // With animations off nothing runs, so close at once.
    onOpacityChanged: {
        if (opacity === 0 && owner.closing && !closeFade.running)
            owner.finishClose();
    }

    Behavior on rsx {
        enabled: !root.down

        Anim {
            type: Anim.FastSpatial
        }
    }

    Behavior on rsy {
        enabled: !root.down

        Anim {
            type: Anim.FastSpatial
        }
    }

    Behavior on sw {
        enabled: !root.down

        Anim {
            type: Anim.FastSpatial
        }
    }

    Behavior on sh {
        enabled: !root.down

        Anim {
            type: Anim.FastSpatial
        }
    }
}
