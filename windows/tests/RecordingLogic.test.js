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

test("reload retains overlay windows before status without changing the physical region", () => {
    const source = fs.readFileSync(path.join(__dirname,
        "../shell/adapters/modules/areapicker/RecordingOverlay.qml"), "utf8");
    const regionExpression = source.match(/readonly property var region: ([\s\S]*?)\n    readonly property bool active:/)[1];
    const activeExpression = source.match(/readonly property bool active: (.*)/)[1];
    const remember = source.match(/function remember\(\): void \{([\s\S]*?)^    }/m)[1];
    assert.ok(source.indexOf("PersistentProperties {") < source.indexOf("LazyLoader {"),
        "region restores in the root graph before the window loader adopts its old windows");
    assert.match(source, /reloadableId: "recording-overlay-region"/);
    assert.match(source, /Logic\.localRegion\(root\.region,/);
    for (const dpr of [1, 1.25, 1.5, 1.75, 2]) {
        for (const state of ["recording", "paused", "finalizing"]) {
            const screen = { x: -3840, y: -200, width: 1920, height: 1080 };
            const region = plain(logic.region({ x: 10, y: 12, width: 501, height: 301 }, screen, dpr));
            const context = {
                interactionEnabled: true, observation: { region: null },
                recorder: { baselinePending: false, running: true, state, shellRegion: region },
            };
            vm.createContext(context);
            vm.runInContext(`function remember() {${remember}}
                function currentRegion() { return ${regionExpression}; }
                function activeValue() { const region = currentRegion(); return ${activeExpression}; }`, context);
            context.recorder = { baselinePending: true, running: false, shellRegion: null };
            context.remember();
            assert.equal(context.activeValue(), false, "cold start has no retained recording");
            context.recorder = { baselinePending: false, running: true, state, shellRegion: region };
            context.remember();
            const retained = context.observation.region;
            // A new service has no observation yet. Root PersistentProperties
            // restores the previous region before LazyLoader.onReload runs.
            context.recorder = { baselinePending: true, running: false, shellRegion: null };
            context.remember();
            assert.equal(context.activeValue(), true);
            assert.equal(context.currentRegion(), retained);
            assert.deepEqual(plain(context.currentRegion()), region);
            const selection = logic.localRegion(context.currentRegion(), screen, dpr);
            assert.deepEqual(plain(logic.region(selection, screen, dpr)), region);
            // The first fresh status replaces the retained presentation.
            Object.assign(context.recorder, { baselinePending: false, running: true, shellRegion: region });
            context.remember();
            assert.equal(context.activeValue(), true);
            assert.deepEqual(plain(context.currentRegion()), region);
            context.recorder.running = false;
            context.recorder.shellRegion = null;
            context.remember();
            assert.equal(context.activeValue(), false);
            assert.equal(context.observation.region, null);
            context.observation.region = retained;
            Object.assign(context.recorder, { baselinePending: true, connectionFailed: true });
            context.remember();
            assert.equal(context.activeValue(), false);
            assert.equal(context.observation.region, null);
            Object.assign(context.recorder, { connectionFailed: false, baselinePending: false,
                running: true, shellRegion: null });
            context.remember();
            assert.equal(context.activeValue(), false, "classic recording has no shell overlay");
        }
    }
});
