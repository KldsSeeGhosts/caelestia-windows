const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

const logic = {};
vm.runInNewContext(
    fs.readFileSync(path.join(__dirname, "../shell/adapters/modules/areapicker/ThumbnailLogic.js"), "utf8"),
    logic,
);
const plain = value => JSON.parse(JSON.stringify(value));

test("the thumbnail is on for 5 seconds unless the config says otherwise", () => {
    assert.deepEqual(plain(logic.settings(undefined)), { enabled: true, seconds: 5 });
    assert.deepEqual(plain(logic.settings({})), { enabled: true, seconds: 5 });
    assert.deepEqual(plain(logic.settings({ thumbnail: false })), { enabled: false, seconds: 5 });
    assert.deepEqual(plain(logic.settings({ thumbnail: true, thumbnailSeconds: 10 })), { enabled: true, seconds: 10 });
    assert.deepEqual(plain(logic.settings({ thumbnailSeconds: 0 })), { enabled: true, seconds: 0 });
    assert.deepEqual(plain(logic.settings({ thumbnailSeconds: 2.9 })), { enabled: true, seconds: 2 });
});

test("a value of the wrong type falls back to the default", () => {
    for (const bad of ["no", 0, 1, null, "false"])
        assert.equal(logic.settings({ thumbnail: bad }).enabled, true, String(bad));
    for (const bad of ["3", -1, null, NaN, Infinity, true, {}])
        assert.equal(logic.settings({ thumbnailSeconds: bad }).seconds, 5, String(bad));
});

test("MacShot's default is a 240 x 160 preview with centered 110 x 32 action pills", () => {
    assert.deepEqual(plain(logic.previewSize({ width: 1920, height: 1040 })), { width: 240, height: 160 });
    assert.deepEqual(plain(logic.controls(240, 160, 25)), { pad: 10, corner: 28, icon: 13, buttonHeight: 32, buttonWidth: 110, gap: 8, font: 13 });
});

test("the preferred corner and scale position a stack with the newest at the edge", () => {
    const prefs = logic.appearance({ thumbnailCorner: "top-left", thumbnailScale: 0.5,
        thumbnailStacking: false, thumbnailLetterbox: false });
    const work = { width: 1920, height: 1040 };
    const size = logic.previewSize(work, prefs.scale);
    const rects = logic.stackRects(work, 2, size, prefs.corner);
    assert.deepEqual(plain(rects[1]), { x: 16, y: 16, width: 120, height: 80 });
    assert.ok(rects[0].y > rects[1].y);
    assert.equal(prefs.stack, false);
    assert.equal(prefs.cover, true);
});
test("the width shrinks to fit a narrow work area with a gap on each side", () => {
    assert.deepEqual(plain(logic.previewSize({ width: 200, height: 1040 })), { width: 168, height: 112 });
    assert.equal(logic.previewSize({ width: 10, height: 1040 }).width, 1);
});

test("five previews fit and shrink proportionally on small displays", () => {
    assert.equal(logic.previewSize({ width: 1920, height: 720 }).height, 131);
    for (const height of [300, 480, 720, 1040, 1440]) {
        const work = { width: 1920, height };
        const size = logic.previewSize(work);
        const rects = logic.stackRects(work, 5, size);
        for (const r of rects) {
            assert.ok(r.y >= 0 && r.y + r.height <= height, `height ${height}: ${JSON.stringify(r)}`);
            assert.ok(r.x >= 0 && r.x + r.width <= work.width);
        }
    }
    assert.equal(logic.previewSize({ width: 1920, height: 20 }).height, 1);
});

test("the newest preview is at the bottom right, 16 px from both edges", () => {
    const work = { width: 1920, height: 1040 };
    const size = logic.previewSize(work);
    const rects = logic.stackRects(work, 3, size);
    assert.equal(rects.length, 3);
    // Index 2 is the newest.
    assert.deepEqual(plain(rects[2]), { x: 1920 - 16 - 240, y: 1040 - 16 - 160, width: 240, height: 160 });
    assert.equal(rects[2].x + rects[2].width, work.width - 16);
    assert.equal(rects[2].y + rects[2].height, work.height - 16);
});

test("older previews stack upward with an 8 px gap between them", () => {
    const work = { width: 1920, height: 1040 };
    const size = logic.previewSize(work);
    const rects = logic.stackRects(work, 4, size);
    for (let i = 0; i < 3; i++) {
        assert.equal(rects[i].y + rects[i].height + 8, rects[i + 1].y, `gap above preview ${i + 1}`);
        assert.equal(rects[i].x, rects[i + 1].x);
    }
    assert.deepEqual(plain(logic.stackRects(work, 0, size)), []);
});

test("a one preview stack has the same position as the top of a longer one's newest", () => {
    const work = { width: 800, height: 600 };
    const size = logic.previewSize(work);
    assert.deepEqual(plain(logic.stackRects(work, 1, size)[0]), plain(logic.stackRects(work, 5, size)[4]));
});

test("a work area narrower than a preview still keeps it on the panel", () => {
    const rects = logic.stackRects({ width: 20, height: 600 }, 1, { width: 1, height: 100 });
    assert.ok(rects[0].x >= 0);
});

test("the limit of five previews is global, not per screen", () => {
    assert.deepEqual(plain(logic.evictions(["A", "A", "A", "A"])), []);
    assert.deepEqual(plain(logic.evictions([])), []);
    // Five on A and a new one on B: the oldest, which is on A, goes.
    assert.deepEqual(plain(logic.evictions(["A", "A", "A", "A", "A"])), [0]);
    // Mixed screens count together. Five open, so the oldest goes wherever it is.
    assert.deepEqual(plain(logic.evictions(["B", "A", "A", "B", "A"])), [0]);
    assert.deepEqual(plain(logic.evictions(["A", "B", "B", "B", "B"])), [0]);
    // Four on A and one on B: still five in total.
    assert.deepEqual(plain(logic.evictions(["A", "A", "A", "A", "B"])), [0]);
});

test("more than the limit pushes out as many of the oldest as needed", () => {
    assert.deepEqual(plain(logic.evictions(["A", "B", "A", "B", "A", "B", "A"])), [0, 1, 2]);
});

test("the limit can be changed", () => {
    assert.deepEqual(plain(logic.evictions(["A", "A", "A"], 2)), [0, 1]);
    assert.deepEqual(plain(logic.evictions(["A", "A"], 3)), []);
    assert.deepEqual(plain(logic.evictions(["A"], 1)), [0]);
});

test("each screen still places its own previews from the bottom right", () => {
    // Placement depends only on the screen's work area and its own count.
    const small = { width: 1280, height: 720 };
    const large = { width: 2560, height: 1400 };
    const onSmall = logic.stackRects(small, 2, logic.previewSize(small));
    const onLarge = logic.stackRects(large, 3, logic.previewSize(large));
    assert.equal(onSmall[1].x + onSmall[1].width, small.width - 16);
    assert.equal(onSmall[1].y + onSmall[1].height, small.height - 16);
    assert.equal(onLarge[2].x + onLarge[2].width, large.width - 16);
    assert.equal(onLarge[2].y + onLarge[2].height, large.height - 16);
});

test("the screenshot covers its frame unless letterboxing is explicitly enabled", () => {
    assert.equal(logic.appearance().cover, true);
    assert.equal(logic.appearance({ thumbnailLetterbox: true }).cover, false);
});

test("only a deliberate outward horizontal movement dismisses", () => {
    assert.equal(logic.dismissOffset(10, 1, false), 10);
    assert.equal(logic.dismissOffset(-10, 1, true), 10);
    assert.equal(logic.dismissOffset(-10, 1, false), 0);
    assert.equal(logic.dismissOffset(3, 1, false), 0);
    assert.equal(logic.dismissOffset(7, 25, false), 0);
});

test("only unpaused time counts toward the timeout", () => {
    assert.deepEqual(plain(logic.advance(5000, 20000, true, 6)), { elapsed: 5000, expired: false });
    assert.deepEqual(plain(logic.advance(5000, 1000, false, 6)), { elapsed: 6000, expired: true });
    assert.deepEqual(plain(logic.advance(5000, 999, false, 6)), { elapsed: 5999, expired: false });
});

test("a timeout of 0 never expires", () => {
    assert.equal(logic.advance(0, 1e9, false, 0).expired, false);
    assert.equal(logic.advance(1e9, 0, false, 0).expired, false);
});

test("time never runs backwards", () => {
    assert.equal(logic.advance(1000, -500, false, 6).elapsed, 1000);
});

test("a paused preview stays paused however long the pointer rests on it", () => {
    let state = { elapsed: 0, expired: false };
    for (let i = 0; i < 1000; i++)
        state = logic.advance(state.elapsed, 100, true, 6);
    assert.deepEqual(plain(state), { elapsed: 0, expired: false });
    // Leaving the preview resumes the count where it stopped.
    state = logic.advance(state.elapsed, 6000, false, 6);
    assert.equal(state.expired, true);
});

test("action positions snap to whole pixels at fractional display scales", () => {
    for (const scale of [1, 1.25, 1.5, 1.75, 2]) {
        const position = logic.snap(64.3, scale) * scale;
        assert.ok(Math.abs(position - Math.round(position)) < 1e-6);
    }
});

test("a press becomes a drag once it moves the system distance on either axis", () => {
    const distance = { width: 4, height: 4 };
    const origin = { x: 100, y: 80 };
    assert.equal(logic.dragStarts(origin, { x: 100, y: 80 }, distance, 1), false, "a click that does not move");
    assert.equal(logic.dragStarts(origin, { x: 103, y: 82 }, distance, 1), false, "3 px across, 2 px down is below 4");
    assert.equal(logic.dragStarts(origin, { x: 104, y: 80 }, distance, 1), true, "4 px across");
    assert.equal(logic.dragStarts(origin, { x: 96, y: 80 }, distance, 1), true, "4 px to the left");
    assert.equal(logic.dragStarts(origin, { x: 100, y: 84 }, distance, 1), true, "4 px down");
    assert.equal(logic.dragStarts(origin, { x: 100, y: 76 }, distance, 1), true, "4 px up");
});

test("the drag distance is in device pixels, so a high scale starts the drag sooner", () => {
    const distance = { width: 4, height: 4 };
    const origin = { x: 0, y: 0 };
    // 2 logical px are 3 device px at 150% and 4 at 200%.
    assert.equal(logic.dragStarts(origin, { x: 2, y: 0 }, distance, 1.5), false);
    assert.equal(logic.dragStarts(origin, { x: 2, y: 0 }, distance, 2), true);
    assert.equal(logic.dragStarts(origin, { x: 2.67, y: 0 }, distance, 1.5), true);
});

test("the two axes keep their own distances", () => {
    const distance = { width: 8, height: 2 };
    const origin = { x: 0, y: 0 };
    assert.equal(logic.dragStarts(origin, { x: 7, y: 1 }, distance, 1), false);
    assert.equal(logic.dragStarts(origin, { x: 0, y: 2 }, distance, 1), true);
    assert.equal(logic.dragStarts(origin, { x: 8, y: 0 }, distance, 1), true);
});

test("a missing press, point, distance or scale never starts a drag from nothing", () => {
    assert.equal(logic.dragStarts(null, { x: 50, y: 50 }, { width: 4, height: 4 }, 1), false);
    assert.equal(logic.dragStarts({ x: 0, y: 0 }, undefined, { width: 4, height: 4 }, 1), false);
    // No distance means one device pixel on each axis, and a bad scale means 1.
    assert.equal(logic.dragStarts({ x: 0, y: 0 }, { x: 0, y: 0 }, undefined, 0), false);
    assert.equal(logic.dragStarts({ x: 0, y: 0 }, { x: 1, y: 0 }, undefined, 0), true);
    assert.equal(logic.dragStarts({ x: 0, y: 0 }, { x: 0.5, y: 0 }, { width: 0, height: NaN }, -1), false);
});
