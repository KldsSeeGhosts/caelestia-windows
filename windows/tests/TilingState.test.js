// Headless production-function regression, not native forwarding or toast acceptance.
// Run: node --test windows/tests/TilingState.test.js
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { test } = require("node:test");

const source = fs.readFileSync(path.resolve(__dirname, "../shell/shell.qml"), "utf8");

test("shell tilingState returns only fixed stage scalars without actions or writes", () => {
    const handler = source.slice(source.indexOf('target: "shell"'), source.indexOf('target: "displays"'));
    const match = handler.match(/^        function tilingState\(\): string \{([\s\S]*?)\n        \}/m);
    assert.ok(match, "diagnostic is on the existing shell IPC handler");
    assert.equal((source.match(/\btilingState\b/g) ?? []).length, 1,
        "no readiness binding or other caller is added");

    // Only declared reads are permitted. Private fields, methods, serialization
    // hooks and all mutation paths fail, including native-loader/action access.
    const readOnly = fields => new Proxy(Object.freeze(fields), {
        get(target, key) {
            assert.ok(Object.hasOwn(target, key), `unexpected read: ${String(key)}`);
            return target[key];
        },
        set() { assert.fail("diagnostic must not write"); },
        defineProperty() { assert.fail("diagnostic must not define properties"); },
        deleteProperty() { assert.fail("diagnostic must not delete properties"); }
    });
    const defaults = {
        backendLoaded: false, supportsTelemetry: false,
        failedCount: 0, recentFailureCount: 0, toastCount: 0, openToastCount: 0,
        hasFullscreen: false, fullscreenPolicy: "off", status: "disabled"
    };
    const cases = [
        { expected: defaults, backend: null, closed: [] },
        { expected: { ...defaults, backendLoaded: true, status: "observing" },
            backend: readOnly({ supportsTelemetry: undefined }), closed: [] },
        ...["observing", "refused", "tiling"].flatMap(status =>
            ["off", "important", "all"].map(fullscreenPolicy => ({
                expected: {
                    ...defaults, backendLoaded: true, supportsTelemetry: true,
                    failedCount: 7, recentFailureCount: 3, toastCount: 2, openToastCount: 2,
                    hasFullscreen: true, fullscreenPolicy, status
                },
                backend: readOnly({ supportsTelemetry: true }),
                closed: [false, true, false]
            }))),
        {
            expected: { ...defaults, fullscreenPolicy: "unknown", status: "unknown" },
            backend: null, closed: [], status: "private-status", fullscreenPolicy: "private-policy"
        }
    ];

    for (const entry of cases) {
        const expected = entry.expected;
        let fullscreenReads = 0;
        const context = vm.createContext({
            Tiling: readOnly({
                backendLoaded: expected.backendLoaded, backend: entry.backend,
                failedCount: expected.failedCount, recentFailureCount: expected.recentFailureCount,
                toastCount: expected.toastCount, status: entry.status ?? expected.status
            }),
            Toaster: readOnly({
                toasts: Object.freeze(entry.closed.map(closed => readOnly({ closed })))
            }),
            Notifs: readOnly({
                hasFullscreen() { fullscreenReads++; return expected.hasFullscreen; }
            }),
            GlobalConfig: readOnly({
                utilities: readOnly({
                    toasts: readOnly({ fullscreen: entry.fullscreenPolicy ?? expected.fullscreenPolicy })
                })
            }),
            console: readOnly({})
        });
        const json = vm.runInContext(`(function () {${match[1]}\n})()`, context);
        assert.equal(typeof json, "string");
        assert.deepEqual(JSON.parse(json), expected, "exact bounded schema and values");
        assert.ok(json.length < 256, "payload stays bounded, even with private enum input");
        assert.doesNotMatch(json, /private|address|title|appClass|reason|message|monitor|device|recentFailures/);
        assert.equal(fullscreenReads, 1, "only the read-only fullscreen query is called");
    }
});

test("Super-drag follows accepted native tiling state, including stale lease teardown", () => {
    const backend = fs.readFileSync(path.resolve(__dirname,
        "../services/tiling/NativeTilingBackend.qml"), "utf8");
    // Portable production-function test with a fake native lease, plus static
    // QML wiring assertions. This does not execute QML signals or native hooks.
    assert.match(backend, /readonly property bool enabled: Tiling\.enabled/);
    assert.match(backend, /onEnabledChanged: root\.syncSuperDrag\(\)/);
    assert.match(backend, /Component\.onCompleted:\s*\{\s*root\.syncSuperDrag\(\);/);
    assert.match(backend, /Component\.onDestruction: root\.requestDisable\(\)/);
    assert.equal((backend.match(/SuperDrag\.enabled\s*=/g) ?? []).length, 1,
        "one direct sync writer, no teardown reset or restoring Binding");
    assert.doesNotMatch(backend, /target:\s*SuperDrag/);

    let nativeEnabled = false;
    let acceptsWrite = true;
    const requests = [];
    const controllerWrites = [];
    const root = {};
    const context = vm.createContext({
        root,
        Tiling: {
            get enabled() { return nativeEnabled; },
            set enabled(value) {
                requests.push(value);
                if (acceptsWrite)
                    nativeEnabled = value;
            }
        },
        SuperDrag: {
            set enabled(value) { controllerWrites.push(value); }
        }
    });
    for (const name of ["syncSuperDrag", "requestEnable", "requestDisable"]) {
        const match = backend.match(new RegExp(
            `    function ${name}\\(\\): void \\{([\\s\\S]*?)\\n    \\}`));
        assert.ok(match, `${name} production function exists`);
        root[name] = vm.runInContext(`(function () {${match[1]}\n})`, context);
    }
    const expectController = (action, expected, message) => {
        const before = controllerWrites.length;
        action();
        assert.deepEqual(controllerWrites.slice(before), [expected], message);
    };
    expectController(root.syncSuperDrag, false, "initial inactive state stays disabled");
    acceptsWrite = false;
    expectController(root.requestEnable, false, "refused enable cannot start hooks");
    acceptsWrite = true;
    expectController(root.requestEnable, true, "accepted interactive enable starts controller");
    nativeEnabled = false;
    expectController(root.syncSuperDrag, false, "native disable projection stops controller");
    nativeEnabled = true;
    expectController(root.syncSuperDrag, true, "native enable projection starts controller");
    expectController(root.requestDisable, false, "own disable stops controller");
    nativeEnabled = true;
    acceptsWrite = false;
    expectController(root.requestDisable, true, "stale disable preserves current owner's controller");
    assert.deepEqual(requests, [true, true, false, false]);
    assert.equal(nativeEnabled, true);
});
