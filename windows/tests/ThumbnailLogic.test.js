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

test("the thumbnail is on for 6 seconds unless the config says otherwise", () => {
    assert.deepEqual(plain(logic.settings(undefined)), { enabled: true, seconds: 6 });
    assert.deepEqual(plain(logic.settings({})), { enabled: true, seconds: 6 });
    assert.deepEqual(plain(logic.settings({ thumbnail: false })), { enabled: false, seconds: 6 });
    assert.deepEqual(plain(logic.settings({ thumbnail: true, thumbnailSeconds: 10 })), { enabled: true, seconds: 10 });
    assert.deepEqual(plain(logic.settings({ thumbnailSeconds: 0 })), { enabled: true, seconds: 0 });
    assert.deepEqual(plain(logic.settings({ thumbnailSeconds: 2.9 })), { enabled: true, seconds: 2 });
});

test("a value of the wrong type falls back to the default", () => {
    for (const bad of ["no", 0, 1, null, "false"])
        assert.equal(logic.settings({ thumbnail: bad }).enabled, true, String(bad));
    for (const bad of ["3", -1, null, NaN, Infinity, true, {}])
        assert.equal(logic.settings({ thumbnailSeconds: bad }).seconds, 6, String(bad));
});

test("a preview is 260 x 174 on a roomy work area", () => {
    assert.deepEqual(plain(logic.previewSize({ width: 1920, height: 1040 })), { width: 260, height: 174 });
});

test("the width shrinks to fit a narrow work area with a gap on each side", () => {
    assert.deepEqual(plain(logic.previewSize({ width: 200, height: 1040 })), { width: 176, height: 174 });
    assert.equal(logic.previewSize({ width: 10, height: 1040 }).width, 1);
});

test("the height is a fifth of the room left after six gaps, so five previews fit", () => {
    // (720 - 72) / 5 = 129.6, floored.
    assert.equal(logic.previewSize({ width: 1920, height: 720 }).height, 129);
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

test("the newest preview is at the bottom right, 12 px from both edges", () => {
    const work = { width: 1920, height: 1040 };
    const size = logic.previewSize(work);
    const rects = logic.stackRects(work, 3, size);
    assert.equal(rects.length, 3);
    // Index 2 is the newest.
    assert.deepEqual(plain(rects[2]), { x: 1920 - 12 - 260, y: 1040 - 12 - 174, width: 260, height: 174 });
    assert.equal(rects[2].x + rects[2].width, work.width - 12);
    assert.equal(rects[2].y + rects[2].height, work.height - 12);
});

test("older previews stack upward with a 12 px gap between them", () => {
    const work = { width: 1920, height: 1040 };
    const size = logic.previewSize(work);
    const rects = logic.stackRects(work, 4, size);
    for (let i = 0; i < 3; i++) {
        assert.equal(rects[i].y + rects[i].height + 12, rects[i + 1].y, `gap above preview ${i + 1}`);
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
    assert.equal(onSmall[1].x + onSmall[1].width, small.width - 12);
    assert.equal(onSmall[1].y + onSmall[1].height, small.height - 12);
    assert.equal(onLarge[2].x + onLarge[2].width, large.width - 12);
    assert.equal(onLarge[2].y + onLarge[2].height, large.height - 12);
});

test("the image is fitted 20 px in from every edge and never scaled up", () => {
    const card = { width: 260, height: 174 };
    // A screenshot far larger than the card: the 220 x 134 box limits it.
    assert.deepEqual(plain(logic.fitImage(card, { width: 1920, height: 1080 }, 1)), { width: 220, height: 124, known: true });
    // A tall one is limited by the height.
    assert.deepEqual(plain(logic.fitImage(card, { width: 500, height: 1000 }, 1)), { width: 67, height: 134, known: true });
    // A small one keeps its size.
    assert.deepEqual(plain(logic.fitImage(card, { width: 60, height: 40 }, 1)), { width: 60, height: 40, known: true });
});

test("the image size is in physical pixels, so a 2x screen halves it", () => {
    const card = { width: 260, height: 174 };
    assert.deepEqual(plain(logic.fitImage(card, { width: 120, height: 80 }, 2)), { width: 60, height: 40, known: true });
    assert.deepEqual(plain(logic.fitImage(card, { width: 600, height: 400 }, 1.5)), { width: 201, height: 134, known: true });
});

test("an unknown image size fills the inner box", () => {
    const card = { width: 260, height: 174 };
    assert.deepEqual(plain(logic.fitImage(card, null, 1)), { width: 220, height: 134, known: false });
    assert.deepEqual(plain(logic.fitImage(card, { width: 0, height: 0 }, 1)), { width: 220, height: 134, known: false });
    assert.equal(logic.fitImage({ width: 30, height: 30 }, { width: 100, height: 100 }, 1).width >= 1, true);
});

test("a bad ratio counts as 1", () => {
    const card = { width: 260, height: 174 };
    assert.deepEqual(plain(logic.fitImage(card, { width: 60, height: 40 }, 0)), { width: 60, height: 40, known: true });
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

test("Save is offered only for a capture that was not saved", () => {
    assert.deepEqual(plain(logic.actions(false)), ["copy", "save", "reveal", "close"]);
    assert.deepEqual(plain(logic.actions(true)), ["copy", "reveal", "close"]);
});

test("the button pill is centred and 9 px above the bottom edge", () => {
    const card = { width: 260, height: 174 };
    // Four 30 px buttons, three 2 px gaps and 3 px of padding on each side.
    assert.deepEqual(plain(logic.pillRect(card, 4)), { x: 64, y: 174 - 9 - 36, width: 132, height: 36 });
    // Three buttons: 90 + 4 + 6 = 100 wide.
    assert.deepEqual(plain(logic.pillRect(card, 3)), { x: 80, y: 129, width: 100, height: 36 });
});

test("the pill fits the smallest card", () => {
    const size = logic.previewSize({ width: 1920, height: 720 });
    const pill = logic.pillRect(size, 4);
    assert.ok(pill.x >= 0 && pill.x + pill.width <= size.width);
    assert.ok(pill.y >= 0 && pill.y + pill.height <= size.height);
});
