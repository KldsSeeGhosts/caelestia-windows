pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Caelestia
import Caelestia.Config
import qs.modules.areapicker
import "modules/areapicker/CaptureLogic.js" as Capture
import "modules/areapicker/ThumbnailLogic.js" as Thumb

// Every label and icon of the capture interface lies on a whole device pixel.
//
// The text type is NativeRendering, so a glyph run at a fractional device position
// is drawn soft or with uneven letters at 125% and 150% scaling. Test-CapturePicker.ps1
// starts this fixture once per case with QT_SCALE_FACTOR, so the window has a real
// device pixel ratio, and the fixture measures that ratio from the window itself
// (devicePixelRatio of the FloatingWindow). The ratio of the capture (the entry's
// dpr, EditorState.scale) is a separate input: a capture made at 125% can be shown
// in a window that has since moved to 150%, and the labels must follow the window.
// Each StyledText and MaterialIcon is mapped to the window with mapToItem(null, ...)
// times the window's ratio. The fixture covers the editor toolbar (placed below,
// above and inside a selection, after a drag, with Clear armed), the colour and size
// popover and the thumbnail cards on the production stack layout of a 1600 x 900
// work area.
ShellRoot {
    id: root

    Tokens.screen: Quickshell.screens[0]?.name ?? ""

    FontLoader {
        source: Quickshell.shellPath("assets/google-sans-flex/GoogleSansFlex-VariableFont_GRAD,ROND,opsz,slnt,wdth,wght.ttf")
    }
    FontLoader { source: Quickshell.shellPath("assets/material-symbols-rounded/MaterialSymbolsRounded.ttf") }

    // The ratio the window must have (set by QT_SCALE_FACTOR) and the ratio of the
    // capture. They differ in the cases that model a screen changed after a capture.
    readonly property real expectedWindow: Number(Quickshell.env("CAELESTIA_PIXELS_WINDOW_DPR") || 1)
    readonly property real captureScale: Number(Quickshell.env("CAELESTIA_PIXELS_CAPTURE_DPR") || 1)
    // The real device pixel ratio of the window, which is what Qt renders at.
    readonly property real scale: win.devicePixelRatio
    readonly property int minimumItems: 110
    readonly property var work: ({ x: 0, y: 0, width: 1600, height: 900 })
    property int assertions: 0
    property int items: 0
    property var misplaced: []
    property var region: ({ x: 300, y: 200, width: 500, height: 300 })
    property string previewSample

    EditorState {
        id: state

        scale: root.captureScale
    }

    QtObject {
        id: fakeOwner

        property bool suspended: false
        property int seconds: 0

        function copyEntry(): void {}
        function saveEntry(): void {}
        function reveal(): void {}
        function open(): void {}
        function close(): void {}
        function finish(): void {}
    }

    AreaPicker {
        id: picker
        history: null
        saveRoot: (Quickshell.env("CAELESTIA_STATE_DIR") || "").replace(/\\/g, "/") + "/pixel-exports"
    }

    Thumbnails {
        id: thumbs
    }

    FloatingWindow {
        id: win

        implicitWidth: 1600
        implicitHeight: 900
        visible: true
        color: "#202020"

        Item {
            id: backdrop

            anchors.fill: parent

            Rectangle {
                anchors.fill: parent
                color: "#445566"
            }

            Rectangle {
                x: 500
                width: 480
                height: 120
                visible: !!Quickshell.env("CAELESTIA_THUMBNAIL_RENDER")
                color: "#593b68"

                Rectangle { width: parent.width / 4; height: parent.height; color: "#b46f62" }
                Rectangle { x: 3 * parent.width / 4; width: parent.width / 4; height: parent.height; color: "#436577" }
                Text {
                    anchors.centerIn: parent
                    color: "white"
                    text: "Screenshot preview"
                    font.pixelSize: 18
                }
            }
        }

        Image {
            id: outputImage
            visible: false
            cache: false
        }

        EditorToolbar {
            id: toolbar

            anchors.fill: parent
            editor: state
            region: root.region
            work: root.work
            backdrop: backdrop
        }

        Item {
            id: stack

            anchors.fill: parent

            Repeater {
                id: cards

                model: 5

                ThumbnailCard {
                    id: card

                    required property int index
                    readonly property var rects: Thumb.stackRects(root.work, 5, Thumb.previewSize(root.work))

                    owner: fakeOwner
                    manualHover: true
                    present: true
                    slot: rects[index]
                    entry: QtObject {
                        property bool closing: false
                        property bool saved: false
                        property int imageWidth: 600
                        property int imageHeight: 400
                        property real dpr: root.captureScale
                        property string path: ""
                        property string imagePath: root.previewSample
                    }
                }
            }
        }
    }

    Process {
        id: pngProbe

        property string failure: "the edited PNG must contain the stroke and fill the original bounds"
        onExited: code => root.step(() => {
            root.check(code === 0, failure + " (exit " + code + ")");
            root.finish();
        })
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
            console.error("CAELESTIA_CAPTURE_PIXELS_FAIL " + error);
            Qt.exit(1);
        }
    }

    function later(milliseconds, body): void {
        timer.next = body;
        timer.interval = milliseconds;
        timer.restart();
    }

    function waitFor(test, next, description, attempts = 100): void {
        later(50, () => {
            if (test())
                next();
            else if (attempts > 1)
                waitFor(test, next, description, attempts - 1);
            else
                check(false, description);
        });
    }

    // The name of the nearest ancestor that has one, for the failure message.
    function nameOf(item): string {
        for (let p = item; p; p = p.parent) {
            if (p.objectName)
                return p.objectName;
        }
        return "(unnamed)";
    }

    // Every visible StyledText or MaterialIcon with something to draw.
    function texts(item, list): var {
        if (!item)
            return list;
        if (item.visible && item.renderType !== undefined && item.text !== undefined && String(item.text) !== "")
            list.push(item);
        for (const child of item.children)
            texts(child, list);
        return list;
    }

    // mapToItem works in single precision, which is off by about 1e-4 device
    // pixels at these sizes. The positions that matter are a quarter or more away.
    function whole(value): bool {
        return Math.abs(value - Math.round(value)) < 1e-3;
    }

    // The top left corner of the item's box in device pixels. A turned icon moves
    // its corner, so the box is found from its centre, which a turn leaves alone.
    function corner(item): var {
        const centre = item.mapToItem(null, item.width / 2, item.height / 2);
        return { x: (centre.x - item.width / 2) * scale, y: (centre.y - item.height / 2) * scale };
    }

    function checkTexts(list, minimum, label): void {
        check(list.length >= minimum, label + ": found " + list.length + " texts, expected at least " + minimum);
        for (const item of list) {
            const at = corner(item);
            const where = label + ", " + nameOf(item) + " \"" + item.text + "\" at " + scale + ": device "
                + at.x + ", " + at.y;
            assertions += 2;
            if (!whole(at.x) || !whole(at.y))
                misplaced.push({ group: label + " at " + scale, text: where });
            items++;
        }
    }

    Component.onCompleted: Qt.callLater(() => step(() => start()))

    function finish(): void {
        // Every misplaced item is counted, with one example for each group.
        const groups = {};
        for (const entry of misplaced) {
            groups[entry.group] = groups[entry.group] ?? { count: 0, example: entry.text };
            groups[entry.group].count++;
        }
        check(misplaced.length === 0, misplaced.length + " of " + items + " texts are off the device pixel grid:\n"
            + Object.keys(groups).map(name => groups[name].count + " in " + name + ", for example " + groups[name].example).join("\n"));
        check(Math.abs(toolbar.dpr - scale) < 1e-9, "the toolbar snaps to the window's ratio " + scale + ", not " + toolbar.dpr);
        check(Math.abs(cards.itemAt(0).dpr - scale) < 1e-9, "the cards snap to the window's ratio " + scale + ", not " + cards.itemAt(0).dpr);
        // A run that checked next to nothing proves nothing.
        check(items >= minimumItems, "only " + items + " texts were checked, expected at least " + minimumItems);
        console.log("CAELESTIA_CAPTURE_PIXELS_PASS " + assertions);
        Qt.quit();
    }

    // 1. The toolbar and the popover in each placement, then the cards.
    function start(): void {
        // The window must really run at the requested ratio, or every result
        // below would describe a different one.
        check(Math.abs(scale - expectedWindow) < 1e-9,
            "the window has a device pixel ratio of " + scale + ", expected " + expectedWindow + " (QT_SCALE_FACTOR)");
        check(Math.abs(state.scale - captureScale) < 1e-9, "the editor keeps the capture's ratio " + captureScale);
        state.reset();
        state.inkOpen = false;
        const cases = [
            { name: "below the selection", region: { x: 300, y: 200, width: 500, height: 300 }, drag: null, ink: false, arm: false, menu: -1 },
            { name: "above the selection", region: { x: 300.4, y: 640.3, width: 500, height: 240 }, drag: null, ink: false, arm: false, menu: -1 },
            { name: "inside the selection", region: { x: 50, y: 30, width: 1500, height: 840 }, drag: null, ink: false, arm: false, menu: -1 },
            { name: "after a drag", region: { x: 300, y: 200, width: 500, height: 300 }, drag: { x: 333.37, y: 412.61 }, ink: false, arm: false, menu: -1 },
            { name: "with the popover open", region: { x: 300, y: 200, width: 500, height: 300 }, drag: null, ink: true, arm: false, menu: -1 },
            { name: "with the popover above the bar", region: { x: 300.4, y: 640.3, width: 500, height: 240 }, drag: { x: 217.77, y: 301.33 }, ink: true, arm: false, menu: -1 },
            { name: "with Clear armed", region: { x: 300, y: 200, width: 500, height: 300 }, drag: null, ink: false, arm: true, menu: -1 },
            { name: "with the shape flyout open", region: { x: 300, y: 200, width: 500, height: 300 }, drag: null, ink: false, arm: false, menu: 1 }
        ];
        caseStep(cases, 0);
    }

    function caseStep(cases, caseIndex): void {
        if (caseIndex >= cases.length) {
            cardStep();
            return;
        }
        const current = cases[caseIndex];
        state.reset();
        root.region = current.region;
        state.barPosition = current.drag;
        state.inkOpen = current.ink;
        state.toolMenu = current.menu ?? -1;
        if (current.arm)
            state.pressClear();
        // The row layouts position their children when the frame is polished.
        later(150, () => step(() => {
            const bar = toolbar.children.find(child => child.objectName === "editorToolbar");
            const popover = toolbar.children.find(child => child.objectName === "editorInkPopover");
            const flyout = toolbar.children.find(child => child.objectName === "editorToolFlyout");
            const label = "toolbar " + current.name;
            check(bar !== undefined && popover !== undefined && flyout !== undefined, "the toolbar, its popover and the tool flyout exist");
            // Select, three group buttons, undo, redo, Clear, Save, Copy (icon and
            // label) and Close. The armed Clear has a label too.
            const all = texts(bar, []);
            checkTexts(all, current.arm ? 12 : 11, label);
            check(popover.visible === current.ink, label + ": the popover is " + (current.ink ? "open" : "closed"));
            if (current.ink)
                checkTexts(texts(popover, []), 5, label + " popover");
            check(flyout.visible === (current.menu >= 0), label + ": the tool flyout is " + (current.menu >= 0 ? "open" : "closed"));
            if (current.menu >= 0)
                checkTexts(texts(flyout, []), 4, label + " shape flyout");
            const copy = all.find(item => item.text === "Copy" && item.font.pointSize === Tokens.font.body.small.pointSize);
            check(copy !== undefined, label + ": the Copy label is among them");
            caseStep(cases, caseIndex + 1);
        }));
    }

    // 2. A settled card of the production stack, with its buttons showing.
    function cardStep(): void {
        state.reset();
        later(900, () => step(() => {
            for (let i = 0; i < 5; i++) {
                const card = cards.itemAt(i);
                check(card.slide === 1 && card.fade === 1 && card.transform[0].x === 0, "card " + i + " has settled");
                const label = "thumbnail card " + i + " of 5";
                // Copy, Save, Close, Pin, Edit, and Show in folder.
                checkTexts(texts(card, []), 6, label);
                const edge = card.mapToItem(null, 0, 0);
                assertions++;
                if (!whole(edge.x * scale) || !whole(edge.y * scale))
                    misplaced.push({ group: label + " at " + scale, text: label + ": the card starts at device " + (edge.x * scale) + ", " + (edge.y * scale) });
            }
            if (Quickshell.env("CAELESTIA_THUMBNAIL_RENDER"))
                renderCard();
            else if (scale === 1.5 && captureScale === 1.25)
                checkEditExport();
            else if (scale === 1 && captureScale === 1 && typeof CUtils.saveCaptureWithPreview === "function")
                checkMemoryPreview();
            else
                finish();
        }));
    }

    function checkMemoryPreview(): void {
        const legacy = Quickshell.stateDir.replace(/\\/g, "/") + "/legacy.png";
        const path = CUtils.newCaptureTempPath().replace(/\\/g, "/");
        const crop = Qt.rect(40, 30, 1440, 810);
        CUtils.saveItem(backdrop, "file:///" + legacy, crop, () => step(() => {
            let previewReady = false;
            later(50, () => CUtils.saveCaptureWithPreview(backdrop, "file:///" + path, crop, Qt.size(240, 160),
                url => {
                    step(() => {
                        outputImage.source = url;
                        check(outputImage.status === Image.Ready, "the memory preview can be used before PNG completion");
                        check(outputImage.sourceSize.width === 240 && outputImage.sourceSize.height === 135,
                            "the quick preview is bounded and keeps the original aspect ratio");
                        previewReady = true;
                    });
                    return previewReady;
                },
                () => {
                    step(() => {
                        check(previewReady, "the native preview arrived before PNG completion");
                        CUtils.releaseCapturePreview(outputImage.source);
                        outputImage.source = "file:///" + path;
                        check(outputImage.status === Image.Ready && outputImage.sourceSize.width === 1440
                            && outputImage.sourceSize.height === 810, "the PNG retains the full crop dimensions");
                        const first = legacy.replace(/'/g, "''");
                        const second = path.replace(/'/g, "''");
                        const script = "$ErrorActionPreference='Stop'; if ((Get-FileHash -LiteralPath '" + first
                            + "').Hash -ne (Get-FileHash -LiteralPath '" + second + "').Hash) { exit 1 }";
                        pngProbe.failure = "the full PNG must match the legacy crop byte for byte";
                        pngProbe.command = [Quickshell.env("CAELESTIA_POWERSHELL") || "powershell.exe", "-NoProfile", "-NonInteractive", "-Command", script];
                        pngProbe.running = true;
                    });
                    return true;
                },
                () => step(() => check(false, "could not write the full capture"))));
        }), () => step(() => check(false, "could not write the legacy capture")));
    }

    function renderCard(): void {
        const dir = Quickshell.stateDir.replace(/\\/g, "/");
        const input = dir + "/thumbnail-source.png";
        CUtils.saveItem(backdrop, "file:///" + input, Qt.rect(500, 0, 480, 120), () => step(() => {
            previewSample = input;
            later(500, () => step(() => {
                const card = cards.itemAt(4);
                CUtils.saveItem(card, "file:///" + dir + "/thumbnail-render.png",
                    () => step(finish), () => step(() => check(false, "could not render thumbnail")));
            }));
        }), () => step(() => check(false, "could not generate a wide sample image")));
    }

    function checkEditExport(): void {
        // At 150% this crop is 61 px wide, a size grabToImage cannot
        // request directly from a 150% window with a whole logical width.
        const crop = Capture.physicalExport({ x: 1, y: 1, width: 41, height: 41 }, scale);
        const path = CUtils.newCaptureTempPath().replace(/\\/g, "/");
        CUtils.saveItem(backdrop, "file:///" + path, Qt.rect(1, 1, 41, 41), () => step(() => {
            const info = { screen: Quickshell.screens[0].name, width: crop.width, height: crop.height, dpr: captureScale };
            check(thumbs.addCapture(info, path), "the fractional crop is staged");
            const source = thumbs.entries[0];
            thumbs.edit(source);
            waitFor(() => picker.editPicker && CUtils.findChild(picker.editPicker, "captureEditorSource")?.status === Image.Ready, () => {
                check(Math.abs(picker.editor.scale - captureScale) < 1e-9,
                    "the reopened editor keeps the capture's ratio " + captureScale + ", not the window's " + scale);
                picker.editor.pressAt(10, 10);
                picker.editor.moveTo(20, 20);
                picker.editor.releaseAt();
                picker.editPicker.exportEdit("save");
                waitFor(() => !picker.opened && thumbs.entries[0]?.saved, () => {
                    outputImage.source = "file:///" + thumbs.entries[0].path;
                    check(outputImage.status === Image.Ready && outputImage.sourceSize.width === crop.width
                        && outputImage.sourceSize.height === crop.height, "the exported PNG retains the original physical dimensions");
                    // Read actual PNG pixels. Grabbing the displayed Image
                    // can hide transparent padding on a fractional-DPR window.
                    const path = thumbs.entries[0].path.replace(/'/g, "''");
                    const script = "$ErrorActionPreference='Stop'; Add-Type -AssemblyName System.Drawing; "
                        + "$b = [Drawing.Bitmap]::new('" + path + "'); try { "
                        + "$bg = [Drawing.Color]::FromArgb(255,68,85,102).ToArgb(); "
                        + "$corners = @($b.GetPixel(2,2), $b.GetPixel(($b.Width-2),2), "
                        + "$b.GetPixel(2,($b.Height-2)), $b.GetPixel(($b.Width-2),($b.Height-2))); "
                        + "if (@($corners | Where-Object { $_.ToArgb() -ne $bg }).Count) { exit 2 }; "
                        + "$ink = [Drawing.Color]::FromArgb(255,255,68,68).ToArgb(); "
                        + "for ($y=8; $y -lt 36; $y++) { for ($x=8; $x -lt 36; $x++) { "
                        + "if ($b.GetPixel($x,$y).ToArgb() -eq $ink) { exit 0 } } }; exit 3 "
                        + "} finally { $b.Dispose() }";
                    pngProbe.command = [Quickshell.env("CAELESTIA_POWERSHELL") || "powershell.exe", "-NoProfile", "-NonInteractive", "-Command", script];
                    pngProbe.running = true;
                }, "saving the edited crop returns to a saved thumbnail");
            }, "the staged crop opens for editing");
        }), () => step(() => check(false, "could not create the staged crop")));
    }
}
