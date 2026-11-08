// Headless check of the production shell's shell-surface selector list, not a
// QML/live UI test. Run: node --test windows/tests/ShellSurfaceSelectors.test.js
//
// The bundled capture tool draws topmost windows over the shell. Its picker and
// editor overlay must be classified as a shell surface or the top-layer panels
// are restored above it, and the bar and border swallow the press that starts a
// selection. The user's own windows.shellSurfaces.extra entries must keep
// working unchanged, so the binding has to merge them with the built-ins.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { test } = require("node:test");

const repo = path.resolve(__dirname, "../..");
const read = file => fs.readFileSync(path.join(repo, file), "utf8");
const shell = read("windows/shell/shell.qml");

const builtins = [
    "class:GlazierOverlay",
    "class:GlazierThumbnail",
    "class:GlazierRecording",
    "class:GlazierRecordingBorder",
];

// Extracts one QML function and strips its type annotations only.
function qmlFunction(text, name) {
    const match = text.match(new RegExp(`^( +)function ${name}\\(([^)]*)\\)(?:: [\\w<>.]+)? \\{([\\s\\S]*?)\\n\\1\\}`, "m"));
    assert.ok(match, `QML function ${name} exists`);
    const params = match[2].replace(/: [\w<>.]+/g, "");
    return `function ${name}(${params}) {${match[3]}\n}`;
}

// The expression the Native.ShellSurfaces binding actually assigns.
function bindingValue(text) {
    const start = text.indexOf("target: Native.ShellSurfaces");
    assert.ok(start >= 0, "the Native.ShellSurfaces binding exists");
    const value = text.slice(start).match(/^\s*value:\s*(.+)$/m);
    assert.ok(value, "the Native.ShellSurfaces binding has a value");
    return value[1].trim();
}

// Evaluates the real binding expression against a config fixture. The result
// crosses the vm realm, so compare a plain copy.
function boundSelectors(extra) {
    const context = { GlobalConfig: { windows: { shellSurfaces: { extra } } } };
    vm.runInNewContext(qmlFunction(shell, "shellSurfaceSelectors") + "\n;globalThis.merge = shellSurfaceSelectors;", context);
    context.root = { shellSurfaceSelectors: context.merge };
    return JSON.parse(JSON.stringify(vm.runInNewContext(`(${bindingValue(shell)})`, context)));
}

test("the binding adds the bundled capture classes ahead of the user entries", () => {
    const user = ["exe:some-shell.exe", "title:Task Switcher"];
    assert.deepEqual(boundSelectors(user), [...builtins, ...user]);
});

test("the binding keeps the built-ins when the user list is missing or empty", () => {
    assert.deepEqual(boundSelectors(undefined), builtins);
    assert.deepEqual(boundSelectors([]), builtins);
    assert.deepEqual(boundSelectors(null), builtins);
});

test("a semicolon-separated user string stays one entry for the backend", () => {
    // The backend splits a string value itself; merging must not do it early.
    assert.deepEqual(boundSelectors("exe:a.exe;class:Foo"), [...builtins, "exe:a.exe;class:Foo"]);
});

test("non-string user entries are passed through, never coerced to selectors", () => {
    const user = [42, { exe: "not-a-selector" }, ""];
    assert.deepEqual(boundSelectors(user), [...builtins, ...user]);
});

test("every built-in selector is an exact class the capture tool registers", () => {
    assert.deepEqual(builtins.filter(entry => !entry.startsWith("class:")), []);
    const capture = ["windows/capture/src/overlay.rs", "windows/capture/src/thumbnail.rs",
        "windows/capture/src/recording.rs"].map(read).join("\n");
    for (const entry of builtins) {
        assert.ok(capture.includes(`w!("${entry.slice("class:".length)}")`), `${entry} is registered in windows/capture`);
    }
});
