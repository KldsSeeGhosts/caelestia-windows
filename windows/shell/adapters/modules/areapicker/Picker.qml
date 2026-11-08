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
// - Output is saved with CUtils.saveItem over the frozen view, then written to
//   Pictures\Screenshots or copied with Clipboard.copyImageFile.
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
    readonly property bool showSelection: owner.allReady && (containsMouse || down || owner.saving)

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

    // Cut the selection out of the frozen view. saveItem grabs `view` itself, so
    // the tint, the outline and any fade are never part of the image. Results go
    // to the owner with this session's number, so a result that arrives after the
    // picker has closed is ignored. Callbacks use `o`, never `root`, because this
    // item may be gone by then.
    function save(selection: var): void {
        // Nothing to cut from until the view is in a window.
        if (owner.saving || !view.Window.window)
            return;
        const plan = Logic.exportPlan(selection, geometry, dpr);
        if (!plan.valid)
            return;
        owner.saving = true;
        select(plan.logical);
        const rect = Qt.rect(plan.logical.x, plan.logical.y, plan.logical.width, plan.logical.height);
        if (owner.clipboardOnly)
            saveToClipboard(rect);
        else
            saveToFile(rect, owner.saveRoot + "/Screenshots", true);
    }

    function saveToClipboard(rect: rect): void {
        // One fixed temporary file under the shell state folder. The owner
        // deletes it as soon as the clipboard call returns, and on every close.
        const o = owner;
        const session = o.session;
        CUtils.saveItem(view, FileUrls.fromLocalPath(o.tempPath()), rect, saved => o.copyFinished(session, saved),
            () => o.saveFailed(session, Tr.tr("The image could not be saved.")));
    }

    // Screenshots, then Pictures when that folder cannot be created or written.
    function saveToFile(rect: rect, directory: string, firstTry: bool): void {
        const o = owner;
        const session = o.session;
        const stem = Logic.fileStem(new Date(), "");
        const path = Logic.uniquePath(directory, stem, candidate => WindowsFiles.isFile(candidate));
        CUtils.saveItem(view, FileUrls.fromLocalPath(path), rect, saved => o.fileFinished(session, saved), () => {
            if (session !== o.session)
                return;
            if (firstTry)
                root.saveToFile(rect, o.saveRoot, false);
            else
                o.saveFailed(session, Tr.tr("The image could not be saved."));
        });
    }

    objectName: "areaPicker"
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.CrossCursor
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
        if (button === Qt.RightButton) {
            owner.cancel();
            return;
        }
        if (owner.saving || !owner.allReady)
            return;
        down = true;
        startX = x;
        startY = y;
        dragging = false;
    }

    function moveTo(x: real, y: real): void {
        if (owner.saving || !owner.allReady)
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
        if (!wasDown || owner.saving || !owner.allReady)
            return;
        save(targetForRelease(x, y));
    }

    onPressed: mouse => pressAt(mouse.button, mouse.x, mouse.y)
    onPositionChanged: mouse => moveTo(mouse.x, mouse.y)
    onReleased: mouse => releaseAt(mouse.button, mouse.x, mouse.y)

    onExited: {
        if (!down && !owner.saving)
            clearSelection();
    }

    function dismissByKey(): void {
        owner.cancel();
    }

    Keys.onEscapePressed: dismissByKey()

    // The frozen desktop. It is never hidden: a Windows ScreencopyView does not
    // start capturing while invisible. It sits outside the fading overlay, so the
    // freeze appears at once and only the tint fades in.
    ScreencopyView {
        id: view

        objectName: "areaPickerView"
        anchors.fill: parent
        captureSource: root.screen
        live: false
    }

    Item {
        id: overlay

        objectName: "areaPickerOverlay"
        anchors.fill: parent
        opacity: root.owner.allReady ? 1 : 0
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
