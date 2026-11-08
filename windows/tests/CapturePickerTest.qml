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
    // The plugin resolves the capture folder itself, from the same state folder.
    property string stateFolder: (Quickshell.env("CAELESTIA_STATE_DIR") || "").split("\\").join("/")
    property string captureFolder: stateFolder + "/capture"

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

    AreaPicker {
        id: picker

        saveRoot: root.saveRoot
        clipboard: root.clipboardRecorder
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
        check(!picker.clipboardOnly, "openFreeze saves to a file");
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
        // Releasing saves straight away to <saveRoot>/Screenshots.
        area.releaseAt(Qt.LeftButton, 80, 70);
        check(picker.saving, "release starts the save");
        later(1200, () => step(() => savedStep(window)));
    }

    function savedStep(window): void {
        const message = toastWith("Saved to");
        check(message.indexOf("/Screenshots/annotate-") >= 0 && message.endsWith(".png"), "saved under Screenshots with the default name: " + message);
        savedPath = message.substring(message.indexOf("Saved to ") + 9).replace(/\\/g, "/");
        check(WindowsFiles.isFile(savedPath), "the file exists: " + savedPath);
        shot.source = "file:///" + savedPath;
        check(shot.status === Image.Ready, "the file is a readable image");
        check(shot.sourceSize.width === 60 && shot.sourceSize.height === 40, "the image has the selection's size: " + shot.sourceSize);
        check(!picker.opened, "the picker closes after saving");
        check(windows().length === 0, "its windows are gone");
        escapeStep();
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

        // The clipboard variants write the image to a temporary file under the
        // state folder and hand that path to the clipboard.
        check(CaptureUi.screenshot("openClip") === true && picker.opened && picker.clipboardOnly, "openClip opens a clipboard capture");
        readyAll();
        later(300, () => step(clipboardDrag));
    }

    function clipboardDrag(): void {
        const area = areaOf(windows()[0]);
        area.pressAt(Qt.LeftButton, 10, 10);
        area.moveTo(70, 60);
        area.releaseAt(Qt.LeftButton, 70, 60);
        later(1200, () => step(afterClipboard));
    }

    function afterClipboard(): void {
        check(clipboardRecorder.copied.length === 1, "the image is handed to the clipboard once");
        const path = clipboardRecorder.copied[0].split("\\").join("/");
        check(path.indexOf(root.captureFolder + "/clipboard-") === 0 && /clipboard-[0-9a-f]{32}\.png$/.test(path),
            "from this save's own uniquely named file in the capture folder under the state folder: " + path);
        check(clipboardRecorder.existedAtCall, "the file existed when the clipboard call ran");
        check(clipboardRecorder.sizeAtCall.width === 60 && clipboardRecorder.sizeAtCall.height === 50,
            "and held the selection: " + clipboardRecorder.sizeAtCall);
        check(!WindowsFiles.isFile(path), "the temporary file is deleted right after the call");
        check(toastWith("Copying screenshot to clipboard") !== "", "the toast says the copy started");
        check(toastWith("copied to clipboard") === "", "and does not claim it finished");
        check(!picker.opened, "the picker closes after copying");
        shot.source = "";

        // A refused copy reports a failure and still removes the file.
        clipboardRecorder.result = false;
        check(CaptureUi.screenshot("openClip") === true && picker.opened, "openClip opens again");
        readyAll();
        later(300, () => step(copyFailDrag));
    }

    function copyFailDrag(): void {
        const area = areaOf(windows()[0]);
        area.pressAt(Qt.LeftButton, 10, 10);
        area.moveTo(40, 40);
        area.releaseAt(Qt.LeftButton, 40, 40);
        later(1200, () => step(afterCopyFail));
    }

    function afterCopyFail(): void {
        check(clipboardRecorder.copied.length === 2, "the clipboard was asked again");
        check(toastWith("could not be copied") !== "", "a refused copy is reported");
        check(!WindowsFiles.isFile(clipboardRecorder.copied[1].split("\\").join("/")), "and its file is deleted too");
        check(!picker.opened, "the picker closes");
        clipboardRecorder.result = true;

        // Cancelling removes a leftover hand-over file.
        check(CaptureUi.screenshot("openClip") === true && picker.opened, "openClip opens for the cancel case");
        readyAll();
        later(300, () => step(tempCancelStep));
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
        check(clipboardRecorder.copied.length === 2, "and copies nothing");

        // A save that cannot write anywhere reports a failure. The save folder
        // is made a path below an existing file, so neither Screenshots nor the
        // folder itself can be created.
        picker.saveRoot = savedPath;
        check(CaptureUi.screenshot("open") === true && picker.opened, "the picker opens for the failing save");
        readyAll();
        later(300, () => step(failingSaveDrag));
    }

    function failingSaveDrag(): void {
        const area = areaOf(windows()[0]);
        area.pressAt(Qt.LeftButton, 10, 10);
        area.moveTo(40, 40);
        area.releaseAt(Qt.LeftButton, 40, 40);
        check(picker.saving, "the failing save starts");
        later(1200, () => step(afterFailingSave));
    }

    function afterFailingSave(): void {
        check(toastWith("The image could not be saved") !== "", "a save that fails is reported");
        check(!picker.opened && !picker.saving, "and the picker closes");
        picker.saveRoot = root.saveRoot;

        // A save that never answers ends in a bounded failure.
        picker.saveTimeout = 300;
        check(CaptureUi.screenshot("open") === true && picker.opened, "the picker opens for the stalled save");
        readyAll();
        later(300, () => step(() => {
            picker.saving = true;
            check(picker.opened, "a save is pending");
            later(1200, () => step(afterStall));
        }));
    }

    function afterStall(): void {
        check(toastWith("timed out") !== "", "a stalled save shows a failure toast");
        check(!picker.opened && !picker.saving, "and the picker closes");

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
            check(toastCount("Saved to C:/race/done.png") === 1, "one result is shown");
            picker.fileFinished(started, "C:/race/done.png");
            picker.saveFailed(started, "late failure");
            check(toastCount("Saved to C:/race/done.png") === 1 && toastWith("late failure") === "", "a second result for the same save is dropped");
            later(900, () => step(() => {
                check(toastCount("timed out") === timeouts, "the timeout never fires after a completion");
                check(!picker.opened, "the picker closed");
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
                picker.fileFinished(started, "C:/race/late.png");
                check(toastCount("C:/race/late.png") === 0, "a completion after the timeout is dropped");
                later(900, () => step(() => {
                    check(toastCount("timed out") === timeouts + 1, "and the timeout does not repeat");
                    check(!picker.opened, "the picker closed");
                    resultAfterEsc();
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
                    staleSweep();
                }));
            }));
        }));
    }

    function staleSweep(): void {
        // Two fresh pickers, both at session 0, reserve different files: names do
        // not depend on the session.
        const first = extraPicker.createObject(root);
        const second = extraPicker.createObject(root);
        CaptureUi.picker = picker;
        check(first.session === second.session, "two new pickers count sessions from the same number");
        const pathOne = first.beginClipboard();
        const pathTwo = second.beginClipboard();
        check(pathOne !== "" && pathTwo !== "" && pathOne !== pathTwo, "but get different hand-over paths");
        check(pathOne.indexOf(root.captureFolder + "/clipboard-") === 0 && WindowsFiles.isFile(pathOne) && WindowsFiles.isFile(pathTwo),
            "each created exclusively in the capture folder");
        first.invalidate();
        second.invalidate();
        check(!WindowsFiles.isFile(pathOne) && !WindowsFiles.isFile(pathTwo), "and each picker deletes only its own");
        first.destroy();
        second.destroy();

        // The start-of-picker sweep deletes only old temp files in the capture
        // folder. Fresh files, other names, folders and files outside survive.
        const old = CUtils.newCaptureTempPath().split("\\").join("/");
        const fresh = CUtils.newCaptureTempPath().split("\\").join("/");
        const hex = "0123456789abcdef0123456789abcdef";
        const other = root.captureFolder + "/other-" + hex + ".png";
        const tooShort = root.captureFolder + "/clipboard-1.png";
        const sibling = root.stateFolder + "/sibling";
        const outside = sibling + "/clipboard-" + hex + ".png";
        const parentFile = root.stateFolder + "/clipboard-" + hex + ".png";
        const folderLike = root.captureFolder + "/clipboard-" + "fedcba9876543210fedcba9876543210" + ".png";
        const setup = "$ErrorActionPreference='Stop'; $old=(Get-Date).AddMinutes(-5); "
            + "New-Item -ItemType Directory -Force -Path '" + winPath(sibling) + "','" + winPath(folderLike) + "' | Out-Null; "
            + "foreach ($p in '" + winPath(old) + "','" + winPath(other) + "','" + winPath(tooShort) + "','" + winPath(outside) + "','" + winPath(parentFile) + "') { "
            + "if (-not (Test-Path -LiteralPath $p)) { New-Item -ItemType File -Path $p | Out-Null }; (Get-Item -LiteralPath $p).LastWriteTime = $old }";
        powershell(setup, code => {
            check(code === 0, "the sweep fixture was set up");
            check(CUtils.removeStaleCaptureTemps() === 1, "the sweep removes exactly the one old hand-over file");
            check(CUtils.removeStaleCaptureTemps.length === 0, "the sweep takes no directory or pattern argument");
            try {
                CUtils.removeStaleCaptureTemps("../sibling", "*", 0);
            } catch (error) {
                // Either a refusal or an ignored argument is fine; what matters is below.
            }
            check(!WindowsFiles.isFile(old), "an old hand-over file in the capture folder is removed");
            check(WindowsFiles.isFile(fresh), "a fresh one survives");
            check(WindowsFiles.isFile(other) && WindowsFiles.isFile(tooShort), "files with other names survive, even old");
            check(WindowsFiles.isFile(outside) && WindowsFiles.isFile(parentFile), "old files outside the capture folder survive, even with a matching name");
            check(!WindowsFiles.isFile(folderLike), "a folder is not a file");
            junctionStep(fresh, hex);
        });
    }

    function junctionStep(fresh, hex): void {
        // The capture folder is replaced by a junction to another folder holding an
        // old, matching file. The sweep must refuse and delete nothing in the target.
        const target = root.stateFolder + "/junction-target";
        const victim = target + "/clipboard-" + hex + ".png";
        const script = "$ErrorActionPreference='Stop'; $old=(Get-Date).AddMinutes(-5); "
            + "Remove-Item -LiteralPath '" + winPath(root.captureFolder) + "' -Recurse -Force; "
            + "New-Item -ItemType Directory -Force -Path '" + winPath(target) + "' | Out-Null; "
            + "New-Item -ItemType File -Path '" + winPath(victim) + "' | Out-Null; (Get-Item -LiteralPath '" + winPath(victim) + "').LastWriteTime = $old; "
            + "New-Item -ItemType Junction -Path '" + winPath(root.captureFolder) + "' -Target '" + winPath(target) + "' | Out-Null";
        powershell(script, code => {
            check(code === 0, "the junction was created");
            check(WindowsFiles.isFile(victim), "the target holds an old matching file");
            check(CUtils.removeStaleCaptureTemps() === 0, "the sweep refuses a junction in place of the capture folder");
            check(WindowsFiles.isFile(victim), "and deletes nothing in its target");
            // Remove only the link, never its contents.
            powershell("cmd /c rmdir \"" + winPath(root.captureFolder) + "\"", removed => {
                check(removed === 0 && WindowsFiles.isFile(victim), "the junction is removed and the target is intact");
                check(CUtils.removeStaleCaptureTemps() === 0, "with no capture folder the sweep does nothing");
                check(CaptureUi.screenshot("open") === true && picker.opened, "the picker opens for the sweep case");
                picker.cancel();
                later(900, () => step(monitorStep));
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
