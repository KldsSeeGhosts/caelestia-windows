const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

const source = fs.readFileSync(path.join(__dirname, "../services/clipboard/ClipboardHistory.js"), "utf8");
function load(text = source) {
    const urls = vm.createContext({});
    const urlSource = fs.readFileSync(path.join(__dirname, "../shell/adapters/utils/FileUrls.js"), "utf8");
    vm.runInContext(urlSource.replace(/^\s*\.pragma library\s*$/gm, ""), urls,
        { filename: "production/FileUrls.js" });
    const context = vm.createContext({ FileUrls: urls });
    vm.runInContext(text.replace(/^\s*\.import[^\r\n]*$/gm, ""), context,
        { filename: "production/ClipboardHistory.js" });
    return context;
}
const model = load();
const entry = (id, text = id) => ({ id, kind: "text", text });
const ids = rows => Array.from(rows, row => row.itemId);

test("clipboard selection follows the item across insert, reorder and delayed snapshot replacement", () => {
    const original = model.displayRows([entry("a"), entry("selected"), entry("c")], "", 60);
    const selected = original[1].itemId;
    const refreshed = model.displayRows([entry("new"), entry("c"), entry("a"), entry("selected")], "", 60);
    const index = model.selectionIndex(selected, 1, refreshed);
    assert.equal(index, 3);
    assert.equal(refreshed[index].itemId, selected, "Delete/copy must still target the selected ID");
    // This is a new object, not the old snapshot object.
    const delayed = model.displayRows([entry("selected", "completed preview"), entry("a")], "", 60);
    assert.equal(delayed[model.selectionIndex(selected, index, delayed)].fullText, "completed preview");
});

test("clipboard selection removal, filtering and empty snapshots use a bounded fallback", () => {
    const rows = model.displayRows([entry("a"), entry("b"), entry("c")], "b", 60);
    assert.deepEqual(ids(rows), ["b"]);
    assert.equal(model.selectionIndex("removed", 9, rows), 0);
    assert.equal(model.selectionIndex("removed", -9, rows), 0);
    assert.equal(model.selectionIndex("", NaN, rows), 0);
    assert.equal(model.selectionIndex("b", 0, model.displayRows([], "", 60)), -1);
    assert.equal(model.selectionIndex("b", 0, model.displayRows([entry("b")], "no match", 60)), -1);
});

test("clipboard QVariantList-like snapshots preserve identity and reject malformed rows", () => {
    const sequence = { 0: null, 1: {}, 2: entry("a"), 3: entry("b"), length: 4 };
    const rows = model.displayRows(sequence, "", 60);
    assert.deepEqual(ids(rows), ["a", "b"]);
    assert.equal(model.selectionIndex("b", 0, { 0: rows[0], 1: rows[1], length: 2 }), 1);
    assert.deepEqual(ids(model.displayRows(undefined, "", 60)), []);
});

test("clipboard search uses complete text while display remains bounded and inputs stay unchanged", () => {
    const original = entry("long", "x".repeat(9000) + " synthetic-tail-needle");
    const before = JSON.stringify(original);
    const rows = model.displayRows([original, entry("other")], "synthetic-tail-needle", 60);
    assert.equal(rows.length, 1);
    assert.equal(rows[0].itemId, "long");
    assert.ok(rows[0].fullText.length <= 8192);
    assert.equal(JSON.stringify(original), before);
    assert.equal(model.displayRows([original], "", 0).length, 0);
});

test("clipboard stable-ID assertion rejects an index-only behavior mutation", () => {
    const guard = "const found = indexOfId(rows, previousId);";
    assert.equal(source.split(guard).length - 1, 1, "mutation anchor must be unique");
    const mutant = load(source.replace(guard, "const found = -1;"));
    const rows = mutant.displayRows([entry("new"), entry("a"), entry("selected")], "", 60);
    assert.throws(() => {
        assert.equal(rows[mutant.selectionIndex("selected", 1, rows)].itemId, "selected");
    }, assert.AssertionError, "an index-only implementation must fail the user-visible identity assertion");
});
