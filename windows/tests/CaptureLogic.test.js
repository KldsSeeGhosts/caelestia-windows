const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

const logic = {};
vm.runInNewContext(
    fs.readFileSync(path.join(__dirname, "../shell/adapters/modules/areapicker/CaptureLogic.js"), "utf8"),
    logic,
);
const plain = value => JSON.parse(JSON.stringify(value));

// Qt hands a QVariantList to QML as a sequence wrapper: it has a length and
// indices but Array.isArray is false for it. The picker must use Array.from.
function sequence(items) {
    const wrapper = { length: items.length };
    items.forEach((item, index) => { wrapper[index] = item; });
    assert.equal(Array.isArray(wrapper), false);
    return wrapper;
}
function entry(id, title, pieces) {
    return { id, title, rects: sequence(pieces.map(([screen, x, y, width, height]) => ({ screen, rect: { x, y, width, height } }))) };
}

const left = { name: "\\\\.\\DISPLAY1", x: -2194, y: 0, width: 2194, height: 1234 };
const right = { name: "\\\\.\\DISPLAY2", x: 0, y: 0, width: 2560, height: 1440 };

test("a drag is any two corners, in any order, clamped to the screen", () => {
    assert.deepEqual(plain(logic.spanRect(100, 80, 40, 20, right)), { x: 40, y: 20, width: 60, height: 60 });
    assert.deepEqual(plain(logic.spanRect(10, 10, 5000, -30, right)), { x: 10, y: 0, width: 2550, height: 10 });
    assert.deepEqual(plain(logic.spanRect(-5, -5, -1, -1, right)), { x: 0, y: 0, width: 0, height: 0 });
});

test("a press inside the dead zone is a click, not a drag", () => {
    assert.equal(logic.isDrag(50, 50, 52, 53), false);
    assert.equal(logic.isDrag(50, 50, 54, 50), true);
    assert.equal(logic.isDrag(50, 50, 50, 46), true);
    assert.equal(logic.isDrag(50, 50, 51, 51, 1), true);
});

test("window pieces are filtered to this screen, shifted to its origin and keep the stack order", () => {
    const stack = sequence([
        entry("a", "Front", [[right.name, 100, 100, 500, 400]]),
        entry("b", "Spans both", [[left.name, -300, 50, 300, 200], [right.name, 0, 50, 200, 200]]),
        entry("c", "Other screen only", [[left.name, -2000, 600, 100, 100]]),
    ]);
    const onRight = logic.screenWindows(stack, right);
    assert.deepEqual(plain(onRight.map(w => w.id)), ["a", "b"]);
    assert.deepEqual(plain(onRight[1].rect), { x: 0, y: 50, width: 200, height: 200 });
    const onLeft = logic.screenWindows(stack, left);
    assert.deepEqual(plain(onLeft.map(w => w.id)), ["b", "c"]);
    // x is global -300 on a screen that starts at -2194: 1894 from its left edge.
    assert.deepEqual(plain(onLeft[0].rect), { x: 1894, y: 50, width: 300, height: 200 });
    assert.equal(onLeft[1].title, "Other screen only");
});

test("a window piece is clipped to the screen and an empty piece is dropped", () => {
    const stack = sequence([
        entry("big", "", [[right.name, -50, -50, 5000, 5000]]),
        entry("off", "", [[right.name, 3000, 0, 100, 100]]),
        entry("thin", "", [[right.name, 10, 10, 0.4, 100]]),
    ]);
    const list = logic.screenWindows(stack, right);
    assert.deepEqual(plain(list.map(w => w.id)), ["big"]);
    assert.deepEqual(plain(list[0].rect), { x: 0, y: 0, width: 2560, height: 1440 });
});

test("a missing or malformed stack gives no windows", () => {
    assert.deepEqual(plain(logic.screenWindows(null, right)), []);
    assert.deepEqual(plain(logic.screenWindows(sequence([]), right)), []);
    assert.deepEqual(plain(logic.screenWindows(sequence([null, { id: "x" }, { id: "y", rects: sequence([{ screen: right.name }]) }]), right)), []);
});

test("the topmost window under the cursor wins; the edge belongs to the left and top", () => {
    const stack = sequence([
        entry("front", "Front", [[right.name, 200, 200, 300, 300]]),
        entry("back", "Back", [[right.name, 100, 100, 800, 600]]),
    ]);
    const windows = logic.screenWindows(stack, right);
    assert.equal(logic.hitWindow(windows, 250, 250).id, "front");
    assert.equal(logic.hitWindow(windows, 150, 150).id, "back");
    assert.equal(logic.hitWindow(windows, 200, 200).id, "front");
    assert.equal(logic.hitWindow(windows, 500, 250).id, "back", "right edge is outside the front window");
    assert.equal(logic.hitWindow(windows, 50, 50), null);
});

test("with no window under the cursor the whole monitor is the target", () => {
    const windows = logic.screenWindows(sequence([entry("w", "W", [[right.name, 100, 100, 200, 200]])]), right);
    const hit = logic.targetAt(windows, 150, 150, right);
    assert.equal(hit.kind, "window");
    assert.deepEqual(plain(hit.rect), { x: 100, y: 100, width: 200, height: 200 });
    const miss = logic.targetAt(windows, 1000, 900, right);
    assert.equal(miss.kind, "monitor");
    assert.deepEqual(plain(miss.rect), { x: 0, y: 0, width: 2560, height: 1440 });
    assert.equal(logic.targetAt([], 5, 5, left).kind, "monitor");
    assert.equal(logic.hitWindow([], 5, 5), null);
    assert.deepEqual(plain(logic.targetAt([], 5, 5, left).rect), { x: 0, y: 0, width: 2194, height: 1234 });
});

test("the saved rectangle never grows past the selection and stays on the screen", () => {
    assert.deepEqual(plain(logic.logicalExport({ x: 10.2, y: 20.7, width: 50.9, height: 30.1 }, right)),
        { x: 11, y: 21, width: 50, height: 29 });
    assert.deepEqual(plain(logic.logicalExport({ x: 0, y: 0, width: 2560, height: 1440 }, right)),
        { x: 0, y: 0, width: 2560, height: 1440 });
    assert.deepEqual(plain(logic.logicalExport({ x: 2500, y: 1400, width: 400, height: 400 }, right)),
        { x: 2500, y: 1400, width: 60, height: 40 });
    assert.equal(logic.logicalExport({ x: 10, y: 10, width: 0.9, height: 20 }, right), null);
    assert.equal(logic.logicalExport({ x: 3000, y: 10, width: 20, height: 20 }, right), null);
});

test("export arithmetic matches CUtils.saveItem for the display scale", () => {
    const logical = { x: 11, y: 21, width: 50, height: 29 };
    assert.deepEqual(plain(logic.physicalExport(logical, 1)), logical);
    // 11 * 1.5 = 16.5 rounds to 17, 21 * 1.5 = 31.5 to 32, 29 * 1.5 = 43.5 to 44.
    assert.deepEqual(plain(logic.physicalExport(logical, 1.5)), { x: 17, y: 32, width: 75, height: 44 });
    assert.deepEqual(plain(logic.physicalExport(logical, 2)), { x: 22, y: 42, width: 100, height: 58 });
    assert.deepEqual(plain(logic.grabSize(left, 1.75)), { width: 3840, height: 2160 });
});

test("a full-screen selection fits the grabbed image at every common scale", () => {
    for (const [screen, dpr] of [[right, 1], [right, 1.25], [right, 1.5], [right, 2], [left, 1.75], [left, 1.25]]) {
        const plan = logic.exportPlan({ x: 0, y: 0, width: screen.width, height: screen.height }, screen, dpr);
        assert.equal(plan.valid, true, `${screen.width}x${screen.height} at ${dpr}`);
        assert.ok(plan.physical.x + plan.physical.width <= plan.image.width);
        assert.ok(plan.physical.y + plan.physical.height <= plan.image.height);
    }
});

test("a rectangle whose rounding passes the image edge is shortened by one pixel", () => {
    // 666 logical px at 1.5 is a 999 px image. Origin 1 rounds to 2 and size 665
    // rounds to 998, so the far edge would be 1000, one pixel past the image.
    const screen = { name: "s", x: 0, y: 0, width: 666, height: 100 };
    const plan = logic.exportPlan({ x: 1, y: 0, width: 665, height: 100 }, screen, 1.5);
    assert.deepEqual(plain(plan.image), { width: 999, height: 150 });
    assert.equal(plan.valid, true);
    assert.deepEqual(plain(plan.logical), { x: 1, y: 0, width: 664, height: 100 });
    assert.deepEqual(plain(plan.physical), { x: 2, y: 0, width: 996, height: 150 });
    const same = logic.exportPlan({ x: 0, y: 0, width: 666, height: 100 }, screen, 1.5);
    assert.deepEqual(plain(same.logical), { x: 0, y: 0, width: 666, height: 100 });
    assert.equal(logic.exportPlan({ x: 5, y: 5, width: 0, height: 0 }, screen, 1).valid, false);
});

test("an exported rectangle is always inside the image, for every width at common scales", () => {
    for (const dpr of [1, 1.25, 1.5, 1.75, 2]) {
        for (let width = 3; width <= 40; width++) {
            const screen = { name: "s", x: 0, y: 0, width, height: 9 };
            for (let x = 0; x < width; x++) {
                const plan = logic.exportPlan({ x, y: 0, width: width - x, height: 9 }, screen, dpr);
                if (!plan.valid)
                    continue;
                assert.ok(plan.physical.x + plan.physical.width <= plan.image.width, `w=${width} x=${x} dpr=${dpr}`);
            }
            const full = logic.exportPlan({ x: 0, y: 0, width, height: 9 }, screen, dpr);
            assert.equal(full.valid, true, `full w=${width} dpr=${dpr}`);
        }
    }
});

test("the tint waits until every screen has frozen content", () => {
    const names = [left.name, right.name];
    assert.equal(logic.allReady({}, names), false);
    assert.equal(logic.allReady({ [left.name]: true }, names), false);
    assert.equal(logic.allReady({ [left.name]: true, [right.name]: false }, names), false);
    assert.equal(logic.allReady({ [left.name]: true, [right.name]: true }, names), true);
    assert.equal(logic.allReady({ [left.name]: true }, [left.name]), true);
    assert.equal(logic.allReady({ [left.name]: true }, []), false);
    assert.equal(logic.allReady(null, names), false);
});

test("file names follow the current tool's default and number duplicates from (2)", () => {
    const date = new Date(2026, 10, 8, 9, 5, 3);
    assert.equal(logic.fileStem(date, ""), "annotate-2026-11-08_09-05-03");
    assert.equal(logic.fileStem(date, "   "), "annotate-2026-11-08_09-05-03");
    assert.equal(logic.fileStem(date, "shot %Y%m%d"), "shot 20261108");
    assert.equal(logic.fileStem(date, "a/b:c"), "a_b_c");
    assert.equal(logic.fileStem(date, "..."), "annotate-2026-11-08_09-05-03");
    const taken = new Set();
    const exists = p => taken.has(p);
    const dir = "C:/Users/me/Pictures/Screenshots/";
    const first = logic.uniquePath(dir, "annotate-x", exists);
    assert.equal(first, "C:/Users/me/Pictures/Screenshots/annotate-x.png");
    taken.add(first);
    const second = logic.uniquePath(dir, "annotate-x", exists);
    assert.equal(second, "C:/Users/me/Pictures/Screenshots/annotate-x (2).png");
    taken.add(second);
    assert.equal(logic.uniquePath("C:\\Pics", "annotate-x", exists), "C:/Pics/annotate-x.png");
    assert.equal(logic.uniquePath(dir, "annotate-x", exists), "C:/Users/me/Pictures/Screenshots/annotate-x (3).png");
});

test("IPC function names keep their upstream meaning", () => {
    assert.deepEqual(plain(logic.pickerOptions("open")), { freeze: false, clipboardOnly: false });
    assert.deepEqual(plain(logic.pickerOptions("openFreeze")), { freeze: true, clipboardOnly: false });
    assert.deepEqual(plain(logic.pickerOptions("openClip")), { freeze: false, clipboardOnly: true });
    assert.deepEqual(plain(logic.pickerOptions("openFreezeClip")), { freeze: true, clipboardOnly: true });
    assert.equal(logic.pickerOptions("nope"), null);
});

test("only an explicit shell setting with the bundled helper or none selects the QML picker", () => {
    const bundled = "C:/Program Files/Caelestia/caelestia-capture.exe";
    assert.equal(logic.captureRoute(undefined, bundled), "classic");
    assert.equal(logic.captureRoute("classic", bundled), "classic");
    assert.equal(logic.captureRoute("SHELL", bundled), "classic");
    assert.equal(logic.captureRoute(true, bundled), "classic");
    assert.equal(logic.captureRoute("shell", bundled), "shell");
    assert.equal(logic.captureRoute("shell", "C:\\Caelestia\\CAELESTIA-CAPTURE.EXE"), "shell");
    assert.equal(logic.captureRoute("shell", ""), "shell");
    assert.equal(logic.captureRoute("shell", "C:/Apps/Glazier/glazier.exe"), "classic", "a legacy override stays classic");
    assert.equal(logic.captureRoute("shell", "C:/Apps/other-caelestia-capture.exe"), "classic");
});
