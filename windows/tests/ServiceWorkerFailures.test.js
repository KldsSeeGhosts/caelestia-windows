// Execute shipped QML functions and handlers with recording processes/timers.
// No native worker, registry, endpoint, clipboard or desktop input is used.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const test = require("node:test");
const read = file => fs.readFileSync(path.resolve(__dirname, file), "utf8").replace(/\r\n/g, "\n");
const notifs = read("../services/notifications/Notifs.qml");
const quota = read("../quota/services/Quota.qml");

function body(source, name) {
    const match = source.match(new RegExp(`    function ${name}\\([^\\n]*\\)(?:: \\w+)? \\{\\n([\\s\\S]*?)\\n    \\}`));
    assert.ok(match, name);
    return match[1];
}
function block(source, start, end) {
    const from = source.indexOf(start);
    const to = source.indexOf(end, from + start.length);
    assert.ok(from >= 0 && to > from, start);
    return source.slice(from, to);
}
function handler(source, name) {
    const match = source.match(new RegExp(`${name}: (?:[^\\n]*=> )?\\{\\n([\\s\\S]*?)\\n        \\}`));
    assert.ok(match, name);
    return match[1];
}
function run(source, context) {
    return vm.runInNewContext(`(function () { ${source}\n })()`, context);
}
function timer() {
    return { pending: false, starts: 0, start() { this.pending = true; this.starts++; },
        stop() { this.pending = false; } };
}
function install(source, names, context) {
    for (const name of names)
        context.root[name] = () => run(body(source, name), context);
}

const worker = block(notifs, "id: bannerProcess", "// Runs even when mirroring");
const recovery = block(notifs, "id: bannerRecovery", "    Connections {");
const ack = worker.match(/onRead: line => \{\n([\s\S]*?)\n            \}/)[1];

function banners() {
    const root = { bannerFailed: false, bannerRecoveryComplete: true,
        bannerConsecutiveFailures: 0,
        bannerFailureLimit: Number(notifs.match(/bannerFailureLimit: (\d+)/)[1]),
        bannerStarting: false, bannerStopping: false, bannerStarted: false,
        pendingBannerApps: [], recoveries: 0, configureBanners() {},
        recoverBanners() { this.recoveries++; } };
    Object.defineProperty(root, "bannerWanted", { get: () => root.bannerRecoveryComplete && !root.bannerFailed });
    const context = { root, bannerProcess: { write() {} }, console: { warn() {} }, Qt: { callLater() {} } };
    return { root, context };
}

for (const spawnFailure of [false, true]) {
    test(`banner retries stop at the cap after ${spawnFailure ? "spawn" : "worker initialization"} failures`, () => {
        const { root, context } = banners();
        for (let i = 1; i <= root.bannerFailureLimit; i++) {
            assert.equal(root.bannerWanted, true);
            if (spawnFailure)
                run(body(notifs, "bannerStartFailed"), context);
            else
                run(handler(worker, "onExited"), { ...context, code: 1 });
            assert.equal(root.bannerConsecutiveFailures, i);
            assert.equal(root.bannerWanted, false);
            run(handler(recovery, "onExited"), { ...context, code: 0 });
            assert.equal(root.bannerConsecutiveFailures, i, "restoration is not a healthy worker");
        }
        assert.equal(root.bannerWanted, false);
        assert.equal(root.recoveries, root.bannerFailureLimit);
    });
}

test("banner process startup does not reset failures, but a command acknowledgement does", () => {
    const { root, context } = banners();
    root.bannerConsecutiveFailures = 2;
    run(handler(worker, "onStarted"), context);
    assert.equal(root.bannerConsecutiveFailures, 2);
    run(ack, { ...context, line: "noise" });
    assert.equal(root.bannerConsecutiveFailures, 2);
    run(ack, { ...context, line: "ok\r" });
    assert.equal(root.bannerConsecutiveFailures, 0);
});

function quotaRig() {
    const root = { enabled: true, keyRefused: false, hubWanted: true, hubOnly: true,
        hubStarting: false, loading: true, hubState: "", hubRecords: [],
        summaryRecords: [], providers: [], selectedProviderId: "", writes: [],
        cachePath: "/fake/quota-summary.json", cacheRecord: record => record,
        defaultProviderId() { return this.providers[0]?.id || ""; },
        friendlyError: value => value, hubUpdatedAt: 0 };
    const context = { root, hubTimer: timer(), hubStartCheck: timer(), hubProcess: { running: false, signal() {} },
        cacheFile: { setText(text) { root.writes.push(text); } },
        Hub: { order: rows => rows, merge: (a, b) => [...a, ...b] } };
    install(quota, ["stopHub", "rebuild", "writeCache", "startHub", "hubFailed", "applyHubStatus"], context);
    return context;
}

for (const mixed of [false, true]) {
    test(`a refused key retains ${mixed ? "mixed" : "hub-only"} readings and persisted detail`, () => {
        const context = quotaRig();
        const { root } = context;
        root.hubRecords = [{ id: "codex:hub", provider: "codex", history: { days: { today: 10 } } }];
        root.summaryRecords = mixed ? [{ id: "claude:summary", provider: "claude" }] : [];
        root.rebuild();
        const before = JSON.stringify(root.providers);
        root.keyRefused = true;
        root.stopHub();
        root.writeCache();
        assert.equal(root.hubRecords.length, 1);
        assert.equal(JSON.stringify(root.providers), before);
        assert.equal(JSON.stringify(JSON.parse(root.writes.at(-1)).providers), before);
    });
}

for (const method of ["recordRefusal", "adoptRefusal"]) {
    test(`${method} persists the refusal alongside the last-good readings`, () => {
        const context = quotaRig();
        const { root } = context;
        const record = { code: "key_rejected", fingerprint: "fake-fingerprint" };
        Object.assign(context.Hub, { refusal: () => record, refusalMatches: () => true });
        Object.assign(root, { adminKey: "test-only", abortRequests() {}, showRefusal() {} });
        Object.defineProperty(root, "keyRefusal", {
            get: () => root.keyRefused ? record : null,
            set() {
                root.keyRefused = true;
                root.stopHub(); // QML's hubWanted change while adopting the refusal.
            },
        });
        root.hubRecords = [{ id: "hub", history: { days: { today: 10 } } }];
        root.rebuild();
        run(body(quota, method), { ...context, record, code: "key_rejected" });
        const saved = JSON.parse(root.writes.at(-1));
        assert.equal(saved.providers[0].history.days.today, 10);
        assert.deepEqual(saved.refusal, record);
        assert.equal(root.hubRecords.length, 1);
    });
}

test("empty transient sources cannot erase a loaded cache", () => {
    const context = quotaRig();
    const { root } = context;
    Object.assign(root, { lastUpdatedAt: 0, hubSaved: {}, spend: {}, error: "" });
    const providers = [{ id: "codex:cached", provider: "codex" }];
    run(body(quota, "loadCache"), { ...context, raw: JSON.stringify({ providers, lastUpdatedAt: 123 }) });
    root.rebuild();
    assert.deepEqual(JSON.parse(JSON.stringify(root.providers)), providers);
    assert.equal(root.writes.length, 0);
    root.hubRecords = [{ id: "codex:live", provider: "codex" }];
    root.rebuild();
    assert.equal(root.providers[0].id, "codex:live");
    assert.equal(root.writes.length, 1);
});

test("turning off detail still removes hub rows when a summary exists", () => {
    const { root } = quotaRig();
    root.summaryRecords = [{ id: "summary" }];
    root.hubRecords = [{ id: "hub" }];
    root.stopHub();
    assert.deepEqual(JSON.parse(JSON.stringify(root.providers)), [{ id: "summary" }]);
});

const hubProcess = block(quota, "id: hubProcess", "    onHubWantedChanged:");
const startTimer = block(hubProcess, "id: hubStartCheck", "    Timer {\n        id: hubTimer");
const checkStart = startTimer.match(/onTriggered: \{\n([\s\S]*?)\n        \}/)[1];
for (const synchronous of [true, false]) {
    test(`${synchronous ? "a synchronous" : "an asynchronous"} interpreter spawn failure ends hub loading`, () => {
        const context = quotaRig();
        if (synchronous)
            Object.defineProperty(context.hubProcess, "running", { get: () => false, set() {} });
        context.root.startHub();
        if (!synchronous) {
            context.hubProcess.running = false;
            run(handler(hubProcess, "onRunningChanged"), context);
        }
        assert.equal(context.hubStartCheck.pending, true);
        run(checkStart, context);
        assert.equal(context.root.loading, false);
        assert.equal(context.root.status, "error");
        assert.equal(context.root.error, "helper_failed");
    });
}

test("a real exit wins the deferred spawn check; disabling cancels it", () => {
    const context = quotaRig();
    context.root.startHub();
    context.hubProcess.running = false;
    run(handler(hubProcess, "onRunningChanged"), context);
    run(handler(hubProcess, "onExited"), context);
    context.root.hubState = "handled";
    run(checkStart, context);
    assert.equal(context.root.hubState, "handled");
    context.root.stopHub();
    assert.equal(context.hubStartCheck.pending, false);
    assert.equal(context.root.hubStarting, false);
});

const keepalive = block(quota, "id: keepaliveProcess", "    function applyKeepaliveSummary");
const consume = keepalive.match(/onRead: data => \{\n([\s\S]*?)\n            \}/)[1];
test("the keepalive consumer exposes partial inference failure and quota-only reads", () => {
    const root = { keepaliveError: "", keepaliveTotal: 7 };
    const context = { root, qsTr: text => {
        const format = value => ({ arg: argument => format(value.replace(/%\d/, String(argument))), toString: () => value });
        return format(text);
    } };
    root.applyKeepaliveSummary = message => run(body(quota, "applyKeepaliveSummary"), { ...context, message });
    for (const counts of [{ succeeded: 1, fallback: 0, failed: 1 }, { succeeded: 0, fallback: 2, failed: 0 }]) {
        run(consume, { ...context, data: JSON.stringify({ ok: false, ...counts }) });
        assert.equal(String(root.keepaliveError),
            `Keepalive: ${counts.succeeded} inference succeeded, ${counts.fallback} quota reads only, ${counts.failed} failed`);
    }
    root.keepaliveError = "";
    run(consume, { ...context, data: JSON.stringify({ ok: true, succeeded: 2, fallback: 0, failed: 0 }) });
    assert.equal(root.keepaliveError, "");
});
