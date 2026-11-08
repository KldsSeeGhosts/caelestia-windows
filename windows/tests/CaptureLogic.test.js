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

// QRectF::toRect in Qt 6.11.2 (qrect.h): nx = round(x); nw = round(w + (x - nx) / 2),
// halves rounding up. This reference uses exact integer arithmetic with the scale
// given in percent, so it does not share floating point behaviour with the code
// under test. Returns the one dimension [origin, size] for a logical [x, w].
function nativeSpan(x, w, percent) {
    const nx = Math.floor((2 * x * percent + 100) / 200);
    const n = 2 * w * percent + x * percent - 100 * nx;
    return [nx, Math.floor((n + 100) / 200)];
}

test("export arithmetic is Qt's QRectF::toRect over the scaled rectangle", () => {
    const logical = { x: 11, y: 21, width: 50, height: 29 };
    assert.deepEqual(plain(logic.physicalExport(logical, 1)), logical);
    // 11 * 1.5 = 16.5 rounds to 17 and the width 75 loses half of 0.5: 74.75 is 75.
    // 21 * 1.5 = 31.5 rounds to 32 and 43.5 - 0.25 = 43.25 is 43.
    assert.deepEqual(plain(logic.physicalExport(logical, 1.5)), { x: 17, y: 32, width: 75, height: 43 });
    assert.deepEqual(plain(logic.physicalExport(logical, 2)), { x: 22, y: 42, width: 100, height: 58 });
    assert.deepEqual(plain(logic.grabSize(left, 1.75)), { width: 3840, height: 2160 });
    for (const percent of [125, 150, 175, 200, 225]) {
        for (let x = 0; x < 40; x++) {
            for (let w = 1; w < 40; w++) {
                const got = logic.physicalExport({ x, y: x, width: w, height: w }, percent / 100);
                const [nx, nw] = nativeSpan(x, w, percent);
                assert.deepEqual([got.x, got.width, got.y, got.height], [nx, nw, nx, nw], `x=${x} w=${w} at ${percent}%`);
            }
        }
    }
});

test("a full-screen selection fits the grabbed image at every common scale", () => {
    for (const [screen, dpr] of [[right, 1], [right, 1.25], [right, 1.5], [right, 2], [left, 1.75], [left, 1.25]]) {
        const plan = logic.exportPlan({ x: 0, y: 0, width: screen.width, height: screen.height }, screen, dpr);
        assert.equal(plan.valid, true, `${screen.width}x${screen.height} at ${dpr}`);
        assert.deepEqual(plain(plan.physical), { x: 0, y: 0, width: plan.image.width, height: plan.image.height });
    }
});

test("a selection that already fits is never shortened (2560 wide at 150%)", () => {
    const screen = { name: "s", x: 0, y: 0, width: 2560, height: 1440 };
    const plan = logic.exportPlan({ x: 1, y: 0, width: 2559, height: 1440 }, screen, 1.5);
    assert.deepEqual(plain(plan.image), { width: 3840, height: 2160 });
    // Native origin 2, width 3838.5 - 0.25 rounds to 3838, so the edge is exactly 3840.
    assert.deepEqual(plain(plan.logical), { x: 1, y: 0, width: 2559, height: 1440 });
    assert.deepEqual(plain(plan.physical), { x: 2, y: 0, width: 3838, height: 2160 });
    assert.deepEqual(plain(plan.crop), { x: 2, y: 0, width: 3838, height: 2160 });
    assert.equal(plan.valid, true);
});

test("the native crop at the right and bottom edges, at 125% and 175%", () => {
    const cases = [
        // [screen width, height, scale, inset, expected native crop, image]
        [2048, 1152, 1.25, 1, { x: 1, y: 1, width: 2559, height: 1439 }, { width: 2560, height: 1440 }],
        [2048, 1152, 1.25, 2, { x: 3, y: 3, width: 2557, height: 1437 }, { width: 2560, height: 1440 }],
        [2048, 1152, 1.25, 3, { x: 4, y: 4, width: 2556, height: 1436 }, { width: 2560, height: 1440 }],
        [1920, 1080, 1.75, 1, { x: 2, y: 2, width: 3358, height: 1888 }, { width: 3360, height: 1890 }],
        [1920, 1080, 1.75, 2, { x: 4, y: 4, width: 3356, height: 1886 }, { width: 3360, height: 1890 }],
        [1920, 1080, 1.75, 3, { x: 5, y: 5, width: 3355, height: 1885 }, { width: 3360, height: 1890 }],
    ];
    for (const [width, height, dpr, inset, physical, image] of cases) {
        const screen = { name: "s", x: 0, y: 0, width, height };
        const plan = logic.exportPlan({ x: inset, y: inset, width: width - inset, height: height - inset }, screen, dpr);
        assert.deepEqual(plain(plan.image), image, `${width} at ${dpr}`);
        assert.deepEqual(plain(plan.physical), physical, `${width} at ${dpr}, inset ${inset}`);
        assert.deepEqual(plain(plan.logical), { x: inset, y: inset, width: width - inset, height: height - inset }, "not shortened");
        assert.deepEqual(plain(plan.crop), physical, "and nothing is clipped");
        assert.equal(plan.valid, true);
    }
});

test("a native crop that passes the image edge is clipped to the image, not shortened", () => {
    // 1537 logical px at 125% is a 1921 px image (1921.25). Origin 2 gives native
    // x 3 (2.5 rounds up); 1535 * 1.25 = 1918.75 - 0.25 = 1918.5 rounds to 1919, so
    // Qt's crop ends at 1922. The image has 1918 columns from 3 on, and all are saved.
    const wide = { name: "s", x: 0, y: 0, width: 1537, height: 100 };
    const plan = logic.exportPlan({ x: 2, y: 0, width: 1535, height: 100 }, wide, 1.25);
    assert.deepEqual(plain(plan.image), { width: 1921, height: 125 });
    assert.deepEqual(plain(plan.logical), { x: 2, y: 0, width: 1535, height: 100 });
    assert.deepEqual(plain(plan.physical), { x: 3, y: 0, width: 1919, height: 125 });
    assert.deepEqual(plain(plan.crop), { x: 3, y: 0, width: 1918, height: 125 });
    assert.equal(plan.valid, true);

    // The sliver: the last logical column of a 1003 px screen at 175%. The image is
    // 1755 px (1755.25) and Qt's crop is [1754, 1756), one valid column.
    const sliver = { name: "s", x: 0, y: 0, width: 1003, height: 10 };
    const edge = logic.exportPlan({ x: 1002, y: 0, width: 1, height: 10 }, sliver, 1.75);
    assert.deepEqual(plain(edge.image), { width: 1755, height: 18 });
    assert.deepEqual(plain(edge.physical), { x: 1754, y: 0, width: 2, height: 18 });
    assert.deepEqual(plain(edge.crop), { x: 1754, y: 0, width: 1, height: 18 });
    assert.equal(edge.valid, true);

    // A crop wholly outside the image is not a selection.
    const outside = { name: "s", x: 0, y: 0, width: 5, height: 4 };
    assert.equal(logic.exportPlan({ x: 4, y: 0, width: 1, height: 4 }, outside, 1.75).valid, true);
    assert.equal(logic.exportPlan({ x: 5, y: 5, width: 0, height: 0 }, outside, 1).valid, false);
});

test("the saved crop is Qt's crop intersected with the image, at every origin and scale", () => {
    for (const percent of [100, 125, 150, 175, 200, 225]) {
        const dpr = percent / 100;
        for (let width = 2; width <= 60; width++) {
            const screen = { name: "s", x: 0, y: 0, width, height: 9 };
            const image = logic.grabSize(screen, dpr);
            for (let x = 0; x < width; x++) {
                const plan = logic.exportPlan({ x, y: 0, width: width - x, height: 9 }, screen, dpr);
                assert.deepEqual(plain(plan.logical), { x, y: 0, width: width - x, height: 9 }, "the logical rectangle is never shortened");
                const [nx, nw] = percent === 100 ? [x, width - x] : nativeSpan(x, width - x, percent);
                const first = Math.max(0, nx);
                const end = Math.min(nx + nw, image.width);
                if (end - first < 1) {
                    assert.equal(plan.valid, false, `w=${width} x=${x} at ${percent}%`);
                    continue;
                }
                assert.equal(plan.valid, true, `w=${width} x=${x} at ${percent}%`);
                // No valid column is lost: the crop starts where Qt's does and ends at
                // the nearer of Qt's end and the image edge.
                assert.equal(plan.crop.x, first, `w=${width} x=${x} at ${percent}%`);
                assert.equal(plan.crop.x + plan.crop.width, end, `w=${width} x=${x} at ${percent}%`);
                assert.ok(plan.crop.x + plan.crop.width <= image.width);
            }
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

test("the same monitors are recognised in any order", () => {
    assert.equal(logic.sameNames(["a", "b"], ["b", "a"]), true);
    assert.equal(logic.sameNames(["a"], ["a", "b"]), false);
    assert.equal(logic.sameNames(["a", "b"], ["a", "c"]), false);
    assert.equal(logic.sameNames([], []), true);
    assert.equal(logic.sameNames(sequence(["a"]), ["a"]), true);
    assert.equal(logic.sameNames(null, ["a"]), false);
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
    assert.deepEqual(plain(logic.pickerOptions("open")), { freeze: false });
    assert.deepEqual(plain(logic.pickerOptions("openFreeze")), { freeze: true });
    assert.deepEqual(plain(logic.pickerOptions("openClip")), { freeze: false });
    assert.deepEqual(plain(logic.pickerOptions("openFreezeClip")), { freeze: true });
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
