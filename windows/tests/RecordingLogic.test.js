const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");
const logic = {};
vm.runInNewContext(fs.readFileSync(path.join(__dirname, "../shell/adapters/modules/areapicker/RecordingLogic.js"), "utf8"), logic);
const plain = value => JSON.parse(JSON.stringify(value));

test("recording regions scale local coordinates, not monitor offsets", () => {
    for (const dpr of [1, 1.25, 1.5, 1.75, 2]) {
        const screen = { x: -2560, y: 240, width: 1600, height: 900 };
        const r = plain(logic.region({ x: 12, y: 20, width: 101, height: 61 }, screen, dpr));
        assert.equal(r.x, -2560 + Math.round(12 * dpr));
        assert.equal(r.y, 240 + Math.round(20 * dpr));
        assert.equal(r.w % 2, 0);
        assert.equal(r.h % 2, 0);
        const local = logic.localRegion(r, screen, dpr);
        assert.equal(local.x, Math.round(12 * dpr) / dpr);
        assert.equal(local.width, r.w / dpr);
    }
});
test("regions clamp to the selected monitor and reject empty selections", () => {
    const screen = { x: 1920, y: -200, width: 100, height: 100 };
    assert.deepEqual(plain(logic.region({ x: -1, y: -1, width: 102, height: 102 }, screen, 1.5)),
        { x: 1920, y: -200, w: 150, h: 150 });
    assert.equal(logic.region({ x: 20, y: 20, width: 0, height: 0 }, screen, 1), null);
    assert.equal(logic.region({ x: 120, y: 0, width: 5, height: 5 }, screen, 1), null);
    assert.equal(logic.localRegion({ x: 0, y: 0, w: 100, h: 100 }, screen, 1), null);
});
test("timer has MM:SS with no wrap after an hour", () => {
    for (const [elapsed, expected] of [[0, "00:00"], [9.9, "00:09"], [60, "01:00"], [3599, "59:59"], [3600, "60:00"], [-2, "00:00"], [NaN, "00:00"]])
        assert.equal(logic.timer(elapsed), expected);
});
test("the helper receives physical region and no UI, with explicit audio defaults", () => {
    assert.deepEqual(plain(logic.startArgs({ x: -2545, y: 150, w: 152, h: 92 })),
        ["--record", "--region", "-2545,150,152,92", "--no-ui", "--mic", "off", "--system-sound", "off"]);
    assert.equal(logic.startArgs({ x: 0, y: 0, w: 0, h: 10 }), null);
    assert.equal(logic.startArgs({ x: NaN, y: 0, w: 10, h: 10 }), null);
});
