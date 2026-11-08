import QtQuick
import Quickshell
import Quickshell.Wayland
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
        function copyImageFile(path: string): bool {
            copied = copied.concat([path]);
            return true;
        }
    }

    AreaPicker {
        id: picker

        saveRoot: root.saveRoot
        tempDirectory: root.saveRoot + "/tmp"
        clipboard: root.clipboardRecorder
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
        check(path === root.saveRoot + "/tmp/clipboard.png", "from the temporary file under the state folder: " + path);
        check(WindowsFiles.isFile(path), "that file exists");
        shot.source = "file:///" + path;
        check(shot.status === Image.Ready && shot.sourceSize.width === 60 && shot.sourceSize.height === 50, "and holds the selection: " + shot.sourceSize);
        check(toastWith("copied to clipboard") !== "", "the user is told");
        check(!picker.opened, "the picker closes after copying");

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
