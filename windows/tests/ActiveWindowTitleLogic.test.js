const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

const source = fs.readFileSync(path.resolve(__dirname, "../../modules/bar/components/ActiveWindow.qml"), "utf8");
const functions = ["levenshteinGreaterThan", "shouldAnimateTitleChange"].map(name => {
    const match = source.match(new RegExp(`^    function ${name}\\(([^)]*)\\): bool (\\{[\\s\\S]*?\\n    \\})`, "m"));
    assert.ok(match, `QML function ${name} exists`);
    return `function ${name}(${match[1].replace(/: \w+/g, "")}) ${match[2]}`;
});
const context = vm.createContext({});
vm.runInContext(functions.join("\n"), context);
const {levenshteinGreaterThan, shouldAnimateTitleChange} = context;

test("Windows stages the icon strip, not the unused rotated title component", () => {
    const manifest = JSON.parse(fs.readFileSync(path.resolve(__dirname, "../shell/sources.json"), "utf8"));
    assert.equal(manifest["modules/bar/components/ActiveWindow.qml"], undefined);
    assert.equal(manifest["windows/shell/adapters/modules/bar/components/ActiveWindow.qml"],
        "modules/bar/components/ActiveWindow.qml");
    assert.equal(manifest["modules/bar/popouts/ActiveWindow.qml"], "modules/bar/popouts/ActiveWindowContent.qml");
});

test("small title edits stay within the animation suppression threshold", () => {
    assert.equal(levenshteinGreaterThan("Document (1)", "Document (2)", 2), false);
    assert.equal(levenshteinGreaterThan("shell 10%", "shell 11%", 2), false);
    assert.equal(levenshteinGreaterThan("same", "same", 2), false);
    assert.equal(levenshteinGreaterThan("abcdef", "abqef", 2), false);
});

test("window switches and large title edits still animate", () => {
    assert.equal(shouldAnimateTitleChange("a", "b", "Document (1)", "Document (2)"), true);
    assert.equal(shouldAnimateTitleChange("a", "a", "Document (1)", "Document (2)"), false);
    assert.equal(shouldAnimateTitleChange("a", "a", "Firefox", "Terminal"), true);
    assert.equal(levenshteinGreaterThan("a", "abcdef", 2), true);
});
