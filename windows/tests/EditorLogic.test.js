const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

const logic = {};
vm.runInNewContext(
    fs.readFileSync(path.join(__dirname, "../shell/adapters/modules/areapicker/EditorLogic.js"), "utf8"),
    logic,
);
const plain = value => JSON.parse(JSON.stringify(value));
// Arrays made inside the vm context have another prototype, so compare as JSON.
const same = (actual, expected, message) => assert.deepEqual(plain(actual), plain(expected), message);
const near = (actual, expected, message) => assert.ok(Math.abs(actual - expected) < 1e-9, `${message}: ${actual} vs ${expected}`);

// ---- placement (windows/capture/src/placement.rs tests) -------------------

const work = { x: 0, y: 0, width: 1920, height: 1080 };

test("the toolbar goes below the selection, then above it", () => {
    const below = logic.controls(work, { x: 300, y: 200, width: 500, height: 300 }, 620, 44, 10, 6);
    same(plain(below), { x: 240, y: 510, inside: false });
    const above = logic.controls(work, { x: 300, y: 700, width: 500, height: 350 }, 620, 44, 10, 6);
    same(plain(above), { x: 240, y: 646, inside: false });
});

test("a full screen selection puts the toolbar inside, above the work area bottom", () => {
    const area = { x: 0, y: 0, width: 1920, height: 1040 };
    const place = logic.controls(area, { x: 0, y: 0, width: 1920, height: 1080 }, 620, 44, 10, 6);
    same(plain(place), { x: 650, y: 990, inside: true });
});

test("the below branch is clamped to a work area that starts under the selection top", () => {
    const area = { x: 0, y: 48, width: 1920, height: 992 };
    const place = logic.controls(area, { x: 100, y: 30, width: 200, height: 5 }, 100, 44, 10, 6);
    assert.equal(place.inside, false);
    assert.equal(place.y, 54);
});

test("the above branch is clamped to a work area that ends above the selection bottom", () => {
    const area = { x: 0, y: 0, width: 1920, height: 1040 };
    const place = logic.controls(area, { x: 100, y: 1045, width: 200, height: 5 }, 100, 44, 10, 6);
    assert.equal(place.inside, false);
    assert.equal(place.y, 990);
});

test("an offset work area on a second monitor keeps the bar on that monitor", () => {
    const second = { x: -1920, y: 48, width: 1920, height: 1032 };
    const place = logic.controls(second, second, 1600, 66, 12, 9);
    same(plain(place), { x: -1760, y: 1002, inside: true });
    // A selection near the left edge of a monitor at a positive offset.
    const right = { x: 2560, y: 0, width: 2560, height: 1440 };
    const near = logic.controls(right, { x: 2562, y: 100, width: 40, height: 40 }, 500, 44, 10, 6);
    assert.equal(near.x, 2566, "the bar keeps the 6 px margin from the left edge");
    assert.equal(near.y, 150);
});

test("an oversized surface starts at the work area edge", () => {
    const small = { x: 100, y: 100, width: 200, height: 200 };
    const place = logic.controls(small, small, 300, 300, 10, 6);
    assert.equal(place.x, 100);
    assert.equal(place.y, 100);
});

test("a dragged toolbar stays inside the work area with the margin", () => {
    same(plain(logic.clampPoint(work, -50, -50, 500, 44, 6)), { x: 6, y: 6 });
    same(plain(logic.clampPoint(work, 5000, 5000, 500, 44, 6)), { x: 1414, y: 1030 });
    same(plain(logic.clampPoint(work, 300, 400, 500, 44, 6)), { x: 300, y: 400 });
    const size = { width: 500, height: 44 };
    same(plain(logic.barPosition(work, { x: 0, y: 0, width: 10, height: 10 }, size, { x: -9, y: 9000 })), { x: 6, y: 1030 });
    same(plain(logic.barPosition(work, { x: 300, y: 200, width: 500, height: 300 }, size, null)), { x: 300, y: 510 });
});

// ---- toolbar layout (windows/capture/src/toolbar.rs) ----------------------

function ids(layout) {
    return layout.items.map(item => item.id);
}

test("the bar lists the six tools, the colour, undo and redo, clear, save, copy and close", () => {
    const layout = logic.barLayout({});
    same(ids(layout), [
        "tool:pencil", "tool:highlighter", "tool:line", "tool:arrow", "tool:rect", "tool:circle",
        "separator", "color", "separator", "undo", "redo", "clear", "separator", "save", "copy", "close"
    ]);
    assert.equal(layout.height, 44);
});

test("buttons are 30 px with 2 px gaps, 8 px between groups and 6 px around separators", () => {
    const layout = logic.barLayout({});
    const x = id => layout.items.find(item => item.id === id).x;
    assert.equal(x("tool:pencil"), 6, "6 px padding");
    assert.equal(x("tool:highlighter") - x("tool:pencil"), 32);
    assert.equal(x("tool:line") - (x("tool:highlighter") + 30), 8, "8 px between groups");
    assert.equal(x("tool:arrow") - x("tool:line"), 32);
    const separators = layout.items.filter(item => item.id === "separator");
    assert.equal(separators.length, 3);
    assert.ok(separators.every(item => item.width === 1 && item.height === 18 && item.y === 13), "1 x 18, centred");
    assert.equal(separators[0].x - (x("tool:circle") + 30), 6);
    assert.equal(x("color") - (separators[0].x + 1), 6);
    assert.ok(layout.items.filter(item => item.id !== "separator").every(item => item.width >= 30 && item.height === 30 && item.y === 7), "30 px buttons, centred");
});

test("the bar's width is the sum of its parts with the padding on both ends", () => {
    const layout = logic.barLayout({});
    const last = layout.items[layout.items.length - 1];
    assert.equal(last.id, "close");
    assert.equal(layout.width, last.x + last.width + 6);
    assert.equal(logic.itemRect(layout, "copy").x - (logic.itemRect(layout, "save").x + 30), 4, "4 px before Copy");
    assert.equal(logic.itemRect(layout, "close").x - (logic.itemRect(layout, "copy").x + logic.itemRect(layout, "copy").width), 4, "4 px before Close");
    assert.equal(layout.width, 508, "with the default Copy width of 69 px");
    assert.equal(logic.barLayout({ copyWidth: 80 }).width, 519, "a wider Copy label widens the bar");
});

test("items never overlap and stay inside the bar", () => {
    for (const options of [{}, { clearArmed: true, clearWidth: 90 }, { showOptions: false }]) {
        const layout = logic.barLayout(options);
        let end = 0;
        for (const item of layout.items) {
            assert.ok(item.x >= end, `${item.id} starts after the previous item ends`);
            end = item.x + item.width;
        }
        assert.ok(end + 6 === layout.width);
    }
});

test("the armed Clear button grows and pushes the rest right; the colour button can be left out", () => {
    const calm = logic.barLayout({});
    const armed = logic.barLayout({ clearArmed: true, clearWidth: 90 });
    assert.equal(logic.itemRect(armed, "clear").width, 90);
    assert.equal(logic.itemRect(calm, "clear").width, 30);
    assert.equal(armed.width - calm.width, 60);
    assert.equal(logic.itemRect(armed, "tool:pencil").x, logic.itemRect(calm, "tool:pencil").x);
    assert.equal(logic.itemRect(logic.barLayout({ showOptions: false }), "color"), null);
});

test("the colour popover has nine colours, a divider and the S, M and L sizes", () => {
    const popover = logic.inkPopover();
    assert.equal(popover.colors.length, 9);
    same(logic.COLORS, ["#FF4444", "#FF8C00", "#FFD700", "#44FF88", "#44AAFF", "#CC44FF", "#FF44CC", "#FFFFFF", "#000000"]);
    same(plain(logic.SIZES), [{ size: 2, label: "S" }, { size: 4, label: "M" }, { size: 7, label: "L" }]);
    assert.equal(popover.width, 268);
    assert.equal(popover.height, 101);
    same(plain(popover.divider), { x: 12, y: 44, width: 244, height: 1 });
    same(plain(popover.track), { x: 12, y: 57, width: 244, height: 32 });
    same(plain(popover.colors[0]), { index: 0, x: 10, y: 10, width: 24, height: 24 });
    assert.equal(popover.colors[1].x - popover.colors[0].x, 28);
    assert.equal(popover.sizes.length, 3);
    near(popover.sizes[0].width, 80, "a third of the track");
    near(popover.sizes[1].x - popover.sizes[0].x, 80, "segment spacing");
    assert.equal(popover.sizes[2].label, "L");
});

test("the popover opens above the bar and below it when there is no room", () => {
    const size = logic.inkPopover();
    const bar = { x: 700, y: 510, width: 508, height: 44 };
    const anchor = { x: 915, y: 517, width: 30, height: 30 };
    const above = logic.popoverPosition(work, bar, anchor, size);
    assert.equal(above.y, 510 - 8 - 101);
    assert.equal(above.x, 930 - 134);
    const top = logic.popoverPosition(work, { x: 700, y: 20, width: 508, height: 44 }, anchor, size);
    assert.equal(top.y, 20 + 44 + 8, "below when above would leave the work area");
    const edge = logic.popoverPosition(work, bar, { x: 0, y: 517, width: 30, height: 30 }, size);
    assert.equal(edge.x, 6, "clamped to the margin");
});

test("the colour button's dot grows with the line size within 9 and 19 px", () => {
    near(logic.dotDiameter(2), 10.6, "S");
    near(logic.dotDiameter(7), 17.1, "L");
    assert.equal(logic.dotDiameter(0.1), 9);
    assert.equal(logic.dotDiameter(50), 19);
});

test("Clear needs two presses", () => {
    same(plain(logic.clearPress(false)), { armed: true, clear: false });
    same(plain(logic.clearPress(true)), { armed: false, clear: true });
    assert.equal(logic.CLEAR_ARM_MS, 2400);
});

// ---- tools and keys --------------------------------------------------------

test("the tools and their keys", () => {
    same(logic.TOOLS.map(tool => tool.id), ["pencil", "highlighter", "line", "arrow", "rect", "circle"]);
    const key = letter => letter.charCodeAt(0);
    same(logic.TOOLS.map(tool => tool.key), ["P", "H", "L", "A", "R", "C"].map(key));
    same(logic.TOOLS.map(tool => tool.group), [0, 0, 1, 1, 1, 1]);
    assert.equal(logic.groupCount(), 2);
    assert.equal(logic.toolById("circle").label, "Circle");
    assert.equal(logic.toolById("text"), null, "Text comes in a later part");
});

test("letters pick tools; Ctrl+C copies instead of choosing the circle", () => {
    const code = letter => letter.charCodeAt(0);
    same(plain(logic.shortcut(code("P"), false, false, false)), { action: "tool", tool: "pencil" });
    same(plain(logic.shortcut(code("C"), false, false, false)), { action: "tool", tool: "circle" });
    same(plain(logic.shortcut(code("C"), true, false, false)), { action: "copy" });
    assert.equal(logic.shortcut(code("P"), false, false, true), null, "Alt+P is not P");
    assert.equal(logic.shortcut(code("T"), false, false, false), null, "Text is not part of this part");
    assert.equal(logic.shortcut(code("Q"), false, false, false), null);
    assert.equal(logic.shortcut(code("P"), true, false, false), null, "Ctrl+P is nothing");
});

test("Ctrl+S saves; Ctrl+Z undoes, Ctrl+Shift+Z and Ctrl+Y redo", () => {
    const code = letter => letter.charCodeAt(0);
    same(plain(logic.shortcut(code("S"), true, false, false)), { action: "save" });
    same(plain(logic.shortcut(code("Z"), true, false, false)), { action: "undo" });
    same(plain(logic.shortcut(code("Z"), true, true, false)), { action: "redo" });
    same(plain(logic.shortcut(code("Y"), true, false, false)), { action: "redo" });
    assert.equal(logic.shortcut(code("S"), false, false, false), null, "plain S does nothing");
    assert.equal(logic.shortcut(logic.KEY_ESCAPE, false, false, false), null, "Escape is handled by the owner");
});

// ---- the undo and redo stack ----------------------------------------------

const line = (x2 = 10) => Object.assign(logic.newStroke("line", "#FF4444", 3, 0, 0), { x2, y2: 0 });

test("undo and redo move a stroke between the two stacks", () => {
    let history = logic.emptyHistory();
    assert.equal(logic.canUndo(history), false);
    assert.equal(logic.canRedo(history), false);
    const a = line(10), b = line(20), c = line(30);
    history = logic.commit(logic.commit(logic.commit(history, a), b), c);
    same(history.strokes.map(s => s.x2), [10, 20, 30]);
    history = logic.undo(history);
    same(history.strokes.map(s => s.x2), [10, 20]);
    same(history.redo.map(s => s.x2), [30]);
    history = logic.undo(logic.undo(history));
    assert.equal(history.strokes.length, 0);
    same(history.redo.map(s => s.x2), [30, 20, 10]);
    assert.equal(logic.canUndo(history), false);
    history = logic.redo(history);
    same(history.strokes.map(s => s.x2), [10], "redo brings back the most recently undone stroke first");
    history = logic.redo(logic.redo(history));
    same(history.strokes.map(s => s.x2), [10, 20, 30]);
    assert.equal(logic.canRedo(history), false);
});

test("undo and redo with nothing to do change nothing", () => {
    const empty = logic.emptyHistory();
    assert.equal(logic.undo(empty), empty);
    assert.equal(logic.redo(empty), empty);
});

test("a new stroke discards the redo stack", () => {
    let history = logic.commit(logic.commit(logic.emptyHistory(), line(1)), line(2));
    history = logic.undo(history);
    assert.equal(logic.canRedo(history), true);
    history = logic.commit(history, line(3));
    assert.equal(logic.canRedo(history), false);
    same(history.strokes.map(s => s.x2), [1, 3]);
});

test("Clear removes everything and cannot be undone", () => {
    let history = logic.commit(logic.commit(logic.emptyHistory(), line(1)), line(2));
    history = logic.undo(history);
    history = logic.clearAll();
    assert.equal(history.strokes.length, 0);
    assert.equal(history.redo.length, 0);
    assert.equal(logic.canUndo(history), false);
    assert.equal(logic.canRedo(history), false);
});

test("history changes return new objects and leave the old ones alone", () => {
    const one = logic.commit(logic.emptyHistory(), line(1));
    const two = logic.commit(one, line(2));
    assert.equal(one.strokes.length, 1);
    assert.equal(two.strokes.length, 2);
    const undone = logic.undo(two);
    assert.equal(two.strokes.length, 2);
    assert.equal(two.redo.length, 0);
    assert.notEqual(undone, two);
});

// ---- drawing -------------------------------------------------------------

test("the pencil is thinner when it moves fast", () => {
    near(logic.pencilWidth(3, 0), 4.8, "still: 1.6 x size");
    near(logic.pencilWidth(3, 20), 1.05, "fast: 0.35 x size");
    near(logic.pencilWidth(3, 400), 1.05, "speed is capped at 20");
    near(logic.pencilWidth(3, 10), 4.8 - 0.5 * (4.8 - 1.05), "halfway");
    near(logic.pencilWidth(1, 20), 1, "never below 1 px");
});


test("a pencil stroke smooths its speed and skips samples under half a physical pixel", () => {
    const draft = logic.startDraft("pencil", "#FF4444", 3, 100, 100);
    assert.equal(draft.stroke.points.length, 1);
    near(draft.stroke.points[0].w, 3, "the first sample has the size as its width");
    same(plain(logic.moveDraft(draft, 100.2, 100, 1)), { changed: false, done: null });
    same(plain(logic.moveDraft(draft, 100.2, 100, 2)), { changed: false, done: null }, "0.4 physical px at 2x");
    assert.equal(draft.stroke.points.length, 1);
    assert.equal(logic.moveDraft(draft, 100.3, 100, 2).changed, true, "0.6 physical px at 2x is kept");
    const fresh = logic.startDraft("pencil", "#FF4444", 3, 0, 0);
    logic.moveDraft(fresh, 10, 0, 1);
    near(fresh.speed, 3 * 0.7 + 10 * 0.3, "smoothed speed");
    near(fresh.stroke.points[1].w, logic.pencilWidth(3, 5.1), "width from the smoothed speed");
});

test("the highlighter keeps its width and never reads speed", () => {
    const draft = logic.startDraft("highlighter", "#FFD700", 4, 0, 0);
    logic.moveDraft(draft, 50, 0, 1);
    logic.moveDraft(draft, 100, 0, 1);
    same(draft.stroke.points.map(p => p.w), [4, 4, 4]);
});

test("a shape follows the pointer with its far corner", () => {
    const draft = logic.startDraft("rect", "#44AAFF", 4, 10, 20);
    same(plain(logic.moveDraft(draft, 60, 90, 1)), { changed: true, done: null });
    same([draft.stroke.x1, draft.stroke.y1, draft.stroke.x2, draft.stroke.y2], [10, 20, 60, 90]);
    same(plain(logic.strokeBounds(draft.stroke)), { x: 10, y: 20, width: 50, height: 70 });
    logic.moveDraft(draft, 0, 5, 1);
    same(plain(logic.strokeBounds(draft.stroke)), { x: 0, y: 5, width: 10, height: 15 }, "any direction");
    assert.equal(draft.stroke.points.length, 0, "a shape has no samples");
});

test("a freehand stroke is cut at 2000 points and carries on from the last one", () => {
    const draft = logic.startDraft("pencil", "#FF4444", 3, 0, 0);
    let done = null;
    let moves = 0;
    while (!done) {
        moves++;
        done = logic.moveDraft(draft, moves * 2, 0, 1).done;
    }
    assert.equal(moves, 2000, "the 2001st point triggers the cut");
    assert.equal(done.points.length, 2001);
    assert.equal(draft.stroke.points.length, 1, "the new stroke begins at the last point");
    assert.notEqual(draft.stroke, done);
    assert.equal(draft.stroke.points[0].x, 4000);
    assert.equal(draft.stroke.tool, "pencil");
});

test("a shape that was never dragged is not kept; a freehand click is", () => {
    assert.equal(logic.isEmpty(logic.newStroke("line", "#FF4444", 3, 5, 5)), true);
    assert.equal(logic.isEmpty(logic.newStroke("circle", "#FF4444", 3, 5, 5)), true);
    const tiny = logic.newStroke("arrow", "#FF4444", 3, 5, 5);
    tiny.x2 = 5.5;
    assert.equal(logic.isEmpty(tiny), true, "less than a pixel");
    tiny.x2 = 7;
    assert.equal(logic.isEmpty(tiny), false);
    assert.equal(logic.isEmpty(logic.startDraft("pencil", "#FF4444", 3, 5, 5).stroke), false, "a pencil click is a dot");
    assert.equal(logic.isEmpty(logic.newStroke("pencil", "#FF4444", 3, 5, 5)), true, "no samples");
});

// ---- shape geometry (windows/capture/src/strokes.rs) ----------------------

test("the arrow head is max(size x 3.5, 10) long with a half angle of pi/5", () => {
    const arrow = Object.assign(logic.newStroke("arrow", "#FF4444", 4, 0, 0), { x2: 100, y2: 0 });
    const geometry = logic.arrowGeometry(arrow);
    near(geometry.head, 14, "size 4 x 3.5");
    near(geometry.shaftEnd.x, 86, "the shaft stops where the head begins");
    near(geometry.shaftEnd.y, 0, "on the axis");
    const [tip, left, right] = geometry.triangle;
    same(plain(tip), { x: 100, y: 0 });
    for (const corner of [left, right]) {
        near(Math.hypot(corner.x - tip.x, corner.y - tip.y), 14, "each corner is a head length from the tip");
        const angle = Math.atan2(corner.y - tip.y, corner.x - tip.x);
        near(Math.abs(Math.abs(angle) - (Math.PI - Math.PI / 5)), 0, "pi/5 off the shaft direction");
    }
    near(left.y, -right.y, "symmetrical");
    const small = Object.assign(logic.newStroke("arrow", "#FF4444", 2, 0, 0), { x2: 100, y2: 0 });
    near(logic.arrowGeometry(small).head, 10, "never shorter than 10");
});

test("an arrow follows any direction", () => {
    const arrow = Object.assign(logic.newStroke("arrow", "#FF4444", 3, 50, 50), { x2: 50, y2: 150 });
    const geometry = logic.arrowGeometry(arrow);
    near(geometry.shaftEnd.x, 50, "straight down");
    near(geometry.shaftEnd.y, 150 - 10.5, "head is 10.5 for size 3");
    near(geometry.triangle[1].y, geometry.triangle[2].y, "the corners sit level");
    near(geometry.triangle[1].x + geometry.triangle[2].x, 100, "centred on the axis");
});

test("an arrow under 2 px draws nothing, and one shorter than its head has no shaft", () => {
    const point = Object.assign(logic.newStroke("arrow", "#FF4444", 3, 0, 0), { x2: 1, y2: 1 });
    assert.equal(logic.arrowGeometry(point), null);
    same(logic.primitives(point), []);
    const stub = Object.assign(logic.newStroke("arrow", "#FF4444", 3, 0, 0), { x2: 6, y2: 0 });
    same(logic.primitives(stub).map(p => p.kind), ["polygon"], "only the head");
    same(plain(logic.arrowGeometry(stub).shaftEnd), { x: 0, y: 0 });
});

test("a circle is centred on the press with the drag distances as radii, at least 1", () => {
    const circle = Object.assign(logic.newStroke("circle", "#FF4444", 3, 100, 100), { x2: 130, y2: 60 });
    same(plain(logic.ellipseGeometry(circle)), { cx: 100, cy: 100, rx: 30, ry: 40 });
    const thin = Object.assign(logic.newStroke("circle", "#FF4444", 3, 100, 100), { x2: 100.2, y2: 100 });
    same(plain(logic.ellipseGeometry(thin)), { cx: 100, cy: 100, rx: 1, ry: 1 });
    assert.equal(logic.ellipseGeometry(logic.newStroke("circle", "#FF4444", 3, 1, 1)), null);
});

test("a rectangle is a closed outline in any drag direction", () => {
    const rect = Object.assign(logic.newStroke("rect", "#FF4444", 3, 80, 90), { x2: 20, y2: 30 });
    same(plain(logic.rectPoints(rect)), [
        { x: 20, y: 30 }, { x: 80, y: 30 }, { x: 80, y: 90 }, { x: 20, y: 90 }, { x: 20, y: 30 }
    ]);
});

test("a smooth path starts and ends on the first and last sample", () => {
    const points = [{ x: 0, y: 0, w: 3 }, { x: 40, y: 0, w: 3 }, { x: 40, y: 40, w: 3 }, { x: 0, y: 40, w: 2 }];
    const path = logic.smoothPath(points);
    same(plain(path.vertices[0]), { x: 0, y: 0 });
    same(plain(path.vertices[path.vertices.length - 1]), { x: 0, y: 40 });
    assert.equal(path.widths.length, path.vertices.length - 1);
    assert.equal(path.widths[path.widths.length - 1], 2, "the last segment has the last sample's width");
    assert.ok(path.vertices.some(v => v.x === 40 && v.y === 20), "the first curve ends at the midpoint of samples 1 and 2");
    assert.ok(path.vertices.every(v => Number.isFinite(v.x) && Number.isFinite(v.y)));
    same(plain(logic.smoothPath([{ x: 1, y: 2, w: 3 }, { x: 4, y: 6, w: 5 }])), { vertices: [{ x: 1, y: 2 }, { x: 4, y: 6 }], widths: [5] });
    same(plain(logic.smoothPath([])), { vertices: [], widths: [] });
});

test("width runs join end to end and group steps of half a pixel", () => {
    const points = [];
    for (let i = 0; i < 40; i++)
        points.push({ x: i * 5, y: Math.sin(i / 3) * 20, w: i < 20 ? 4 : 2 });
    const runs = logic.widthRuns(logic.smoothPath(points));
    assert.ok(runs.length >= 2);
    for (let i = 1; i < runs.length; i++) {
        assert.notEqual(runs[i].width, runs[i - 1].width, "neighbouring runs differ in width");
        const before = runs[i - 1].points[runs[i - 1].points.length - 1];
        same(plain(runs[i].points[0]), plain(before), "a run starts where the last one ended");
    }
    assert.equal(logic.widthRuns({ vertices: [], widths: [] }).length, 0);
    const merged = logic.widthRuns({ vertices: [{ x: 0, y: 0 }, { x: 1, y: 0 }, { x: 2, y: 0 }], widths: [3.1, 3.2] });
    assert.equal(merged.length, 1, "3.1 and 3.2 both round to 3");
    assert.equal(merged[0].width, 3);
});

test("primitives describe each tool for the renderer", () => {
    const dot = logic.primitives(logic.startDraft("pencil", "#FF4444", 3, 5, 6).stroke);
    same(plain(dot), [{ kind: "dot", cx: 5, cy: 6, r: 1.5, color: "#FF4444" }]);

    const pencil = logic.startDraft("pencil", "#44FF88", 3, 0, 0);
    for (let i = 1; i <= 10; i++)
        logic.moveDraft(pencil, i * 4, i % 2 ? 3 : -3, 1);
    const runs = logic.primitives(pencil.stroke);
    assert.ok(runs.length >= 1 && runs.every(r => r.kind === "polyline" && r.cap === "round" && r.alpha === 1 && r.color === "#44FF88" && r.points.length >= 2));

    const marker = logic.startDraft("highlighter", "#FFD700", 3, 0, 0);
    logic.moveDraft(marker, 30, 0, 1);
    logic.moveDraft(marker, 60, 10, 1);
    const marked = logic.primitives(marker.stroke);
    assert.equal(marked.length, 1);
    assert.equal(marked[0].width, 18, "six times the size");
    assert.equal(marked[0].alpha, 0.35);
    assert.equal(marked[0].cap, "square");

    const stroked = Object.assign(logic.newStroke("line", "#FFFFFF", 7, 1, 2), { x2: 30, y2: 40 });
    same(plain(logic.primitives(stroked)), [{ kind: "polyline", points: [{ x: 1, y: 2 }, { x: 30, y: 40 }], width: 7, color: "#FFFFFF", alpha: 1, cap: "round" }]);

    const arrow = Object.assign(logic.newStroke("arrow", "#FF4444", 3, 0, 0), { x2: 100, y2: 0 });
    same(logic.primitives(arrow).map(p => p.kind), ["polyline", "polygon"], "shaft, then head");

    const rect = Object.assign(logic.newStroke("rect", "#000000", 2, 0, 0), { x2: 10, y2: 10 });
    assert.equal(logic.primitives(rect)[0].points.length, 5);

    const circle = Object.assign(logic.newStroke("circle", "#CC44FF", 4, 50, 50), { x2: 60, y2: 50 });
    same(plain(logic.primitives(circle)), [{ kind: "ellipse", cx: 50, cy: 50, rx: 10, ry: 1, width: 4, color: "#CC44FF" }]);

    same(logic.primitives(logic.newStroke("text", "#FF4444", 3, 0, 0)), [], "a tool from a later part draws nothing");
});
