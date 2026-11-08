import QtQuick
import Quickshell
import Caelestia.Config
import qs.modules.areapicker
import "modules/areapicker/ThumbnailLogic.js" as Thumb

// Every label and icon of the capture interface lies on a whole device pixel.
//
// The text type is NativeRendering, so a glyph run at a fractional device position
// is drawn soft or with uneven letters at 125% and 150% scaling. The offscreen
// screen has a ratio of 1, so this fixture gives the toolbar and the cards the
// ratio the way the picker does (EditorState.scale, the entry's dpr) and maps
// each StyledText and MaterialIcon to the window with mapToItem(null, ...)
// times that ratio. It covers the editor toolbar (placed below, above and inside
// a selection, after a drag, with Clear armed), the colour and size popover and
// the thumbnail cards on the production stack layout of a 1600 x 900 work area.
ShellRoot {
    id: root

    Tokens.screen: Quickshell.screens[0]?.name ?? ""

    FontLoader {
        source: Quickshell.shellPath("assets/google-sans-flex/GoogleSansFlex-VariableFont_GRAD,ROND,opsz,slnt,wdth,wght.ttf")
    }
    FontLoader { source: Quickshell.shellPath("assets/material-symbols-rounded/MaterialSymbolsRounded.ttf") }

    readonly property var scales: [1, 1.25, 1.5]
    readonly property var work: ({ x: 0, y: 0, width: 1600, height: 900 })
    property int assertions: 0
    property int items: 0
    property var misplaced: []
    property real scale: 1
    property var region: ({ x: 300, y: 200, width: 500, height: 300 })

    EditorState {
        id: state

        scale: root.scale
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

    Window {
        id: window

        width: 1600
        height: 900
        visible: true
        color: "#202020"

        Item {
            id: backdrop

            anchors.fill: parent

            Rectangle {
                anchors.fill: parent
                color: "#445566"
            }
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
                        property real dpr: root.scale
                        property string path: ""
                        property string imagePath: ""
                    }
                }
            }
        }
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

    Component.onCompleted: Qt.callLater(() => step(() => scaleStep(0)))

    // 1. The toolbar and the popover, at each ratio, in each placement.
    function scaleStep(index): void {
        if (index >= scales.length) {
            // Every misplaced item is counted, with one example for each group.
            const groups = {};
            for (const entry of misplaced) {
                groups[entry.group] = groups[entry.group] ?? { count: 0, example: entry.text };
                groups[entry.group].count++;
            }
            check(misplaced.length === 0, misplaced.length + " of " + items + " texts are off the device pixel grid:\n"
                + Object.keys(groups).map(name => groups[name].count + " in " + name + ", for example " + groups[name].example).join("\n"));
            console.log("CAELESTIA_CAPTURE_PIXELS_PASS " + assertions);
            Qt.quit();
            return;
        }
        scale = scales[index];
        state.reset();
        state.inkOpen = false;
        const cases = [
            { name: "below the selection", region: { x: 300, y: 200, width: 500, height: 300 }, drag: null, ink: false, arm: false },
            { name: "above the selection", region: { x: 300.4, y: 640.3, width: 500, height: 240 }, drag: null, ink: false, arm: false },
            { name: "inside the selection", region: { x: 50, y: 30, width: 1500, height: 840 }, drag: null, ink: false, arm: false },
            { name: "after a drag", region: { x: 300, y: 200, width: 500, height: 300 }, drag: { x: 333.37, y: 412.61 }, ink: false, arm: false },
            { name: "with the popover open", region: { x: 300, y: 200, width: 500, height: 300 }, drag: null, ink: true, arm: false },
            { name: "with the popover above the bar", region: { x: 300.4, y: 640.3, width: 500, height: 240 }, drag: { x: 217.77, y: 301.33 }, ink: true, arm: false },
            { name: "with Clear armed", region: { x: 300, y: 200, width: 500, height: 300 }, drag: null, ink: false, arm: true }
        ];
        caseStep(index, cases, 0);
    }

    function caseStep(scaleIndex, cases, caseIndex): void {
        if (caseIndex >= cases.length) {
            cardStep(scaleIndex);
            return;
        }
        const current = cases[caseIndex];
        state.reset();
        root.region = current.region;
        state.barPosition = current.drag;
        state.inkOpen = current.ink;
        if (current.arm)
            state.pressClear();
        // The row layouts position their children when the frame is polished.
        later(150, () => step(() => {
            const bar = toolbar.children.find(child => child.objectName === "editorToolbar");
            const popover = toolbar.children.find(child => child.objectName === "editorInkPopover");
            const label = "toolbar " + current.name;
            check(bar !== undefined && popover !== undefined, "the toolbar and its popover exist");
            // Six tools, undo, redo, Clear, Save, Copy (icon and label), Close.
            // The armed Clear has a label too.
            const all = texts(bar, []);
            checkTexts(all, current.arm ? 14 : 13, label);
            check(popover.visible === current.ink, label + ": the popover is " + (current.ink ? "open" : "closed"));
            if (current.ink)
                checkTexts(texts(popover, []), 3, label + " popover");
            const copy = all.find(item => item.text === "Copy" && item.font.pointSize === Tokens.font.body.small.pointSize);
            check(copy !== undefined, label + ": the Copy label is among them");
            caseStep(scaleIndex, cases, caseIndex + 1);
        }));
    }

    // 2. A settled card of the production stack, with its buttons showing.
    function cardStep(scaleIndex): void {
        state.reset();
        later(900, () => step(() => {
            for (let i = 0; i < 5; i++) {
                const card = cards.itemAt(i);
                check(card.slide === 1 && card.fade === 1 && card.transform[0].x === 0, "card " + i + " has settled");
                const label = "thumbnail card " + i + " of 5";
                // Copy, Save, Show in folder and Close.
                checkTexts(texts(card, []), 4, label);
                const edge = card.mapToItem(null, 0, 0);
                assertions++;
                if (!whole(edge.x * scale) || !whole(edge.y * scale))
                    misplaced.push({ group: label + " at " + scale, text: label + ": the card starts at device " + (edge.x * scale) + ", " + (edge.y * scale) });
            }
            scaleStep(scaleIndex + 1);
        }));
    }
}
