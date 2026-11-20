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

// Wrap FileUrls.parseFileUrl in a counting spy so a test can assert each row's
// lines are decoded once per pass, not once per derived field.
function loadWithParseCounter() {
    const urls = vm.createContext({});
    const urlSource = fs.readFileSync(path.join(__dirname, "../shell/adapters/utils/FileUrls.js"), "utf8");
    vm.runInContext(urlSource.replace(/^\s*\.pragma library\s*$/gm, ""), urls,
        { filename: "production/FileUrls.js" });
    const realParse = urls.parseFileUrl;
    const counter = { calls: 0 };
    const instrumented = vm.createContext({ FileUrls: Object.assign({}, urls, {
        parseFileUrl: value => { counter.calls++; return realParse(value); }
    }) });
    vm.runInContext(source.replace(/^\s*\.import[^\r\n]*$/gm, ""), instrumented,
        { filename: "production/ClipboardHistory.js" });
    return { context: instrumented, counter };
}

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

test("clipboard file rows split and decode each visible line once per pass", () => {
    const { context, counter } = loadWithParseCounter();
    const fileText = [
        "file:///C:/docs/report.pdf",
        "file:///D:/photos/cat.png",
        "plain tail line"
    ].join("\n");
    const rows = context.displayRows([entry("files", fileText), entry("note", "no urls here")], "", 60);
    assert.equal(rows.length, 2);
    assert.equal(rows[0].entryType, "file");
    assert.equal(rows[0].subtitle, "report.pdf, cat.png");
    assert.equal(rows[0].fullText, "C:/docs/report.pdf\nD:/photos/cat.png");
    // Only the file row's three lines reach the parser; the plain-text row is
    // skipped by the file: precheck, and no derived field re-parses a line.
    assert.equal(counter.calls, 3);

    counter.calls = 0;
    context.displayRows([entry("files", fileText)], "report", 60);
    assert.equal(counter.calls, 3, "search reuse must not decode the row a second time");
});

test("clipboard file search matches labels and file lines past the display cap", () => {
    const padding = "filler text\n".repeat(700); // pushes text past displayTextLimit
    const fileText = [
        "plain intro line",
        padding,
        "file:///C:/docs/deep-secret.pdf",
        "file://remote-host/share/skip.txt",
        "file:///E:/encoded%20name.txt"
    ].join("\n");
    const rows = model.displayRows([entry("deep", fileText)], "deep-secret", 60);
    assert.equal(rows.length, 1, "a file label past the cap must still match search");
    assert.equal(rows[0].itemId, "deep");

    const mixed = model.displayRows([
        entry("mixed", "regular line\nfile:///C:/ok/visible.txt\nfile:///\\\\unc\\evil\nfile://otherhost/x/y"),
        entry("plain", "ordinary text")
    ], "", 60);
    assert.equal(mixed.length, 2);
    assert.equal(mixed[0].entryType, "file");
    // Remote-authority and decoded-UNC spellings are refused, leaving one path.
    assert.equal(mixed[0].fullText, "C:/ok/visible.txt");
    assert.equal(mixed[0].path, "C:/ok/visible.txt");
    assert.equal(mixed[1].entryType, "text");
});

test("clipboard rows retain no parsed-path state between calls", () => {
    const first = model.displayRows([entry("f", "file:///C:/one.txt")], "", 60);
    assert.equal(first[0].path, "C:/one.txt");
    const second = model.displayRows([entry("g", "totally plain")], "", 60);
    assert.equal(second[0].entryType, "text");
    assert.equal(second[0].path, "");
});
