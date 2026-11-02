// Headless checks of the production QML's JavaScript, not a QML/live UI test.
// Run: node --test windows/tests/RegexConfigGuard.test.js
//
// User configuration can carry a regular expression that does not compile
// (favourite and hidden apps, icon rules). The engine's SyntaxError text
// contains the pattern, so the helpers must skip such a rule without throwing,
// and must not log it.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { test } = require("node:test");

const repo = path.resolve(__dirname, "../..");
const read = file => fs.readFileSync(path.join(repo, file), "utf8");

// Extracts one QML function and strips its type annotations only.
function qmlFunction(text, name) {
    const match = text.match(new RegExp(`^( +)function ${name}\\(([^)]*)\\)(?:: [\\w<>.]+)? \\{([\\s\\S]*?)\\n\\1\\}`, "m"));
    assert.ok(match, `QML function ${name} exists`);
    const params = match[2].replace(/: [\w<>.]+/g, "");
    return `function ${name}(${params}) {${match[3]}\n}`;
}

function load(file, names, extra = "") {
    const text = read(file);
    const logs = [];
    const context = {
        _regexCache: {},
        console: { log: m => logs.push(String(m)), warn: m => logs.push(String(m)), error: m => logs.push(String(m)) },
    };
    vm.runInNewContext(extra + names.map(n => qmlFunction(text, n)).join("\n")
        + `\n;globalThis.api = { ${names.join(", ")} };`, context);
    return { api: context.api, logs };
}

const BAD = "^[unterminated$";

test("Strings.testRegexList skips a pattern that does not compile", () => {
    const { api, logs } = load("utils/Strings.qml", ["testRegexList"]);
    assert.equal(api.testRegexList([BAD], "anything"), false);
    // Later valid entries still apply, and the bad one is remembered, not retried.
    assert.equal(api.testRegexList([BAD, "^org\\.example\\..*$"], "org.example.app"), true);
    assert.equal(api.testRegexList([BAD, "plain.id"], "plain.id"), true);
    assert.equal(api.testRegexList([BAD], "^[unterminated$"), false);
    assert.deepEqual(logs, []);
});

test("Icons.matchIconRule treats an invalid regex as no match", () => {
    const { api, logs } = load("utils/Icons.qml", ["matchIconRule"]);
    assert.equal(api.matchIconRule("firefox", { icon: "web", regex: BAD }), false);
    assert.equal(api.matchIconRule("firefox", { icon: "web", regex: "^fire.*$" }), true);
    assert.equal(api.matchIconRule("firefox", { icon: "web", name: "firefox" }), true);
    assert.deepEqual(logs, []);
});

test("AppInfo.matchedByRegex treats an invalid regex as no match", () => {
    const { api, logs } = load(
        "modules/nexus/pages/apps/AppInfo.qml",
        ["isRegexEntry", "matchedByRegex"]
    );
    assert.equal(api.matchedByRegex([BAD], "anything"), false);
    assert.equal(api.matchedByRegex([BAD, "^app$"], "app"), true);
    assert.deepEqual(logs, []);
});

test("shipping sources log no regex pattern text", () => {
    // The C++ side is covered by its own tests; here the QML helpers must not
    // build a message from a pattern.
    for (const file of ["utils/Strings.qml", "utils/Icons.qml", "modules/nexus/pages/apps/AppInfo.qml"]) {
        assert.doesNotMatch(read(file), /console\.(log|warn|error)\([^)]*(filter|iconRule\.regex)/, file);
    }
});
