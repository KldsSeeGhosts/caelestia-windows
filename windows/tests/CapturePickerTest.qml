import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import Caelestia
import Caelestia.Config
import Caelestia.Windows
import qs.services
import qs.modules.areapicker

// The screenshot routing and the QML picker, offscreen. No real capture, no
// clipboard and no user folder is touched: Glazier is replaced by a recorder,
// files go to a folder in the disposable profile, and readiness of the frozen
// frames is reported by hand because an offscreen screen has nothing to copy.
ShellRoot {
    id: root

    property int assertions: 0
    property int classicCalls: 0
    property int dismissCalls: 0
    property bool surfacesHiddenNow: true
    property string saveRoot: (Quickshell.env("CAELESTIA_STATE_DIR") || "").replace(/\\/g, "/") + "/picker-test"
    property string savedPath: ""
    // Hand-over files live in the OS temp directory. The fixture runner points
    // TEMP and TMP at a disposable folder, so nothing lands in the real one.
    property string tempFolder: (Quickshell.env("TEMP") || "").split("\\").join("/")
    property string stateFolder: (Quickshell.env("CAELESTIA_STATE_DIR") || "").split("\\").join("/")

    property QtObject glazier: QtObject {
        property bool ready: true
        property string executable: "C:/Caelestia/caelestia-capture.exe"
        property int hiddenTimeout: 2000
        function capture(): bool {
            root.classicCalls++;
            return true;
        }
        function dismiss(): void { root.dismissCalls++; }
        function surfacesHidden(): bool { return root.surfacesHiddenNow; }
    }

    // Records the clipboard writes. The real clipboard is never touched.
    property QtObject clipboardRecorder: QtObject {
        property var copied: []
        property bool result: true
        // What the file held at the moment of the call: the backend reads it
        // before copyImageFile returns, so it must exist and be readable then.
        property bool existedAtCall: false
        property size sizeAtCall: Qt.size(0, 0)
        function copyImageFile(path: string): bool {
            copied = copied.concat([path]);
            existedAtCall = WindowsFiles.isFile(path);
            shot.source = "file:///" + path.split("\\").join("/");
            sizeAtCall = shot.status === Image.Ready ? shot.sourceSize : Qt.size(0, 0);
            return result;
        }
    }

    // Stands in for Thumbnails.qml and records what the picker hands it.
    property QtObject thumbRecorder: QtObject {
        property bool enabled: true
        property var saved: []
        property var copies: []
        function addSaved(info, path) {
            saved = saved.concat([{ info: info, path: path }]);
            return true;
        }
        function addCopy(info, path) {
            copies = copies.concat([{ info: info, path: path }]);
            return true;
        }
    }

    AreaPicker {
        id: picker

        saveRoot: root.saveRoot
        clipboard: root.clipboardRecorder
        thumbnails: root.thumbRecorder
    }

    // Runs a PowerShell command to set up a disposable file system state that
    // QML cannot create (an old modification time, a junction). It only touches
    // paths inside the fixture's temporary profile.
    Process {
        id: shell

        property var done: null
        onExited: code => {
            const callback = done;
            done = null;
            if (callback)
                root.step(() => callback(code));
        }
    }

    Component {
        id: extraPicker

        AreaPicker {}
    }

    Image {
        id: shot

        asynchronous: false
        cache: false
        visible: false
    }

    Timer {
        id: timer

        property var next: null
        onTriggered: root.step(next)
    }

    function check(value, description): void {
        assertions++;
        if (!value)
            throw new Error(description);
    }

    function step(body): void {
        try {
            body();
        } catch (error) {
            console.error("CAELESTIA_CAPTURE_PICKER_FAIL " + error);
            Qt.exit(1);
        }
    }

    function later(milliseconds, body): void {
        timer.next = body;
        timer.interval = milliseconds;
        timer.restart();
    }

    function find(item, name): var {
        if (!item)
            return null;
        if (item.objectName === name)
            return item;
        for (const child of item.children) {
            const found = find(child, name);
            if (found)
                return found;
        }
        return null;
    }

    function findAll(item, name): var {
        let list = [];
        if (!item)
            return list;
        if (item.objectName === name)
            list.push(item);
        for (const child of item.children)
            list = list.concat(findAll(child, name));
        return list;
    }

    function windows(): var {
        return Array.from(picker.windows).filter(window => window);
    }

    function areaOf(window): var {
        return find(window.contentItem, "areaPicker");
    }

    function readyAll(): void {
        for (const screen of Quickshell.screens)
            picker.noteContent(screen.name, true);
    }

    function powershell(script, callback): void {
        shell.done = callback;
        shell.command = [Quickshell.env("SystemRoot") + "\\System32\\WindowsPowerShell\\v1.0\\powershell.exe",
            "-NoProfile", "-NonInteractive", "-Command", script];
        shell.running = true;
    }

    function inTemp(path): bool {
        return root.tempFolder !== "" && path.toLowerCase().indexOf(root.tempFolder.toLowerCase() + "/") === 0
            && path.indexOf("/", root.tempFolder.length + 1) < 0;
    }

    function winPath(path): string {
        return path.split("/").join("\\");
    }

    function toastCount(part): int {
        const toasts = Toaster.toasts;
        let count = 0;
        for (let i = 0; i < toasts.length; i++) {
            if (toasts[i].message.indexOf(part) >= 0)
                count++;
        }
        return count;
    }

    function fileUrl(path): string {
        return "file:///" + path;
    }

    // The text of the toast that contains `part`, or "". Toast order is not
    // part of the contract, so every open toast is searched.
    function toastWith(part): string {
        const toasts = Toaster.toasts;
        for (let i = 0; i < toasts.length; i++) {
            if (toasts[i].message.indexOf(part) >= 0)
                return toasts[i].message;
        }
        return "";
    }

    Component.onCompleted: Qt.callLater(() => step(routing))

    function routing(): void {
        CaptureUi.glazierProvider = glazier;
        check(CaptureUi.picker === picker, "the picker registers itself with the router");
        check(Quickshell.screens.length > 0, "the fixture has a screen");

        // Classic is the default and behaves as before: one call, no picker.
        GlobalConfig.windows = {};
        check(CaptureUi.setting === "classic" && CaptureUi.route === "classic", "no setting means classic");
        check(CaptureUi.screenshot("open") === true && classicCalls === 1, "classic opens the existing tool");
        check(!picker.opened && dismissCalls === 0, "classic never touches the picker or dismisses panels itself");
        for (const name of ["openFreeze", "openClip", "openFreezeClip"])
            CaptureUi.screenshot(name);
        check(classicCalls === 4, "every upstream picker name reaches the classic tool");

        GlobalConfig.windows = { capture: { ui: "classic" } };
        check(CaptureUi.route === "classic", "an explicit classic setting");
        for (const value of ["Shell", "", 1, true, null]) {
            GlobalConfig.windows = { capture: { ui: value } };
            check(CaptureUi.route === "classic", "an unknown setting falls back to classic: " + value);
        }
        classicCalls = 0;

        // A legacy glazier.exe override always stays classic.
        GlobalConfig.windows = { capture: { ui: "shell" } };
        glazier.executable = "C:/Apps/Glazier/glazier.exe";
        check(CaptureUi.route === "classic", "shell with a legacy override stays classic");
        CaptureUi.screenshot("open");
        check(classicCalls === 1 && !picker.opened, "the legacy override gets the classic tool");

        // Until Glazier has read its override file the press is not guessed.
        glazier.executable = "C:/Caelestia/caelestia-capture.exe";
        glazier.ready = false;
        check(CaptureUi.route === "classic", "an unread override file means classic");
        glazier.ready = true;

        // The bundled helper, or none, with the shell setting opens the picker.
        check(CaptureUi.route === "shell", "shell with the bundled helper routes to the picker");
        check(CaptureUi.shellAvailable, "the picker is available");
        check(CaptureUi.screenshot("bogus") === false, "an unknown picker name is refused");

        // Panels are dismissed first. The picker waits until they are hidden.
        classicCalls = 0;
        surfacesHiddenNow = false;
        check(CaptureUi.screenshot("openFreeze") === true, "the shell route accepts a request");
        check(dismissCalls === 1 && !picker.opened, "panels are dismissed and the picker waits for them");
        check(CaptureUi.screenshot("open") === true && dismissCalls === 1, "a second request while waiting is absorbed");
        check(classicCalls === 0, "the shell route never starts the classic tool");
        surfacesHiddenNow = true;
        later(300, () => step(openedStep));
    }

    function openedStep(): void {
        check(picker.opened, "the picker opens once the panels are hidden");
        const list = windows();
        check(list.length === Quickshell.screens.length, "one picker window per screen");
        for (const window of list) {
            check(window.screen !== null && Quickshell.screens.some(s => s.name === window.screen.name), "each window has its own screen");
            check(window.WlrLayershell.layer === WlrLayer.Overlay, "overlay layer");
            check(window.exclusionMode === ExclusionMode.Ignore, "reserves no space");
            check(window.WlrLayershell.keyboardFocus === WlrKeyboardFocus.Exclusive, "exclusive keyboard focus while open");
            check(window.excludeFromCapture === true, "excluded from capture");
            check(window.anchors.left && window.anchors.right && window.anchors.top && window.anchors.bottom, "covers its screen");
            const view = find(window.contentItem, "areaPickerView");
            check(view !== null && view.live === false, "a non-live ScreencopyView");
            check(view.visible, "the frozen view is never hidden");
            check(view.captureSource === window.screen, "the view captures this window's screen");
            const overlay = find(window.contentItem, "areaPickerOverlay");
            check(overlay !== null && !overlay.visible, "the tint stays hidden until every screen has content");
        }
        check(!picker.allReady, "not ready before any frame");
        check(CaptureUi.screenshot("open") === true && windows().length === list.length, "a request while open does not add windows");

        // The tint waits for the last screen.
        const names = Quickshell.screens.map(s => s.name);
        for (let i = 0; i < names.length - 1; i++)
            picker.noteContent(names[i], true);
        check(!picker.allReady || names.length === 1, "one screen short is not ready");
        if (names.length > 1)
            check(!find(windows()[0].contentItem, "areaPickerOverlay").visible, "the tint is still hidden one screen short");
        readyAll();
        check(picker.allReady, "ready once every screen has content");
        later(600, () => step(pointerStep));
    }

    function pointerStep(): void {
        for (const window of windows()) {
            const overlay = find(window.contentItem, "areaPickerOverlay");
            check(overlay.visible, "the tint shows once every screen is ready");
        }
        const window = windows()[0];
        const area = areaOf(window);
        const tint = find(window.contentItem, "areaPickerTint");
        const outline = find(window.contentItem, "areaPickerOutline");
        check(tint !== null && Math.abs(tint.opacity - 0.3) < 1e-6, "30 percent tint");
        check(outline !== null && outline.border.width === 2, "2 px outline");
        check(area.cursorShape === Qt.CrossCursor, "cross cursor");
        // An offscreen pointer may already count as inside, in which case the
        // whole monitor is its target; otherwise there is no target yet.
        check(area.containsMouse || (area.sw === 0 && !outline.visible), "no target before the pointer arrives");

        // Hit testing against a known stack, top-down, then the monitor.
        area.windows = [
            { id: "front", title: "", rect: { x: 100, y: 100, width: 300, height: 200 } },
            { id: "back", title: "", rect: { x: 50, y: 50, width: 500, height: 400 } }
        ];
        area.moveTo(150, 150);
        later(500, () => step(() => {
            check(area.rsx === 100 && area.rsy === 100 && area.sw === 300 && area.sh === 200, "the topmost window under the pointer");
            check(outline.visible || !area.containsMouse, "the outline follows the target when the pointer is in");
            area.moveTo(500, 400);
            later(500, () => step(() => backWindow(window, area)));
        }));
    }

    function backWindow(window, area): void {
        check(area.rsx === 50 && area.sw === 500 && area.sh === 400, "the window behind when the front one is not under the pointer");
        area.moveTo(area.width - 1, area.height - 1);
        later(500, () => step(() => {
            check(area.rsx === 0 && area.rsy === 0 && area.sw === area.width && area.sh === area.height,
                "no window under the pointer selects the whole monitor");
            drag(window, area);
        }));
    }

    function drag(window, area): void {
        area.pressAt(Qt.LeftButton, 20, 30);
        area.moveTo(22, 31);
        check(!area.dragging, "a small movement is still a click");
        area.moveTo(80, 70);
        check(area.dragging, "a larger movement starts a drag");
        check(area.rsx === 20 && area.rsy === 30 && area.sw === 60 && area.sh === 40, "a drag selects its rectangle at once");
        area.moveTo(5, 10);
        check(area.rsx === 5 && area.rsy === 10 && area.sw === 15 && area.sh === 20, "a drag may go up and left");
        area.moveTo(80, 70);
        // Releasing opens the editor over the selection. Nothing is saved.
        area.releaseAt(Qt.LeftButton, 80, 70);
        check(picker.editing && !picker.saving, "release opens the editor and starts no save");
        check(picker.editScreen === window.screen.name && picker.editPicker === area, "on the screen of the selection");
        const logical = picker.editPlan.logical;
        check(logical.x === 20 && logical.y === 30 && logical.width === 60 && logical.height === 40, "with the selection as its region");
        later(800, () => step(() => noAutoSave(window, area)));
    }

    // The screenshots folder is written only when the user chooses Save.
    function noAutoSave(window, area): void {
        check(picker.opened && picker.editing && !picker.saving && !picker.closing, "the editor stays open after the selection");
        check(toastWith("Saved to") === "" && toastWith("Screenshot taken") === "" && toastWith("Copying screenshot") === "",
            "and no success toast was shown");
        check(thumbRecorder.saved.length === 0 && thumbRecorder.copies.length === 0 && clipboardRecorder.copied.length === 0,
            "nothing reached the thumbnail or the clipboard");
        powershell("if (Test-Path -LiteralPath '" + winPath(root.saveRoot) + "') { exit 1 } else { exit 0 }", code => {
            check(code === 0, "nothing was written: the save folder does not exist");
            editorLook(window, area);
        });
    }

    function editorLook(window, area): void {
        const editorItem = find(window.contentItem, "captureEditor");
        check(editorItem !== null && editorItem.visible, "the editor interface is loaded on the selection's screen");
        check(find(window.contentItem, "areaPickerOverlay").visible === false || find(window.contentItem, "areaPickerOverlay").opacity < 1,
            "the picker's tint is on its way out");
        check(area.cursorShape === Qt.ArrowCursor, "no cross cursor outside the drawing surface");
        check(!area.showSelection, "the picker's outline is gone");
        const composed = find(window.contentItem, "areaPickerComposed");
        check(composed !== null && find(composed, "areaPickerView") !== null && find(composed, "areaPickerAnnotations") !== null,
            "the exported item holds the frozen frame and the annotation layer");
        check(find(composed, "editorToolbar") === null && find(composed, "captureEditor") === null && find(composed, "areaPickerTint") === null,
            "and neither the toolbar, the wash nor the tint");
        const annotations = find(composed, "areaPickerAnnotations");
        check(annotations.visible && annotations.clip && annotations.x === 20 && annotations.y === 30
            && annotations.width === 60 && annotations.height === 40, "the annotation layer is the selection, clipped to it");
        check(findAll(editorItem, "captureEditorWash").length === 4, "four washes around the selection");
        for (const wash of findAll(editorItem, "captureEditorWash"))
            check(Math.abs(wash.color.a - 0.55) < 0.01 && wash.color.r === 0, "55 percent black");
        const canvas = find(editorItem, "captureEditorCanvas");
        check(canvas.x === 20 && canvas.y === 30 && canvas.width === 60 && canvas.height === 40, "the drawing surface covers the selection");
        check(canvas.cursorShape === Qt.CrossCursor, "with a cross cursor");

        // Geometry of the bar: 44 px tall, 10 px below the selection, kept 6 px from the left edge.
        const bar = find(editorItem, "editorToolbar");
        check(bar.height === 44, "the toolbar is 44 px tall");
        check(bar.y === 80 && bar.x === 6, "10 px below the selection and 6 px from the edge: " + bar.x + ", " + bar.y);
        check(bar.width > 500, "wide enough for every item: " + bar.width);
        for (const id of ["pencil", "highlighter", "line", "arrow", "rect", "circle"]) {
            const button = find(bar, "editorTool-" + id);
            check(button !== null && button.width === 30 && button.height === 30, "a 30 px button for " + id);
        }
        for (const name of ["editorColor", "editor-undo", "editor-redo", "editor-clear", "editor-save", "editor-copy", "editor-close"])
            check(find(bar, name) !== null && find(bar, name).height === 30, "the " + name + " button");
        check(find(bar, "editor-copy").width > 30, "Copy has a label");
        check(find(bar, "editorTool-text") === null && find(bar, "editorTool-blur") === null, "no tool from a later part");
        check(find(bar, "editor-undo").disabled && find(bar, "editor-redo").disabled, "undo and redo are off with nothing drawn");
        later(100, () => step(() => toolsStep(window, area)));
    }

    function toolsStep(window, area): void {
        const editor = picker.editor;
        const bar = find(window.contentItem, "editorToolbar");
        check(editor.tool === "pencil" && editor.color === "#FF4444" && editor.size === 3, "Pencil, red, 3 px to begin with");

        // Each button picks its tool, and so does its key.
        for (const id of ["highlighter", "line", "arrow", "rect", "circle", "pencil"]) {
            find(bar, "editorTool-" + id).clicked();
            check(editor.tool === id, "the " + id + " button picks " + id);
        }
        const keys = { H: "highlighter", L: "line", A: "arrow", R: "rect", C: "circle", P: "pencil" };
        for (const letter of Object.keys(keys)) {
            check(picker.editorKey(letter.charCodeAt(0), false, false, false) && editor.tool === keys[letter], "the key " + letter + " picks " + keys[letter]);
        }
        check(picker.editorKey(0x54, false, false, false) === false && editor.tool === "pencil", "T is not a tool in this part");

        // Draw with every tool, in region coordinates.
        const drawings = {
            pencil: [[5, 5], [12, 9], [20, 14], [30, 12], [40, 6]],
            highlighter: [[5, 30], [25, 32], [45, 30]],
            line: [[5, 5], [55, 35]],
            arrow: [[10, 35], [50, 8]],
            rect: [[8, 8], [40, 30]],
            circle: [[30, 20], [45, 28]]
        };
        for (const id of Object.keys(drawings)) {
            editor.setTool(id);
            const points = drawings[id];
            editor.pressAt(points[0][0], points[0][1]);
            check(editor.drawing, "a press starts a " + id + " stroke");
            for (let i = 1; i < points.length; i++)
                editor.moveTo(points[i][0], points[i][1]);
            editor.releaseAt();
            check(!editor.drawing, "a release ends it");
        }
        check(editor.strokes.length === 6, "six strokes: " + editor.strokes.length);
        check(editor.strokes.map(s => s.tool).join() === "pencil,highlighter,line,arrow,rect,circle", "in drawing order");
        const annotations = find(window.contentItem, "areaPickerAnnotations");
        const kinds = findAll(annotations, "annotationPrimitive");
        check(kinds.length >= 7, "the layer draws them as Shapes: " + kinds.length);

        // A shape that was never dragged is not kept.
        editor.setTool("line");
        editor.pressAt(3, 3);
        editor.releaseAt();
        check(editor.strokes.length === 6, "a click with a shape tool adds nothing");

        // Undo and redo, by button and by key.
        check(!find(bar, "editor-undo").disabled && find(bar, "editor-redo").disabled, "undo is on, redo is off");
        find(bar, "editor-undo").clicked();
        check(editor.strokes.length === 5 && editor.canRedo && !find(bar, "editor-redo").disabled, "undo takes the last stroke off");
        find(bar, "editor-redo").clicked();
        check(editor.strokes.length === 6 && !editor.canRedo, "redo puts it back");
        check(picker.editorKey(0x5A, true, false, false) && editor.strokes.length === 5, "Ctrl+Z undoes");
        check(picker.editorKey(0x5A, true, true, false) && editor.strokes.length === 6, "Ctrl+Shift+Z redoes");
        check(picker.editorKey(0x5A, true, false, false) && picker.editorKey(0x5A, true, false, false) && editor.strokes.length === 4, "two more undos");
        check(picker.editorKey(0x59, true, false, false) && editor.strokes.length === 5, "Ctrl+Y redoes");
        editor.setTool("rect");
        editor.pressAt(2, 2);
        editor.moveTo(20, 20);
        editor.releaseAt();
        check(editor.strokes.length === 6 && !editor.canRedo, "a new stroke empties the redo stack");
        check(editor.strokes[5].tool === "rect" && editor.strokes[3].tool === "arrow", "the new rectangle is last, after the arrow and the first rectangle");

        // Keys are ignored while a stroke is being drawn.
        editor.pressAt(1, 1);
        check(picker.editorKey(0x5A, true, false, false) === false && editor.strokes.length === 6, "no undo mid stroke");
        editor.abandon();
        check(!editor.drawing && editor.strokes.length === 6, "an abandoned stroke is dropped, not committed");
        later(100, () => step(() => clearStep(window, area)));
    }

    function clearStep(window, area): void {
        const editor = picker.editor;
        const bar = find(window.contentItem, "editorToolbar");
        const clear = find(bar, "editor-clear");
        const width = clear.width;
        clear.clicked();
        check(editor.clearArmed && editor.strokes.length === 6, "the first press only arms Clear");
        check(clear.width > width, "the armed button shows its label");
        clear.clicked();
        check(!editor.clearArmed && editor.strokes.length === 0 && !editor.canUndo && !editor.canRedo, "the second clears everything, redo too");

        // Clear disarms by itself, and when the user does something else.
        editor.setTool("line");
        editor.pressAt(5, 5);
        editor.moveTo(30, 30);
        editor.releaseAt();
        clear.clicked();
        check(editor.clearArmed, "armed again");
        editor.setTool("pencil");
        check(!editor.clearArmed, "choosing a tool disarms it");
        clear.clicked();
        check(editor.clearArmed, "armed for the pointer check");
        find(clear, "editor-clear-layer").exited();
        check(!editor.clearArmed && editor.strokes.length === 1, "leaving the button disarms it");
        clear.clicked();
        check(editor.clearArmed, "armed once more");
        later(2800, () => step(() => {
            check(!editor.clearArmed && editor.strokes.length === 1, "it disarms after 2.4 s and keeps the stroke");
            inkStep(window, area);
        }));
    }

    function inkStep(window, area): void {
        const editor = picker.editor;
        const bar = find(window.contentItem, "editorToolbar");
        const popover = find(window.contentItem, "editorInkPopover");
        check(!popover.visible, "the colour popover starts closed");
        find(bar, "editorColor").clicked();
        check(editor.inkOpen && popover.visible, "the colour button opens it");
        check(popover.width === 268 && popover.height === 101, "268 x 101");
        check(popover.y === bar.y - 8 - popover.height || popover.y === bar.y + bar.height + 8, "8 px above or below the bar");
        for (let i = 0; i < 9; i++)
            check(find(popover, "editorColor-" + i) !== null, "colour " + i);
        check(find(popover, "editorColor-9") === null, "nine colours");
        find(popover, "editorColor-4").clicked(null);
        check(editor.color === "#44AAFF", "a colour dot picks it");
        find(popover, "editorSize-M").clicked(null);
        check(editor.size === 4, "M is 4 px");
        find(popover, "editorSize-L").clicked(null);
        find(popover, "editorSize-S").clicked(null);
        check(editor.size === 2 && editor.inkOpen, "S is 2 px, and the popover stays open");

        // Esc closes the popover first and the editor second.
        area.dismissByKey();
        check(!editor.inkOpen && !picker.closing && picker.editing, "Esc closes the popover only");
        find(bar, "editorColor").clicked();
        check(editor.inkOpen, "open again");
        editor.pressAt(10, 10);
        check(!editor.inkOpen, "pressing the drawing surface closes it");
        editor.abandon();

        // Dragging the bar moves it, and it stays on the screen.
        editor.barPosition = { x: -500, y: 90000 };
        check(bar.x === 6 && bar.y === window.height - 44 - 6, "a dragged bar keeps 6 px from the edges: " + bar.x + ", " + bar.y);
        editor.barPosition = { x: 100, y: 200 };
        check(bar.x === 100 && bar.y === 200, "and goes where it was put");
        editor.barPosition = null;
        check(bar.x === 6 && bar.y === 80, "automatic placement returns");

        // A right press does nothing in the editor. A left press outside the
        // selection and the bar closes it.
        area.pressAt(Qt.RightButton, window.width - 50, window.height - 50);
        check(!picker.closing && picker.editing, "a right press does not close the editor");
        area.moveTo(100, 100);
        check(area.rsx === 20 && area.sw === 60, "moving the pointer does not retarget the selection");
        later(100, () => step(() => saveStep(window, area)));
    }

    // Save writes one file with the annotations in it.
    function saveStep(window, area): void {
        const editor = picker.editor;
        const bar = find(window.contentItem, "editorToolbar");
        editor.setColor(0);
        editor.setSize(2);
        editor.setTool("line");
        editor.pressAt(5, 20);
        editor.moveTo(55, 20);
        editor.releaseAt();
        check(editor.strokes.length === 2, "a thick red line is added");
        find(bar, "editor-save").clicked();
        check(picker.saving, "Save starts the export");
        check(find(window.contentItem, "captureEditor").busy, "and the editor is busy");
        const screenName = window.screen.name;
        later(1500, () => step(() => savedStep(screenName)));
    }

    function savedStep(screenName): void {
        check(toastWith("Saved to") === "" && toastWith("Screenshot taken") === "", "no success toast");
        check(thumbRecorder.saved.length === 1 && thumbRecorder.copies.length === 0, "the thumbnail was given the saved file");
        savedPath = thumbRecorder.saved[0].path;
        const info = thumbRecorder.saved[0].info;
        check(info.screen === screenName && info.width === 60 && info.height === 40 && info.dpr === 1, "with the capture's screen and size");
        check(savedPath.indexOf("/Screenshots/annotate-") >= 0 && savedPath.endsWith(".png"), "saved under Screenshots with the default name: " + savedPath);
        check(WindowsFiles.isFile(savedPath), "the file exists: " + savedPath);
        shot.source = "file:///" + savedPath;
        check(shot.status === Image.Ready, "the file is a readable image");
        check(shot.sourceSize.width === 60 && shot.sourceSize.height === 40, "the image has the selection's size: " + shot.sourceSize);
        shot.source = "";
        check(clipboardRecorder.copied.length === 0, "Save does not touch the clipboard");
        check(!picker.opened, "Save closes the editor");
        check(windows().length === 0, "its windows are gone");
        // The line is in the file: red at its middle, and the pixel above it is
        // empty because the layer holds only the annotations over an empty frame.
        const script = "$ErrorActionPreference='Stop'; Add-Type -AssemblyName System.Drawing; "
            + "$b = New-Object System.Drawing.Bitmap('" + savedPath + "'); "
            + "$line = $b.GetPixel(30, 20); $above = $b.GetPixel(30, 8); $b.Dispose(); "
            + "if ($line.R -eq 255 -and $line.G -eq 68 -and $line.B -eq 68 -and $line.A -eq 255 -and $above.A -eq 0) { exit 0 } "
            + "else { [Console]::Error.WriteLine('line=' + $line + ' above=' + $above); exit 3 }";
        powershell(script, code => {
            check(code === 0, "the annotation is drawn into the saved image at native scale (exit " + code + ")");
            countScreenshots();
        });
    }

    function countScreenshots(): void {
        powershell("$n = @(Get-ChildItem -LiteralPath '" + winPath(root.saveRoot) + "/Screenshots' -File).Count; exit $n", code => {
            check(code === 1, "Save wrote exactly one file: " + code);
            escapeStep();
        });
    }

    function escapeStep(): void {
        surfacesHiddenNow = true;
        check(CaptureUi.screenshot("open") === true && picker.opened, "the picker opens again");
        check(windows().length === Quickshell.screens.length, "one window per screen again");
        readyAll();
        const list = windows();
        areaOf(list[0]).dismissByKey();
        check(picker.closing, "Esc starts closing");
        for (const window of list)
            check(window.WlrLayershell.keyboardFocus === WlrKeyboardFocus.None, "keyboard focus is released while closing");
        later(1200, () => step(afterEscape));
    }

    function afterEscape(): void {
        check(!picker.opened && windows().length === 0, "Esc closes every window");
        check(clipboardRecorder.copied.length === 0, "Esc copies nothing");
        check(CaptureUi.screenshot("open") === true && picker.opened, "and the picker can open once more");
        readyAll();
        const area = areaOf(windows()[0]);
        area.pressAt(Qt.RightButton, 10, 10);
        check(picker.closing, "a right click starts closing");
        later(1200, () => step(afterRightClick));
    }

    function afterRightClick(): void {
        check(!picker.opened && windows().length === 0, "a right click closes every window");

        // openClip opens the same editor as the other names. Copy in the editor
        // writes the image to a temporary file in the OS temp directory and hands
        // that path to the clipboard.
        check(CaptureUi.screenshot("openClip") === true && picker.opened, "openClip opens the picker");
        readyAll();
        later(300, () => step(clipboardDrag));
    }

    // Selects a region and returns the editor's toolbar.
    function selectRegion(x1, y1, x2, y2): var {
        const window = windows()[0];
        const area = areaOf(window);
        area.pressAt(Qt.LeftButton, x1, y1);
        area.moveTo(x2, y2);
        area.releaseAt(Qt.LeftButton, x2, y2);
        check(picker.editing && !picker.saving, "the selection opens the editor and saves nothing");
        return find(window.contentItem, "editorToolbar");
    }

    function clipboardDrag(): void {
        const bar = selectRegion(10, 10, 70, 60);
        check(clipboardRecorder.copied.length === 0 && picker.activeTemp === "", "nothing is copied by the selection");
        picker.editor.setTool("rect");
        picker.editor.pressAt(5, 5);
        picker.editor.moveTo(30, 30);
        picker.editor.releaseAt();
        find(bar, "editor-copy").clicked();
        check(picker.saving, "Copy starts the export");
        later(1200, () => step(afterClipboard));
    }

    function afterClipboard(): void {
        check(clipboardRecorder.copied.length === 1, "the image is handed to the clipboard once");
        const path = clipboardRecorder.copied[0].split("\\").join("/");
        check(inTemp(path) && /\/caelestia-clipboard-[0-9a-f]{32}\.png$/.test(path),
            "from this save's own uniquely named file in the temp directory: " + path);
        check(clipboardRecorder.existedAtCall, "the file existed when the clipboard call ran");
        check(clipboardRecorder.sizeAtCall.width === 60 && clipboardRecorder.sizeAtCall.height === 50,
            "and held the selection: " + clipboardRecorder.sizeAtCall);
        check(!WindowsFiles.isFile(path), "the temporary file is deleted right after the call");
        check(toastWith("Copying screenshot") === "" && toastWith("Screenshot taken") === "" && toastWith("copied to clipboard") === "",
            "no toast: the thumbnail is the feedback");
        check(thumbRecorder.copies.length === 1 && thumbRecorder.copies[0].path === clipboardRecorder.copied[0], "the thumbnail was given the copy");
        check(thumbRecorder.saved.length === 1, "and Copy saved no file");
        check(!picker.opened, "Copy closes the editor");
        shot.source = "";

        // A refused copy reports a failure and still removes the file.
        clipboardRecorder.result = false;
        check(CaptureUi.screenshot("openClip") === true && picker.opened, "openClip opens again");
        readyAll();
        later(300, () => step(copyFailDrag));
    }

    function copyFailDrag(): void {
        const bar = selectRegion(10, 10, 40, 40);
        picker.editor.setTool("circle");
        picker.editor.pressAt(10, 10);
        picker.editor.moveTo(20, 20);
        picker.editor.releaseAt();
        find(bar, "editor-copy").clicked();
        later(1200, () => step(afterCopyFail));
    }

    // A failed export keeps the editor and its annotations, so the user can try
    // again. Only an error toast is shown.
    function afterCopyFail(): void {
        check(clipboardRecorder.copied.length === 2, "the clipboard was asked again");
        check(toastWith("could not be copied") !== "", "a refused copy is reported");
        check(!WindowsFiles.isFile(clipboardRecorder.copied[1].split("\\").join("/")), "and its file is deleted too");
        check(picker.opened && picker.editing && !picker.saving && !picker.closing, "the editor stays open");
        check(picker.editor.strokes.length === 1 && picker.editor.strokes[0].tool === "circle", "with its annotations");
        check(thumbRecorder.copies.length === 1, "and no thumbnail is added for the failed copy");
        clipboardRecorder.result = true;
        const bar = find(windows()[0].contentItem, "editorToolbar");
        find(bar, "editor-copy").clicked();
        later(1200, () => step(() => {
            check(clipboardRecorder.copied.length === 3 && thumbRecorder.copies.length === 2, "trying again copies and adds the thumbnail");
            check(!picker.opened, "and closes the editor");

            // Cancelling removes a leftover hand-over file.
            check(CaptureUi.screenshot("openClip") === true && picker.opened, "openClip opens for the cancel case");
            readyAll();
            later(300, () => step(tempCancelStep));
        }));
    }

    property string leftover: ""

    function tempCancelStep(): void {
        // A save is under way with its own file; Esc invalidates it and removes the file.
        const view = find(windows()[0].contentItem, "areaPickerView");
        leftover = picker.beginClipboard();
        CUtils.saveItem(view, fileUrl(leftover), Qt.rect(0, 0, 4, 4), () => {}, () => {});
        later(500, () => step(() => {
            check(WindowsFiles.isFile(leftover), "a hand-over file exists before the cancel");
            areaOf(windows()[0]).dismissByKey();
            check(picker.activeTemp === "" && !WindowsFiles.isFile(leftover), "Esc deletes it at once, before the fade ends");
            later(1200, () => step(afterTempCancel));
        }));
    }

    function afterTempCancel(): void {
        check(!picker.opened, "Esc closed the picker");
        check(!WindowsFiles.isFile(leftover), "and the file stays deleted");
        check(clipboardRecorder.copied.length === 3, "and copies nothing");

        // A save that cannot write anywhere reports a failure. The save folder
        // is made a path below an existing file, so neither Screenshots nor the
        // folder itself can be created.
        picker.saveRoot = savedPath;
        check(CaptureUi.screenshot("open") === true && picker.opened, "the picker opens for the failing save");
        readyAll();
        later(300, () => step(failingSaveDrag));
    }

    function failingSaveDrag(): void {
        const bar = selectRegion(10, 10, 40, 40);
        find(bar, "editor-save").clicked();
        check(picker.saving, "the failing save starts");
        later(1200, () => step(afterFailingSave));
    }

    function afterFailingSave(): void {
        check(toastWith("The image could not be saved") !== "", "a save that fails is reported");
        check(picker.opened && picker.editing && !picker.saving && !picker.closing, "and the editor stays open for another try");
        check(thumbRecorder.saved.length === 1, "with no thumbnail for it");
        picker.saveRoot = root.saveRoot;
        closePicker(() => {
            // A save that never answers ends in a bounded failure.
            picker.saveTimeout = 300;
            check(CaptureUi.screenshot("open") === true && picker.opened, "the picker opens for the stalled save");
            readyAll();
            later(300, () => step(() => {
                picker.saving = true;
                check(picker.opened, "a save is pending");
                later(1200, () => step(afterStall));
            }));
        });
    }

    function closePicker(next): void {
        picker.cancel();
        later(1200, () => step(() => {
            check(!picker.opened && !picker.editing, "the picker closed: opened=" + picker.opened + " editing=" + picker.editing + " closing=" + picker.closing + " saving=" + picker.saving);
            next();
        }));
    }

    function afterStall(): void {
        check(toastWith("timed out") !== "", "a stalled save shows a failure toast");
        check(picker.opened && !picker.saving, "and the picker stays open");
        closePicker(stalledClosed);
    }

    function stalledClosed(): void {

        // Completion first: the operation is terminal at once, so the timeout
        // that is still counting never fires.
        picker.saveTimeout = 400;
        check(CaptureUi.screenshot("open") === true && picker.opened, "the picker opens for the completion race");
        readyAll();
        later(300, () => step(raceCompletion));
    }

    function raceCompletion(): void {
        const started = picker.session;
        const timeouts = toastCount("timed out");
        picker.saving = true;
        later(150, () => step(() => {
            picker.fileFinished(started, "C:/race/done.png");
            check(!picker.saving && picker.session !== started, "completion invalidates the session and clears saving at once");
            check(toastCount("C:/race/done.png") === 0, "no success toast: the thumbnail is the feedback");
            picker.fileFinished(started, "C:/race/done.png");
            picker.saveFailed(started, "late failure");
            check(toastCount("C:/race/done.png") === 0 && toastWith("late failure") === "", "a second result for the same save is dropped");
            later(900, () => step(() => {
                check(toastCount("timed out") === timeouts, "the timeout never fires after a completion");
                check(!picker.opened, "the picker closed");
                thumbnailOffStep();
            }));
        }));
    }

    // With the thumbnail switched off nothing else would say where a saved file
    // went, so Save announces it, as the classic tool does. Copy never does.
    function thumbnailOffStep(): void {
        check(CaptureUi.screenshot("open") === true && picker.opened, "the picker opens for the thumbnail-off case");
        readyAll();
        later(300, () => step(() => {
            thumbRecorder.enabled = false;
            picker.fileFinished(picker.session, "C:/off/saved.png");
            check(toastCount("Saved to C:/off/saved.png") === 1, "a save with the thumbnail off is announced");
            thumbRecorder.enabled = true;
            later(1200, () => step(() => {
                check(!picker.opened, "and the picker closed");
                raceTimeout();
            }));
        }));
    }

    function raceTimeout(): void {
        // Timeout first: a completion that arrives afterwards is dropped.
        check(CaptureUi.screenshot("open") === true && picker.opened, "the picker opens for the timeout race");
        readyAll();
        later(300, () => step(() => {
            const started = picker.session;
            const timeouts = toastCount("timed out");
            picker.saving = true;
            later(700, () => step(() => {
                check(toastCount("timed out") === timeouts + 1, "the timeout shows once");
                check(picker.session !== started && !picker.saving, "and ends the operation");
                const saved = thumbRecorder.saved.length;
                picker.fileFinished(started, "C:/race/late.png", { screen: "x", width: 1, height: 1, dpr: 1 });
                check(thumbRecorder.saved.length === saved, "a completion after the timeout is dropped");
                check(picker.opened && !picker.closing, "and the editor stays open after the timeout");
                later(900, () => step(() => {
                    check(toastCount("timed out") === timeouts + 1, "and the timeout does not repeat");
                    closePicker(resultAfterEsc);
                }));
            }));
        }));
    }

    function resultAfterEsc(): void {
        // A clipboard save whose write lands after Esc must copy nothing and
        // leave no file.
        const copies = clipboardRecorder.copied.length;
        const toasts = toastCount("Copying screenshot to clipboard");
        check(CaptureUi.screenshot("openClip") === true && picker.opened, "openClip opens for the Esc race");
        readyAll();
        later(300, () => step(() => {
            const started = picker.session;
            const path = picker.beginClipboard();
            const view = find(windows()[0].contentItem, "areaPickerView");
            areaOf(windows()[0]).dismissByKey();
            check(picker.closing && picker.session !== started, "Esc invalidates the save before its write");
            // The grab was requested after Esc and lands in the next frames.
            CUtils.saveItem(view, fileUrl(path), Qt.rect(0, 0, 4, 4), saved => picker.copyFinished(started, saved), () => {});
            later(900, () => step(() => {
                check(clipboardRecorder.copied.length === copies, "a result after Esc does not copy");
                check(toastCount("Copying screenshot to clipboard") === toasts, "and shows no toast");
                check(!WindowsFiles.isFile(path), "and its late file is deleted by the late callback");
                check(!picker.opened, "the picker closed");
                overlapStep();
            }));
        }));
    }

    function overlapStep(): void {
        // Save A is cancelled, save B begins. A's late result must delete only
        // A's file.
        check(CaptureUi.screenshot("openClip") === true && picker.opened, "openClip opens for the overlap");
        readyAll();
        later(300, () => step(() => {
            const copies = clipboardRecorder.copied.length;
            const sessionA = picker.session - 1; // An earlier, ended session.
            const pathA = CUtils.newCaptureTempPath().split("\\").join("/");
            const sessionB = picker.session;
            const pathB = picker.beginClipboard();
            check(pathA !== "" && pathB !== "" && pathA !== pathB, "each save has its own path: " + pathB);
            const view = find(windows()[0].contentItem, "areaPickerView");
            CUtils.saveItem(view, fileUrl(pathB), Qt.rect(0, 0, 6, 6), () => {}, () => {});
            CUtils.saveItem(view, fileUrl(pathA), Qt.rect(0, 0, 6, 6), () => {}, () => {});
            later(500, () => step(() => {
                check(WindowsFiles.isFile(pathA) && WindowsFiles.isFile(pathB), "both hand-over files exist");
                picker.copyFinished(sessionA, pathA);
                check(!WindowsFiles.isFile(pathA), "A's late result deletes A's file");
                check(WindowsFiles.isFile(pathB), "and leaves B's file alone");
                check(clipboardRecorder.copied.length === copies && picker.opened && picker.activeTemp === pathB, "and does not disturb B");
                picker.copyFinished(sessionB, pathB);
                check(clipboardRecorder.copied.length === copies + 1 && clipboardRecorder.copied[copies] === pathB, "B copies its own file");
                check(!WindowsFiles.isFile(pathB), "and deletes it");
                later(900, () => step(() => {
                    check(!picker.opened, "the picker closed");
                    uniqueTempPathsStep();
                }));
            }));
        }));
    }

    function uniqueTempPathsStep(): void {
        // Two fresh pickers, both at session 0, reserve different files in the
        // temp directory: names do not depend on the session.
        const first = extraPicker.createObject(root);
        const second = extraPicker.createObject(root);
        CaptureUi.picker = picker;
        check(first.session === second.session, "two new pickers count sessions from the same number");
        const pathOne = first.beginClipboard();
        const pathTwo = second.beginClipboard();
        check(pathOne !== "" && pathTwo !== "" && pathOne !== pathTwo, "but get different hand-over paths");
        check(inTemp(pathOne) && inTemp(pathTwo) && WindowsFiles.isFile(pathOne) && WindowsFiles.isFile(pathTwo),
            "each created exclusively, directly in the temp directory");
        first.invalidate();
        check(!WindowsFiles.isFile(pathOne) && WindowsFiles.isFile(pathTwo), "a picker deletes only its own file");
        second.invalidate();
        check(!WindowsFiles.isFile(pathTwo), "the other deletes its own");
        first.destroy();
        second.destroy();
        removeScope();
    }

    function removeScope(): void {
        // CUtils.removeCaptureTemp accepts only the exact name scheme in the temp
        // directory.
        const hex = "0123456789abcdef0123456789abcdef";
        const mine = CUtils.newCaptureTempPath();
        const base = mine.substring(mine.lastIndexOf("/") + 1);
        const wrongName = root.tempFolder + "/caelestia-clipboard-" + hex.substring(1) + ".png";
        const upper = root.tempFolder + "/caelestia-clipboard-" + hex.toUpperCase() + ".png";
        const unrelated = root.tempFolder + "/unrelated-" + hex + ".png";
        const elsewhere = root.stateFolder + "/caelestia-clipboard-" + hex + ".png";
        const sub = root.tempFolder + "/sub";
        const dotted = sub + "/../" + base;
        const linkName = root.tempFolder + "/caelestia-clipboard-fedcba9876543210fedcba9876543210.png";
        const target = root.stateFolder + "/junction-target";
        const setup = "$ErrorActionPreference='Stop'; "
            + "New-Item -ItemType Directory -Force -Path '" + winPath(sub) + "','" + winPath(target) + "' | Out-Null; "
            + "foreach ($p in '" + winPath(wrongName) + "','" + winPath(upper) + "','" + winPath(unrelated) + "','" + winPath(elsewhere) + "') { "
            + "if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType File -Path $p | Out-Null } }; "
            + "New-Item -ItemType File -Force -Path '" + winPath(target) + "\\keep.txt' | Out-Null; "
            + "New-Item -ItemType Junction -Path '" + winPath(linkName) + "' -Target '" + winPath(target) + "' | Out-Null";
        powershell(setup, code => {
            check(code === 0, "the refusal cases were set up");
            check(WindowsFiles.isFile(mine), "a hand-over file exists");
            check(CUtils.removeCaptureTemp(dotted) === false && WindowsFiles.isFile(mine), "a path with .. is refused");
            check(CUtils.removeCaptureTemp(winPath(mine)) === false && WindowsFiles.isFile(mine), "so is the same path with other separators");
            check(CUtils.removeCaptureTemp(wrongName) === false && WindowsFiles.isFile(wrongName), "a name of the wrong length is refused");
            check(CUtils.removeCaptureTemp(upper) === false && WindowsFiles.isFile(upper), "so is upper case hex");
            check(CUtils.removeCaptureTemp(unrelated) === false && WindowsFiles.isFile(unrelated), "so is another name in the temp directory");
            check(CUtils.removeCaptureTemp(elsewhere) === false && WindowsFiles.isFile(elsewhere), "so is a matching name in another directory");
            check(CUtils.removeCaptureTemp(sub) === false && CUtils.removeCaptureTemp(root.tempFolder) === false, "so are directories");
            check(CUtils.removeCaptureTemp("") === false && CUtils.removeCaptureTemp(mine + "\n") === false, "so are an empty path and a trailing newline");
            check(CUtils.removeCaptureTemp(linkName) === false && WindowsFiles.isFile(target + "/keep.txt"),
                "a junction with a matching name is refused and its target is untouched");
            check(CUtils.removeCaptureTemp(mine) === true && !WindowsFiles.isFile(mine), "the exact path is deleted");
            check(CUtils.removeCaptureTemp(mine) === false, "and deleting it again does nothing");
            // Remove only the link, never its contents.
            powershell("cmd /c rmdir \"" + winPath(linkName) + "\"", removed => {
                check(removed === 0 && WindowsFiles.isFile(target + "/keep.txt"), "the junction is removed and the target is intact");
                monitorStep();
            });
        });
    }

    function monitorStep(): void {
        check(!picker.opened, "the picker is closed before the monitor case");

        // A monitor change while open cancels the picker.
        check(CaptureUi.screenshot("open") === true && picker.opened, "the picker opens for the monitor change");
        readyAll();
        picker.screenList = [];
        check(!picker.opened, "removing a monitor closes the picker at once");
        check(toastWith("monitors changed") !== "", "with a toast");
        check(windows().length === 0, "and no windows are left");
        picker.screenList = Qt.binding(() => Screens.screens);
        check(CaptureUi.screenshot("open") === true && picker.opened, "the picker opens normally afterwards");
        check(windows().length === Quickshell.screens.length, "with a window per screen again");
        readyAll();
        later(300, () => step(rejectionStep));
    }

    function rejectionStep(): void {
        // Every way saveItem can refuse a request reports through onFailed.
        let failed = 0;
        let saved = 0;
        const target = "file:///" + root.saveRoot + "/rejected.png";
        const onSaved = () => { saved++; };
        const onFailed = () => { failed++; };
        const window = windows()[0];
        const empty = Qt.createQmlObject("import QtQuick; Item {}", window.contentItem);
        CUtils.saveItem(null, target, Qt.rect(0, 0, 1, 1), onSaved, onFailed);
        CUtils.saveItem(find(window.contentItem, "areaPickerView"), "https://example.invalid/x.png", Qt.rect(0, 0, 1, 1), onSaved, onFailed);
        CUtils.saveItem(shot, target, Qt.rect(0, 0, 1, 1), onSaved, onFailed);
        CUtils.saveItem(empty, target, Qt.rect(0, 0, 1, 1), onSaved, onFailed);
        check(failed === 0, "the callbacks run from the event loop, not inside the call");

        // A crop that sticks out of the image is clipped to it, not padded; one
        // wholly outside fails.
        const view = find(window.contentItem, "areaPickerView");
        const edge = root.saveRoot + "/clipped-edge.png";
        const gone = root.saveRoot + "/clipped-outside.png";
        let clippedSaved = 0;
        let clippedFailed = 0;
        const width = Math.round(window.width);
        CUtils.saveItem(view, fileUrl(edge), Qt.rect(width - 10, 0, 40, 20), () => { clippedSaved++; }, () => { clippedFailed++; });
        CUtils.saveItem(view, fileUrl(gone), Qt.rect(width + 10, 0, 20, 20), () => { clippedSaved++; }, () => { clippedFailed++; });
        later(700, () => step(() => {
            check(failed === 4 && saved === 0, "no target, a remote URL, no window and an empty item each call onFailed: " + failed);
            check(!WindowsFiles.isFile(root.saveRoot + "/rejected.png"), "and nothing is written");
            check(clippedSaved === 1 && clippedFailed === 1, "a crop past the edge saves and one wholly outside fails: " + clippedSaved + "/" + clippedFailed);
            shot.source = fileUrl(edge);
            check(shot.status === Image.Ready && shot.sourceSize.width === 10 && shot.sourceSize.height === 20,
                "the crop past the edge is cut to the image, 10 x 20: " + shot.sourceSize);
            check(!WindowsFiles.isFile(gone), "and the outside one writes no file");
            shot.source = "";
            empty.destroy();
            picker.cancel();
            later(1200, () => step(panelTimeoutStep));
        }));
    }

    function panelTimeoutStep(): void {
        check(!picker.opened, "the picker is closed before the panel case");
        // A panel that never hides: the request times out and nothing opens.
        glazier.hiddenTimeout = 50;
        surfacesHiddenNow = false;
        check(CaptureUi.screenshot("open") === true, "the request is accepted");
        later(400, () => step(afterTimeout));
    }

    function afterTimeout(): void {
        check(!picker.opened && CaptureUi.pending === null, "a panel that stays open cancels the request");
        check(toastWith("still on screen") !== "", "and the user is told");

        // Smoke never freezes a desktop.
        surfacesHiddenNow = true;
        picker.interactionEnabled = false;
        check(CaptureUi.screenshot("open") === false && !picker.opened, "no picker while interaction is disabled");
        picker.interactionEnabled = true;

        // Switching back to classic works without a restart.
        GlobalConfig.windows = { capture: { ui: "classic" } };
        classicCalls = 0;
        CaptureUi.screenshot("open");
        check(classicCalls === 1, "the setting applies live");

        CaptureUi.glazierProvider = Glazier;
        console.log("CAELESTIA_CAPTURE_PICKER_PASS " + assertions);
        Qt.quit();
    }
}
