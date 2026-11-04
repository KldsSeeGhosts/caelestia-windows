// Runs the real VramMeter.js. This is not a render or live-hardware check.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const test = require("node:test");
const repo = path.resolve(__dirname, "../..");
const read = file => fs.readFileSync(path.join(repo, file), "utf8").replace(/\r\n/g, "\n");
const GIB = 1024 ** 3;

const meter = {};
// The QML-only ".pragma library" line is the one thing Node cannot parse.
vm.runInNewContext(
    read("windows/shell/adapters/modules/dashboard/performance/VramMeter.js")
        .replace(/^\.pragma library\r?$/m, ""), meter);
const evaluate = (used, total) => JSON.parse(JSON.stringify(meter.evaluate(used, total)));

test("zero used is a real empty meter", () => {
    assert.deepEqual(evaluate(0, 8 * GIB), { valid: true, ratio: 0, usedBytes: 0, totalBytes: 8 * GIB });
});

test("partial and full usage fill the bar in proportion", () => {
    assert.equal(evaluate(2 * GIB, 8 * GIB).ratio, 0.25);
    const full = evaluate(8 * GIB, 8 * GIB);
    assert.equal(full.ratio, 1);
    assert.equal(full.valid, true);
});

test("overflow clamps the bar only and keeps the true figures", () => {
    const over = evaluate(9 * GIB, 8 * GIB);
    assert.equal(over.valid, true);
    assert.equal(over.ratio, 1);
    assert.equal(over.usedBytes, 9 * GIB);
    assert.equal(over.totalBytes, 8 * GIB);
});

test("missing, null, negative, non-finite and zero-total data is rejected", () => {
    const rejected = [
        [undefined, 8 * GIB], [0, undefined], [null, 8 * GIB], [0, null],
        [NaN, 8 * GIB], [0, NaN], [Infinity, 8 * GIB], [0, Infinity], [-Infinity, 8 * GIB],
        [-1, 8 * GIB], [0, -1], [0, 0], [4 * GIB, 0],
        ["4", 8 * GIB], [4 * GIB, "8"], [{}, 8 * GIB],
    ];
    for (const [used, total] of rejected) {
        const result = evaluate(used, total);
        assert.equal(result.valid, false, `${String(used)} / ${String(total)}`);
        assert.equal(result.ratio, 0, "no fabricated fill");
    }
});
