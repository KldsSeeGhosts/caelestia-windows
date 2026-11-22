const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const logic = vm.createContext({});
vm.runInContext(fs.readFileSync(path.join(__dirname, "../shell/adapters/modules/areapicker/HistoryLogic.js"), "utf8"), logic);

function row(hex, width = 800, height = 600) {
    const id = hex.repeat(32);
    return { id, raw: `${id}.png`, image: `${id}.png`, info: { width, height }, created: 1, updated: 1, strokes: [], canvasWidth: 0 };
}

test("Quick Capture copies by default, with independent, bounded history", () => {
    assert.equal(logic.settings({}).mode, "copy");
    assert.equal(logic.settings({ quickCapture: "preview" }).mode, "preview");
    assert.equal(logic.settings({ historyLimit: 0 }).limit, 0);
    assert.equal(logic.settings({ historyLimit: 200 }).limit, 50);
});

test("the cache won't interpret an index path as a file it owns", () => {
    const valid = row("a");
    const invalid = row("b");
    invalid.image = "../Screenshots/export.png";
    const index = JSON.stringify({ version: 1, rows: [valid, invalid, valid] });
    assert.equal(logic.decode(index).length, 1);
    assert.equal(logic.decode("not an index"), null);
});

test("an edited capture is charged for its source and its rendered PNG", () => {
    const a = row("a");
    const b = row("b");
    b.image = `${"c".repeat(32)}.png`;
    assert.ok(logic.cost(b) > logic.cost(a));
    assert.equal(logic.bounded([a, b], 10, logic.cost(a) + logic.cost(b) - 1).length, 1);
    assert.equal(logic.bounded([a, b], 1, Infinity).length, 1);
    assert.equal(logic.bounded([a, b], 0, Infinity).length, 0);
    assert.deepEqual(Array.from(logic.ownedFiles([a, b])), [a.raw, b.raw, b.image]);
});
