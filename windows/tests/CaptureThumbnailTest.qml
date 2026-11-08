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

    // The toolbar and the buttons are sized by the controls' fonts, so the test
    // loads the shell's fonts and a screen for Tokens, as the shell does.
    Tokens.screen: Quickshell.screens[0]?.name ?? ""

    FontLoader {
        source: Quickshell.shellPath("assets/google-sans-flex/GoogleSansFlex-VariableFont_GRAD,ROND,opsz,slnt,wdth,wght.ttf")
    }
    FontLoader { source: Quickshell.shellPath("assets/material-symbols-rounded/MaterialSymbolsRounded.ttf") }

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

    // Holds a preview file open for the locked-file cases.
    Process {
        id: holder
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

    // The rectangles of a panel's input mask, as the backend reads them: each
    // child region's item, in panel coordinates.
    function maskRects(window): var {
        return Array.from(window.mask.regions).map(region => region.item).map(item => {
            const origin = window.contentItem.mapFromItem(item, 0, 0);
            return { x: origin.x, y: origin.y, width: item.width, height: item.height };
        });
    }

    function inMask(rects, x, y): bool {
        return rects.some(r => x >= r.x && y >= r.y && x < r.x + r.width && y < r.y + r.height);
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

    // Selects a rectangle in the open picker, releases the mouse, and then
    // chooses "save" or "copy" in the editor that the selection opens.
    function drag(x1, y1, x2, y2, kind = "save"): void {
        const area = find(pickerWindows()[0].contentItem, "areaPicker");
        area.pressAt(Qt.LeftButton, x1, y1);
        area.moveTo(x2, y2);
        area.releaseAt(Qt.LeftButton, x2, y2);
        check(picker.editing && !picker.saving, "the selection opens the editor and saves nothing");
        picker.editPicker.exportEdit(kind);
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
        check(thumbs.entries.length === 1, "the thumbnail is the feedback");
        check(toastWith("Saved to") === "" && toastWith("Screenshot taken") === "", "and there is no success toast");
        savedPath = thumbs.entries[0].path;
        check(WindowsFiles.isFile(savedPath), "the file was saved: " + savedPath);
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
        const copy = find(card, "captureThumbnailAction-copy");
        check(copy.stateLayer !== undefined && copy.type === 2, "the buttons are Caelestia IconButtons of the text type");
        check(copy.width === copy.height && copy.width > 0, "square, sized by the control: " + copy.width);
        const buttons = ["copy", "reveal", "close"].map(name => find(card, "captureThumbnailAction-" + name));
        check(buttons.every(button => button.width === copy.width && button.height === copy.height), "all the same size");
        check(buttons[1].x - (buttons[0].x + buttons[0].width) === Tokens.spacing.extraSmall, "spaced by Tokens");
        check(pill.width === 3 * copy.width + 2 * Tokens.spacing.extraSmall + 2 * Tokens.padding.extraSmall
            && pill.height === copy.height + 2 * Tokens.padding.extraSmall, "the pill is its buttons plus Tokens padding");
        card.manualHover = true;
        later(600, () => step(() => {
            check(pill.visible && pill.opacity === 1, "the buttons show while the pointer is over the card");
            check(card.paused, "which pauses the timeout");
            check(pill.y + pill.height === card.height - Tokens.spacing.small, "a small gap above the bottom edge");
            check(pill.x === Math.round((card.width - pill.width) / 2), "centred on whole pixels");
            card.manualHover = false;
            copyCapture();
        }));
    }

    // 2. The thumbnail appears after a copy.
    function copyCapture(): void {
        check(CaptureUi.screenshot("openClip") === true, "openClip is asked to open");
        later(400, () => step(() => {
            check(picker.opened, "the picker opened for a clipboard capture");
            check(panels()[0].visible === false && thumbs.suspended, "the thumbnails step aside while the picker is open");
            readyAll();
            later(300, () => step(() => {
                drag(10, 10, 70, 60, "copy");
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
        find(card, "captureThumbnailAction-copy").clicked();
        check(clipboardRecorder.copied.length === 2 && clipboardRecorder.copied[1] === entry.path && clipboardRecorder.existedAtCall,
            "Copy puts the preview file on the clipboard");
        check(thumbs.entries.length === 2, "and leaves the thumbnail");

        thumbs.open(entry);
        check(opener.urls.length === 1 && decodeURIComponent(opener.urls[0]).endsWith(entry.path) && opener.urls[0].indexOf("file:///") === 0,
            "clicking the card opens the image: " + opener.urls[0]);

        // Save writes to Screenshots with the picker's naming.
        const preview = entry.temp;
        find(card, "captureThumbnailAction-save").clicked();
        check(entry.saved && entry.path !== preview, "Save saves the capture");
        check(entry.path.indexOf(root.saveRoot + "/Screenshots/annotate-") === 0 && entry.path.endsWith(".png"), "in Screenshots with the default name: " + entry.path);
        check(WindowsFiles.isFile(entry.path), "the file exists");
        check(!WindowsFiles.isFile(preview) && entry.temp === "", "the preview file is gone");
        check(toastWith("Saved to") === "", "and no toast, because the thumbnail is the feedback");
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
        // The input mask is one region per card. It covers every card and nothing
        // else: not the gaps between cards, not the margin, not the rest of the panel.
        const rects = maskRects(window);
        check(rects.length === 5, "one mask region per card: " + rects.length);
        for (let i = 0; i < 5; i++) {
            const card = list[i];
            for (const [px, py] of [[card.x + 1, card.y + 1], [card.x + card.width / 2, card.y + card.height / 2],
                    [card.x + card.width - 1, card.y + card.height - 1]])
                check(inMask(rects, px, py), "a point on card " + i + " is inside the mask");
            check(!inMask(rects, card.x + card.width / 2, card.y - 1), "the row above card " + i + " is outside");
            check(!inMask(rects, card.x - 1, card.y + card.height / 2), "and the column left of it");
            check(!inMask(rects, card.x + card.width + 1, card.y + card.height / 2), "and the column right of it");
        }
        for (let i = 0; i < 4; i++)
            check(!inMask(rects, list[i].x + list[i].width / 2, list[i].y + list[i].height + 6), "the middle of the gap under card " + i + " is outside the mask");
        check(!inMask(rects, 5, 5) && !inMask(rects, window.width / 2, window.height / 2) && !inMask(rects, window.width - 3, window.height - 3),
            "so is the rest of the panel, including its corner margin");
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
        // While it slides in, its mask region is where the card is drawn.
        later(60, () => step(() => {
            const card = cardFor(entry);
            const rects = maskRects(panels()[0]);
            const mask = card.maskItem;
            check(rects.length === 5, "a mask region per card while the oldest one leaves and the new one enters");
            check(mask.x === card.x + (1 - card.slide) * 60 && mask.y === card.y, "the region follows the slide: " + mask.x + " for card x " + card.x + " at slide " + card.slide);
            check(card.slide >= 1 || mask.x > card.x, "a card still sliding in is masked where it is drawn, to the right of its place");
            check(card.fade > 0 ? mask.width === card.width : mask.width === 0, "and takes no presses until it is visible");
            later(700, () => step(() => closeCard(entry, temp)));
        }));
    }

    function closeCard(entry, temp): void {
        const card = cardFor(entry);
        check(card.slide === 1 && card.maskItem.x === card.x, "after the slide the region is the card");
        find(card, "captureThumbnailAction-close").clicked();
        check(entry.closing, "Close starts the exit");
        later(1500, () => step(() => {
            check(thumbs.entries.length === 4 && !thumbs.entries.includes(entry), "the thumbnail is gone after the exit");
            check(!WindowsFiles.isFile(temp), "and so is its preview file");
            check(cards().length === 4, "with its card");
            check(maskRects(panels()[0]).length === 4, "and its mask region");
            timeoutStep();
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
                drag(10, 10, 40, 40, "copy");
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
                            drag(10, 10, 40, 40, "copy");
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
            lockStep();
        }));
    }

    // 11. A preview file that a viewer holds open is deleted later.
    //
    // The helper opens the file for reading without delete sharing, which is what
    // a viewer does, so Windows refuses to delete it until the helper lets go.
    // It creates a flag file once it holds the file and lets go when a second flag
    // file appears.
    // `path` is one path or a list of paths, all held by the same helper.
    function holdFile(path, callback): void {
        const base = root.stateFolder + "/thumbnail-lock-" + (++lockCount);
        held.flag = base + ".held";
        held.release = base + ".release";
        const list = (Array.isArray(path) ? path : [path]).map(item => "'" + winPath(item) + "'").join(",");
        holder.command = [Quickshell.env("SystemRoot") + "\\System32\\WindowsPowerShell\\v1.0\\powershell.exe",
            "-NoProfile", "-NonInteractive", "-Command",
            "$held = @(foreach ($p in @(" + list + ")) { [IO.File]::Open($p, 'Open', 'Read', 'Read') }); "
            + "New-Item -ItemType File -Force -Path '" + winPath(held.flag) + "' | Out-Null; "
            + "while (-not (Test-Path -LiteralPath '" + winPath(held.release) + "')) { Start-Sleep -Milliseconds 50 }; "
            + "foreach ($f in $held) { $f.Close() }"];
        holder.running = true;
        waitFor(() => WindowsFiles.isFile(held.flag), callback, 200);
    }

    function letGo(callback): void {
        powershell("New-Item -ItemType File -Force -Path '" + winPath(held.release) + "' | Out-Null", code => {
            check(code === 0, "the lock is released");
            waitFor(() => !holder.running, callback, 200);
        });
    }

    // Polls every 50 ms until `condition` holds, then calls `callback`.
    function waitFor(condition, callback, tries): void {
        check(tries > 0, "the awaited condition came true");
        if (condition())
            callback();
        else
            later(50, () => step(() => waitFor(condition, callback, tries - 1)));
    }

    property int lockCount: 0

    function lockStep(): void {
        check(thumbs.entries.length === 0 && thumbs.pendingTemps.length === 0 && !thumbs.retrying, "nothing is waiting to be deleted yet");
        thumbs.retryInterval = 300;
        check(thumbs.addCopy(info(), savedPath), "a copy-only thumbnail");
        const entry = thumbs.entries[0];
        const temp = entry.temp;
        holdFile(temp, () => step(() => {
            thumbs.close(entry);
            later(1200, () => step(() => {
                check(!thumbs.entries.includes(entry), "the thumbnail closed");
                check(WindowsFiles.isFile(temp), "but Windows kept its locked preview file");
                check(thumbs.pendingTemps.length === 1 && thumbs.pendingTemps[0] === temp, "which the scope remembers");
                check(thumbs.retrying, "and retries on a timer");
                // The retries so far (every 300 ms) all failed and kept the file.
                letGo(() => step(() => {
                    later(900, () => step(() => {
                        check(!WindowsFiles.isFile(temp), "once the viewer lets go, a retry deletes it");
                        check(thumbs.pendingTemps.length === 0 && !thumbs.retrying, "and the retry timer stops");
                        nextCaptureRetry();
                    }));
                }));
            }));
        }));
    }

    function nextCaptureRetry(): void {
        // A very long interval, so only the next capture can retry.
        thumbs.retryInterval = 600000;
        check(thumbs.addCopy(info(), savedPath), "another copy-only thumbnail");
        const entry = thumbs.entries[0];
        const temp = entry.temp;
        holdFile(temp, () => step(() => {
            thumbs.close(entry);
            later(1200, () => step(() => {
                check(WindowsFiles.isFile(temp) && thumbs.pendingTemps.includes(temp), "the locked file is remembered again");
                letGo(() => step(() => {
                    later(500, () => step(() => {
                        check(WindowsFiles.isFile(temp), "with a long interval nothing retries by itself");
                        check(thumbs.addSaved(info(), savedPath), "the next capture arrives");
                        check(!WindowsFiles.isFile(temp) && thumbs.pendingTemps.length === 0, "and retries the deletion at once");
                        check(!thumbs.retrying, "so the timer stops");
                        saveWhileLocked();
                    }));
                }));
            }));
        }));
    }

    // Save while a viewer holds the preview file, then a retry, then a reload of
    // the card's image. The card must already show the saved file by then.
    function saveWhileLocked(): void {
        thumbs.retryInterval = 300;
        check(thumbs.addCopy(info(), savedPath), "a copy-only thumbnail");
        const entry = thumbs.entries[thumbs.entries.length - 1];
        const temp = entry.temp;
        check(entry.imagePath === temp, "the card shows the preview file");
        later(700, () => step(() => {
            const image = find(cardFor(entry), "captureThumbnailImage");
            check(image.status === Image.Ready && decodeURIComponent(String(image.source)).endsWith(temp), "and has loaded it");
            holdFile(temp, () => step(() => {
                check(thumbs.saveEntry(entry) === true && entry.saved, "Save works while the preview file is locked");
                check(entry.imagePath === entry.path && entry.path !== temp, "the card now shows the saved file");
                check(decodeURIComponent(String(image.source)).endsWith(entry.path), "its image source changed first");
                check(entry.temp === "" && WindowsFiles.isFile(temp) && thumbs.pendingTemps.includes(temp), "then the locked preview file went on the retry list");
                check(!thumbs.isShown(temp), "no live card shows a file on the list");
                later(500, () => step(() => {
                    check(image.status === Image.Ready, "the saved file is loaded");
                    letGo(() => step(() => {
                        later(900, () => step(() => {
                            check(!WindowsFiles.isFile(temp) && thumbs.pendingTemps.length === 0, "the retry deleted the preview file");
                            // A new size makes the image load again. It reads the saved file.
                            const before = image.sourceSize.width;
                            entry.imageWidth = 3000;
                            entry.imageHeight = 2000;
                            check(image.sourceSize.width > 0 && image.sourceSize.width !== before, "a new size asks for a new decode: " + before + " then " + image.sourceSize.width);
                            later(600, () => step(() => {
                                check(image.status === Image.Ready, "and the image stays valid after the preview file is gone");
                                capStep();
                            }));
                        }));
                    }));
                }));
            }));
        }));
    }

    // The retry list holds at most pendingLimit paths.
    function capStep(): void {
        thumbs.pendingLimit = 3;
        const paths = [];
        for (let i = 0; i < 4; i++)
            paths.push(CUtils.newCaptureTempPath().split("\\").join("/"));
        check(paths.every(path => path !== "" && WindowsFiles.isFile(path)), "four temp files");
        holdFile(paths, () => step(() => {
            const dropped = thumbs.droppedCount;
            for (const path of paths)
                thumbs.deleteTemp(path);
            check(thumbs.pendingTemps.length === 3 && thumbs.droppedCount === dropped + 1, "the list stops at its limit and drops one");
            check(thumbs.pendingTemps[0] === paths[1] && thumbs.pendingTemps[2] === paths[3], "the oldest path");
            check(WindowsFiles.isFile(paths[0]), "whose file stays in the temp directory");
            thumbs.deleteTemp(paths[3]);
            check(thumbs.pendingTemps.length === 3 && thumbs.droppedCount === dropped + 1, "a path already on the list is not added twice");
            letGo(() => step(() => {
                later(900, () => step(() => {
                    check(thumbs.pendingTemps.length === 0 && paths.slice(1).every(path => !WindowsFiles.isFile(path)), "the three that were kept are deleted once released");
                    check(CUtils.removeCaptureTemp(paths[0]) === true, "the dropped one can still be removed by hand");
                    thumbs.pendingLimit = 20;
                    reloadWithLock();
                }));
            }));
        }));
    }

    // A reload forgets the list, but still makes one last attempt.
    function reloadWithLock(): void {
        const extra = extraThumbnails.createObject(root);
        check(extra.addCopy(info(), savedPath), "a new instance holds a copy-only thumbnail");
        const temp = extra.entries[0].temp;
        holdFile(temp, () => step(() => {
            extra.destroy();
            later(300, () => step(() => {
                check(WindowsFiles.isFile(temp), "a file that is still locked when the shell reloads stays");
                letGo(() => step(() => {
                    // The file belongs to the temp scheme, so a later cleanup
                    // (here the fixture's) can remove it.
                    check(CUtils.removeCaptureTemp(temp) === true && !WindowsFiles.isFile(temp), "and can be removed once released");
                    CaptureUi.thumbnails = thumbs;
                    thumbs.retryInterval = 30000;
                    finalStep();
                }));
            }));
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
