import QtQuick
import Quickshell
import Quickshell.Wayland
import Quickshell.Io
import Caelestia
import Caelestia.Config
import Caelestia.Windows
import qs.services
import qs.modules.areapicker

// The post-capture thumbnail of the QML picker, offscreen. The picker saves and
// copies for real into the disposable profile and temp directory. The clipboard
// and the "open with the default application" call are recorders, readiness of
// the frozen frames is reported by hand, and the timeout is shortened or turned
// off through the same config key the shell reads.
ShellRoot {
    id: root

    property int assertions: 0
    property bool surfacesHiddenNow: true
    property string saveRoot: (Quickshell.env("CAELESTIA_STATE_DIR") || "").replace(/\\/g, "/") + "/thumbnail-test"
    property string tempFolder: (Quickshell.env("TEMP") || "").split("\\").join("/")
    property string stateFolder: (Quickshell.env("CAELESTIA_STATE_DIR") || "").split("\\").join("/")
    property string savedPath: ""
    property string screenName: ""
    property int tempBefore: 0
    property var held: ({})

    property QtObject glazier: QtObject {
        property bool ready: true
        property string executable: "C:/Caelestia/caelestia-capture.exe"
        property int hiddenTimeout: 2000
        function capture(): bool { return true; }
        function dismiss(): void {}
        function surfacesHidden(): bool { return root.surfacesHiddenNow; }
    }

    // Records the clipboard writes. The real clipboard is never touched.
    property QtObject clipboardRecorder: QtObject {
        property var copied: []
        property bool result: true
        property bool existedAtCall: false
        function copyImageFile(path: string): bool {
            copied = copied.concat([path]);
            existedAtCall = WindowsFiles.isFile(path);
            shot.source = "file:///" + path.split("\\").join("/");
            return result;
        }
    }

    // Records what would be opened with the default application.
    property QtObject opener: QtObject {
        property var urls: []
        property bool result: true
    }

    AreaPicker {
        id: picker

        saveRoot: root.saveRoot
        clipboard: root.clipboardRecorder
    }

    Thumbnails {
        id: thumbs

        saveRoot: root.saveRoot
        clipboard: root.clipboardRecorder
        openUrl: url => {
            root.opener.urls = root.opener.urls.concat([String(url)]);
            return root.opener.result;
        }
    }

    Component {
        id: extraThumbnails

        Thumbnails {}
    }

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
            console.error("CAELESTIA_CAPTURE_THUMBNAIL_FAIL " + error);
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

    function findAll(item, name, found): var {
        if (!item)
            return found;
        if (item.objectName === name)
            found.push(item);
        for (const child of item.children)
            findAll(child, name, found);
        return found;
    }

    function pickerWindows(): var {
        return Array.from(picker.windows).filter(window => window);
    }

    function panels(): var {
        return Array.from(thumbs.windows).filter(window => window);
    }

    // Cards of the first panel, lowest on screen last.
    function cards(): var {
        const window = panels()[0];
        const list = window ? findAll(window.contentItem, "captureThumbnail", []) : [];
        return list.sort((a, b) => a.y - b.y);
    }

    function cardFor(entry): var {
        for (const window of panels()) {
            for (const card of findAll(window.contentItem, "captureThumbnail", [])) {
                if (card.entry === entry)
                    return card;
            }
        }
        return null;
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

    // Exits with the number of hand-over files in the temp directory.
    function countTemp(callback): void {
        powershell("exit @(Get-ChildItem -LiteralPath $env:TEMP -Filter 'caelestia-clipboard-*.png' -ErrorAction SilentlyContinue).Count", callback);
    }

    function winPath(path): string {
        return path.split("/").join("\\");
    }

    function inTemp(path): bool {
        return root.tempFolder !== "" && path.toLowerCase().indexOf(root.tempFolder.toLowerCase() + "/") === 0
            && path.indexOf("/", root.tempFolder.length + 1) < 0;
    }

    function toastWith(part): string {
        const toasts = Toaster.toasts;
        for (let i = 0; i < toasts.length; i++) {
            if (toasts[i].message.indexOf(part) >= 0)
                return toasts[i].message;
        }
        return "";
    }

    function info(width = 60, height = 40): var {
        return { screen: root.screenName, width: width, height: height, dpr: 1 };
    }

    function config(capture): void {
        GlobalConfig.windows = { capture: Object.assign({ ui: "shell" }, capture) };
    }

    // Selects a rectangle in the open picker and releases the mouse.
    function drag(x1, y1, x2, y2): void {
        const area = find(pickerWindows()[0].contentItem, "areaPicker");
        area.pressAt(Qt.LeftButton, x1, y1);
        area.moveTo(x2, y2);
        area.releaseAt(Qt.LeftButton, x2, y2);
    }

    Component.onCompleted: Qt.callLater(() => step(setup))

    function setup(): void {
        CaptureUi.glazierProvider = glazier;
        check(Quickshell.screens.length > 0, "the fixture has a screen");
        check(CaptureUi.thumbnails === thumbs, "the thumbnails register themselves with the router");
        check(picker.thumbnails === thumbs, "and the picker finds them there");
        // Timeout off, so the first checks are not racing a timer.
        config({ thumbnailSeconds: 0 });
        check(thumbs.enabled && thumbs.seconds === 0, "a timeout of 0 is read from the config");
        check(thumbs.entries.length === 0 && panels().length === 0, "no panel before the first capture");
        check(CaptureUi.screenshot("openFreeze") === true, "the picker is asked to open");
        later(400, () => step(() => {
            check(picker.opened, "the picker opened");
            screenName = pickerWindows()[0].screen.name;
            readyAll();
            later(300, () => step(savedCapture));
        }));
    }

    // 1. The thumbnail appears after a save.
    function savedCapture(): void {
        drag(20, 30, 80, 70);
        check(picker.saving, "release starts the save");
        later(1600, () => step(afterSave));
    }

    function afterSave(): void {
        const message = toastWith("Saved to");
        savedPath = message.substring(message.indexOf("Saved to ") + 9).replace(/\\/g, "/");
        check(WindowsFiles.isFile(savedPath), "the file was saved");
        check(!picker.opened && !thumbs.suspended, "the picker closed");
        check(thumbs.entries.length === 1, "one thumbnail after a save");
        const entry = thumbs.entries[0];
        check(entry.saved && entry.temp === "" && entry.path === savedPath, "it shows the saved file and owns no temp file");
        check(entry.screen === screenName && entry.imageWidth === 60 && entry.imageHeight === 40, "with the capture's screen and size");
        check(panels().length === 1, "one panel");
        const window = panels()[0];
        check(window.screen.name === screenName, "on the screen of the capture");
        check(window.WlrLayershell.layer === WlrLayer.Overlay, "an overlay panel");
        check(window.WlrLayershell.keyboardFocus === WlrKeyboardFocus.None, "that takes no keyboard focus");
        check(window.excludeFromCapture === true, "excluded from capture");
        check(window.exclusionMode === ExclusionMode.Normal && window.exclusiveZone === 0, "reserving no space, so it is the work area");
        check(window.anchors.left && window.anchors.right && window.anchors.top && window.anchors.bottom, "anchored to the work area");
        check(window.visible, "visible once the picker is gone");
        later(900, () => step(cardLook));
    }

    function cardLook(): void {
        const window = panels()[0];
        const list = cards();
        check(list.length === 1, "one card");
        const card = list[0];
        const expectedWidth = Math.min(260, window.width - 24);
        const expectedHeight = Math.min(174, Math.floor((window.height - 72) / 5));
        check(card.width === expectedWidth && card.height === expectedHeight, "260 x 174, or smaller on a small work area: " + card.width + " x " + card.height);
        check(card.x + card.width === window.width - 12 && card.y + card.height === window.height - 12, "12 px from the bottom right corner");
        check(card.fade === 1 && card.slide === 1 && card.opacity === 1 && card.transform[0].x === 0, "the entrance has finished");
        const image = find(card, "captureThumbnailImage");
        check(image !== null && image.status === Image.Ready, "the image is loaded");
        check(image.width === 60 && image.height === 40, "at its own size, because it is smaller than the card: " + image.width + " x " + image.height);
        check(Math.abs(image.x + image.width / 2 - card.width / 2) < 1 && Math.abs(image.y + image.height / 2 - card.height / 2) < 1, "centred");
        const pill = find(card, "captureThumbnailActions");
        check(pill !== null && !pill.visible, "the buttons are hidden until the pointer is over the card");
        check(find(card, "captureThumbnailAction-copy") && find(card, "captureThumbnailAction-reveal") && find(card, "captureThumbnailAction-close"),
            "Copy, Show in folder and Close are offered");
        check(find(card, "captureThumbnailAction-save") === null, "Save is not, because the capture is saved");
        check(find(card, "captureThumbnailAction-copy").width === 30 && find(card, "captureThumbnailAction-copy").height === 30, "30 px buttons");
        card.manualHover = true;
        later(600, () => step(() => {
            check(pill.visible && pill.opacity === 1, "the buttons show while the pointer is over the card");
            check(card.paused, "which pauses the timeout");
            check(pill.y + pill.height === card.height - 9, "9 px above the bottom edge");
            card.manualHover = false;
            copyCapture();
        }));
    }

    // 2. The thumbnail appears after a copy.
    function copyCapture(): void {
        check(CaptureUi.screenshot("openClip") === true, "openClip is asked to open");
        later(400, () => step(() => {
            check(picker.opened && picker.clipboardOnly, "a clipboard capture");
            check(panels()[0].visible === false && thumbs.suspended, "the thumbnails step aside while the picker is open");
            readyAll();
            later(300, () => step(() => {
                drag(10, 10, 70, 60);
                later(1600, () => step(afterCopy));
            }));
        }));
    }

    function afterCopy(): void {
        check(clipboardRecorder.copied.length === 1, "the image was handed to the clipboard");
        const handOver = clipboardRecorder.copied[0].split("\\").join("/");
        check(clipboardRecorder.existedAtCall, "from a file that existed at the call");
        check(!WindowsFiles.isFile(handOver), "which the picker deleted right away");
        check(!picker.opened && !thumbs.suspended && panels()[0].visible, "the picker closed and the panel is back");
        check(thumbs.entries.length === 2, "two thumbnails");
        const entry = thumbs.entries[1];
        check(!entry.saved && entry.temp !== "" && entry.path === entry.temp, "the new one shows its own preview file");
        check(entry.temp !== handOver, "not the deleted hand-over file");
        check(inTemp(entry.temp) && /\/caelestia-clipboard-[0-9a-f]{32}\.png$/.test(entry.temp), "named like a hand-over file, in the temp directory: " + entry.temp);
        check(WindowsFiles.isFile(entry.temp), "and it exists");
        shot.source = "file:///" + entry.temp;
        check(shot.status === Image.Ready && shot.sourceSize.width === 60 && shot.sourceSize.height === 50, "holding the selection: " + shot.sourceSize);
        check(entry.imageWidth === 60 && entry.imageHeight === 50, "and the card knows its size");
        later(900, () => step(copyLayout));
    }

    function copyLayout(): void {
        const window = panels()[0];
        const list = cards();
        check(list.length === 2, "two cards");
        check(list[0].entry === thumbs.entries[0] && list[1].entry === thumbs.entries[1], "the newest is at the bottom");
        check(list[1].y + list[1].height === window.height - 12, "on the bottom edge gap");
        check(list[0].y + list[0].height + 12 === list[1].y, "with 12 px between them");
        check(find(list[1], "captureThumbnailAction-save") !== null, "a copy-only capture offers Save");
        check(find(list[0], "captureThumbnailAction-save") === null, "a saved one does not");
        const image = find(list[1], "captureThumbnailImage");
        check(image.status === Image.Ready && image.width === 60 && image.height === 50, "the copy's preview is drawn");
        actionsStep();
    }

    // 3. The hover buttons and the card body.
    function actionsStep(): void {
        const entry = thumbs.entries[1];
        const card = cardFor(entry);
        find(card, "captureThumbnailAction-copy").triggered("copy");
        check(clipboardRecorder.copied.length === 2 && clipboardRecorder.copied[1] === entry.path && clipboardRecorder.existedAtCall,
            "Copy puts the preview file on the clipboard");
        check(thumbs.entries.length === 2, "and leaves the thumbnail");

        thumbs.open(entry);
        check(opener.urls.length === 1 && decodeURIComponent(opener.urls[0]).endsWith(entry.path) && opener.urls[0].indexOf("file:///") === 0,
            "clicking the card opens the image: " + opener.urls[0]);

        // Save writes to Screenshots with the picker's naming.
        const preview = entry.temp;
        find(card, "captureThumbnailAction-save").triggered("save");
        check(entry.saved && entry.path !== preview, "Save saves the capture");
        check(entry.path.indexOf(root.saveRoot + "/Screenshots/annotate-") === 0 && entry.path.endsWith(".png"), "in Screenshots with the default name: " + entry.path);
        check(WindowsFiles.isFile(entry.path), "the file exists");
        check(!WindowsFiles.isFile(preview) && entry.temp === "", "the preview file is gone");
        check(toastWith("Saved to") !== "", "with a toast");
        check(thumbs.saveEntry(entry) === true && entry.path.indexOf("(2)") < 0, "saving again does nothing");
        shot.source = "file:///" + entry.path;
        check(shot.status === Image.Ready && shot.sourceSize.width === 60 && shot.sourceSize.height === 50, "the saved file holds the same image");
        later(300, () => step(() => {
            check(find(card, "captureThumbnailAction-save") === null, "Save disappears once saved");
            check(find(card, "captureThumbnailImage").status === Image.Ready, "and the picture stays");
            revealStep();
        }));
    }

    function revealStep(): void {
        const saved = thumbs.entries[1];
        const folder = root.saveRoot + "/Screenshots";
        const before = opener.urls.length;
        thumbs.reveal(saved);
        check(opener.urls.length === before + 1 && decodeURIComponent(opener.urls[before]).endsWith(folder), "Show in folder opens the folder of a saved capture");

        // Save a second copy-only capture through Show in folder.
        check(thumbs.addCopy(info(), savedPath), "a copy-only thumbnail can be added from any image file");
        const copy = thumbs.entries[2];
        check(copy.temp !== "" && WindowsFiles.isFile(copy.temp), "with its own preview file");
        thumbs.reveal(copy);
        check(copy.saved && WindowsFiles.isFile(copy.path) && copy.temp === "", "Show in folder saves a copy-only capture first");
        check(opener.urls.length === before + 2 && decodeURIComponent(opener.urls[before + 1]).endsWith(folder), "and then opens the folder");

        // A failing opener is reported.
        opener.result = false;
        thumbs.open(copy);
        check(toastWith("could not be opened") !== "", "an image that cannot be opened is reported");
        opener.result = true;

        // A copy the clipboard refuses is reported.
        clipboardRecorder.result = false;
        check(thumbs.copyEntry(copy) === false && toastWith("could not be copied") !== "", "a refused copy is reported");
        clipboardRecorder.result = true;
        saveFailureStep();
    }

    function saveFailureStep(): void {
        check(thumbs.addCopy(info(), savedPath), "another copy-only thumbnail");
        const entry = thumbs.entries[3];
        const preview = entry.temp;
        // Neither Screenshots nor the folder itself can be created below a file.
        thumbs.saveRoot = savedPath;
        check(thumbs.saveEntry(entry) === false, "a save that cannot write fails");
        check(!entry.saved && entry.temp === preview && WindowsFiles.isFile(preview), "and keeps the preview");
        check(toastWith("The image could not be saved") !== "", "with a toast");
        thumbs.saveRoot = root.saveRoot;

        // Screenshots cannot be created, so the folder itself is used.
        const fallback = root.stateFolder + "/thumbnail-fallback";
        powershell("$ErrorActionPreference='Stop'; New-Item -ItemType Directory -Force -Path '" + winPath(fallback)
            + "' | Out-Null; New-Item -ItemType File -Force -Path '" + winPath(fallback) + "\\Screenshots' | Out-Null", code => {
            check(code === 0, "the fallback case was set up");
            thumbs.saveRoot = fallback;
            check(thumbs.saveEntry(entry) === true, "the save falls back to the folder itself");
            check(entry.path.indexOf(fallback + "/annotate-") === 0 && WindowsFiles.isFile(entry.path), "as the picker does: " + entry.path);
            check(!WindowsFiles.isFile(preview), "and drops the preview file");
            thumbs.saveRoot = root.saveRoot;
            stackStep();
        });
    }

    // 4. Stacking and eviction.
    function stackStep(): void {
        thumbs.closeAll();
        later(1500, () => step(() => {
            check(thumbs.entries.length === 0 && panels().length === 0, "closing every thumbnail removes the panel");
            check(WindowsFiles.isFile(savedPath), "and leaves the saved files alone");
            thumbs.addCopy(info(), savedPath);
            const copy = thumbs.entries[0];
            check(copy.temp !== "" && WindowsFiles.isFile(copy.temp), "the oldest is copy-only");
            for (let i = 0; i < 4; i++)
                check(thumbs.addSaved(info(), savedPath), "a saved thumbnail is added");
            check(thumbs.entries.length === 5, "five thumbnails");
            held.oldest = copy;
            held.oldestTemp = copy.temp;
            later(1000, () => step(fiveStack));
        }));
    }

    function fiveStack(): void {
        const window = panels()[0];
        const list = cards();
        check(panels().length === 1 && list.length === 5, "five cards in one panel");
        for (let i = 0; i < 5; i++)
            check(list[i].entry === thumbs.entries[i], "oldest highest, newest lowest: " + i);
        for (let i = 0; i < 4; i++)
            check(list[i].y + list[i].height + 12 === list[i + 1].y, "12 px between cards " + i + " and " + (i + 1));
        check(list[4].y + list[4].height === window.height - 12, "the newest on the bottom edge gap");
        check(list[0].y >= 0, "the oldest is inside the panel");
        const box = find(window.contentItem, "captureThumbnailStack");
        check(box.y === list[0].y && box.height === list[4].y + list[4].height - list[0].y && box.width === list[0].width,
            "the input area is the stack and nothing else");
        // A sixth pushes out the oldest, a copy-only one, and its file with it.
        const firstSerial = thumbs.entries[1].serial;
        thumbs.addSaved(info(), savedPath);
        check(thumbs.entries.length === 5, "a sixth thumbnail pushes one out");
        check(thumbs.entries[0].serial === firstSerial && thumbs.entries.every(entry => entry !== held.oldest), "the oldest");
        check(!WindowsFiles.isFile(held.oldestTemp), "and deletes its preview file");
        // A seventh pushes out a saved one, whose file belongs to the user.
        thumbs.addSaved(info(), savedPath);
        check(thumbs.entries.length === 5 && WindowsFiles.isFile(savedPath), "a saved capture's file is never deleted");
        later(1000, () => step(afterEviction));
    }

    function afterEviction(): void {
        const window = panels()[0];
        const list = cards();
        check(list.length === 5, "five cards after the evictions");
        for (let i = 0; i < 4; i++)
            check(list[i].y + list[i].height + 12 === list[i + 1].y, "the stack closed up: " + i);
        check(list[4].y + list[4].height === window.height - 12, "and still sits on the bottom edge gap");
        closeStep();
    }

    // 5. Close.
    function closeStep(): void {
        check(thumbs.addCopy(info(), savedPath), "a copy-only thumbnail on top of a full stack");
        const entry = thumbs.entries[4];
        const temp = entry.temp;
        check(thumbs.entries.length === 5 && WindowsFiles.isFile(temp), "it pushed the oldest out");
        later(700, () => step(() => {
            const card = cardFor(entry);
            find(card, "captureThumbnailAction-close").triggered("close");
            check(entry.closing, "Close starts the exit");
            later(1500, () => step(() => {
                check(thumbs.entries.length === 4 && !thumbs.entries.includes(entry), "the thumbnail is gone after the exit");
                check(!WindowsFiles.isFile(temp), "and so is its preview file");
                check(cards().length === 4, "with its card");
                timeoutStep();
            }));
        }));
    }

    // 6. The timeout, and the pause.
    function timeoutStep(): void {
        thumbs.closeAll();
        later(1500, () => step(() => {
            check(thumbs.entries.length === 0, "the stack is empty");
            config({ thumbnailSeconds: 1 });
            check(thumbs.seconds === 1, "the timeout follows the config");
            thumbs.addSaved(info(), savedPath);
            thumbs.addCopy(info(), savedPath);
            held.kept = thumbs.entries[0];
            held.timed = thumbs.entries[1];
            held.timedTemp = held.timed.temp;
            later(100, () => step(() => {
                cardFor(held.kept).manualHover = true;
                later(2300, () => step(afterTimeout));
            }));
        }));
    }

    function afterTimeout(): void {
        check(thumbs.entries.length === 1 && thumbs.entries[0] === held.kept, "after 1 s the thumbnail the pointer is not over is gone");
        check(!WindowsFiles.isFile(held.timedTemp), "with its preview file");
        const card = cardFor(held.kept);
        check(card.elapsed === 0 || card.elapsed < 1000, "the one under the pointer has not used its time: " + card.elapsed);
        card.manualHover = false;
        later(2300, () => step(() => {
            check(thumbs.entries.length === 0, "it goes once the pointer leaves");
            noTimeoutStep();
        }));
    }

    function noTimeoutStep(): void {
        config({ thumbnailSeconds: 0 });
        thumbs.addSaved(info(), savedPath);
        later(2000, () => step(() => {
            check(thumbs.entries.length === 1, "a timeout of 0 never closes the thumbnail");
            config({ thumbnailSeconds: -3 });
            check(thumbs.seconds === 6, "a negative timeout falls back to 6 s");
            config({});
            check(thumbs.seconds === 6 && thumbs.enabled, "and so does a missing one");
            suspendStep();
        }));
    }

    // 7. The picker and the thumbnails take turns.
    function suspendStep(): void {
        config({ thumbnailSeconds: 0 });
        check(panels()[0].visible, "the panel is visible");
        check(CaptureUi.screenshot("open") === true, "a new picker is asked to open");
        later(400, () => step(() => {
            check(picker.opened && thumbs.suspended && !panels()[0].visible, "the panel is hidden while the picker is open");
            check(thumbs.entries.length === 1, "and keeps its thumbnails");
            readyAll();
            find(pickerWindows()[0].contentItem, "areaPicker").dismissByKey();
            later(1400, () => step(() => {
                check(!picker.opened && !thumbs.suspended && panels()[0].visible, "Esc brings it back");
                check(thumbs.entries.length === 1, "with nothing added");
                clipboardFailureStep();
            }));
        }));
    }

    // 8. A copy the clipboard refuses shows no thumbnail.
    function clipboardFailureStep(): void {
        clipboardRecorder.result = false;
        check(CaptureUi.screenshot("openClip") === true, "openClip is asked to open");
        later(400, () => step(() => {
            readyAll();
            later(300, () => step(() => {
                drag(10, 10, 40, 40);
                later(1600, () => step(() => {
                    check(toastWith("could not be copied") !== "", "the refused copy is reported");
                    check(thumbs.entries.length === 1, "and adds no thumbnail");
                    clipboardRecorder.result = true;
                    disabledStep();
                }));
            }));
        }));
    }

    // 9. Turning it off.
    function disabledStep(): void {
        config({ thumbnail: false });
        check(!thumbs.enabled, "windows.capture.thumbnail = false turns it off");
        later(1500, () => step(() => {
            check(thumbs.entries.length === 0 && panels().length === 0, "and closes the ones on screen");
            countTemp(before => {
                tempBefore = before;
                check(thumbs.addSaved(info(), savedPath) === false, "nothing is added for a saved capture");
                check(thumbs.addCopy(info(), savedPath) === false, "or for a copy");
                countTemp(after => {
                    check(after === tempBefore, "and no preview file is made: " + tempBefore + " then " + after);
                    // The picker itself still works.
                    check(CaptureUi.screenshot("openClip") === true, "the picker still opens");
                    later(400, () => step(() => {
                        readyAll();
                        later(300, () => step(() => {
                            drag(10, 10, 40, 40);
                            later(1600, () => step(offResult));
                        }));
                    }));
                });
            });
        }));
    }

    function offResult(): void {
        check(clipboardRecorder.copied.length > 0 && thumbs.entries.length === 0 && panels().length === 0, "a copy still works and shows no thumbnail");
        config({ thumbnail: true, thumbnailSeconds: 0 });
        check(thumbs.enabled, "turning it back on works without a restart");
        reloadStep();
    }

    // 10. A shell reload leaves no preview file.
    function reloadStep(): void {
        const extra = extraThumbnails.createObject(root);
        check(CaptureUi.thumbnails === extra, "a new instance registers itself");
        check(extra.addCopy(info(), savedPath), "it holds a copy-only thumbnail");
        const temp = extra.entries[0].temp;
        check(WindowsFiles.isFile(temp), "with a preview file");
        extra.destroy();
        later(300, () => step(() => {
            check(!WindowsFiles.isFile(temp), "destroying the instance deletes the preview file");
            check(CaptureUi.thumbnails === null, "and unregisters it");
            CaptureUi.thumbnails = thumbs;
            finalStep();
        }));
    }

    function finalStep(): void {
        thumbs.closeAll();
        later(1500, () => step(() => {
            check(thumbs.entries.length === 0 && panels().length === 0, "everything is closed");
            countTemp(left => {
                check(left === 0, "no hand-over or preview file is left in the temp directory: " + left);
                GlobalConfig.windows = { capture: { ui: "classic" } };
                CaptureUi.glazierProvider = Glazier;
                console.log("CAELESTIA_CAPTURE_THUMBNAIL_PASS " + assertions);
                Qt.quit();
            });
        }));
    }
}
