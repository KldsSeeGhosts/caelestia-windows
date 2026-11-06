// Headless protocol/ownership regression checks against the adapter's actual JS.
// No Qt, processes, desktop, filesystem store or real recordings are exercised.
// The Windows QML fixture covers real FileView persistence and Delete bindings.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const revision = process.argv[2];
if (revision && !/^[a-f0-9]{40}$/.test(revision))
    throw new Error("Expected a full source revision");
const source = revision
    ? require("node:child_process").execFileSync("git",
        ["show", `${revision}:windows/shell/adapters/services/Recorder.qml`],
        { cwd: path.join(__dirname, "../.."), encoding: "utf8" })
    : fs.readFileSync(path.join(__dirname, "../shell/adapters/services/Recorder.qml"), "utf8");
function capture(pattern) {
    const match = source.match(pattern);
    assert.ok(match, "adapter source block found");
    return match[1];
}
const functions = [...source.matchAll(/^    (function \w+\([^\n]*\n[\s\S]*?^    })/gm)]
    .map(match => match[1].replace(/\): (?:void|bool|string)\s*\{/, ") {")).join("\n");
const status = capture(/readonly property string status: \{([\s\S]*?)^    }/m);
const canStart = capture(/readonly property bool canStart: ([^\n]+)/);
const running = capture(/readonly property bool running: ([^\n]+)/);
const timeout = capture(/id: startTimeout[\s\S]*?onTriggered: \{([\s\S]*?)^        }/m);
const loaded = capture(/onLoaded: \{([\s\S]*?)^        }/m);
const finish = capture(/^        function finish\(\): void \{([\s\S]*?)^        }/m);
let assertions = 0;
function check(condition, message) {
    // Never print response bodies, file paths or event messages on failure.
    assert.ok(condition, message);
    assertions++;
}
function recorder() {
    const context = {
        permitted: true, probed: true, available: true, executable: "C:/synthetic/glazier.exe",
        state: "idle", elapsed: 0, outputDir: "", lastFile: "", finishedFiles: [],
        lastError: "", connectionError: "", pendingStart: false, baselinePending: true,
        hostId: "", eventSequence: 0, connectionFailed: false, incompatible: false,
        startTimeout: { stop() {}, restart() {} },
        Quickshell: { env() { return ""; }, execDetached(spec) { context.launched = spec; } },
        Glazier: { ownedHost: false, launchedHost: false,
            sendHostCommand(args) { context.launched = { command: [context.executable].concat(args) }; return true; },
            hostOptions() { return ["--no-hotkeys", "--theme-file", "C:/synthetic/theme-tokens.json"]; } },
        store: { restored: false, saved: "", input: "", text() { return this.input; },
            setText(text) { this.saved = text; } },
    };
    context.root = context;
    vm.createContext(context);
    vm.runInContext(functions + "\nfunction statusValue() {" + status + "}\n"
        + "function canStartValue() { return " + canStart + "; }\n"
        + "function runningValue() { return " + running + "; }\n"
        + "function expireStart() {" + timeout + "}\n"
        + "function restoreStore() { with (store) {" + loaded + "}}\n"
        + "store.finish = function() { with (store) {" + finish + "}};", context);
    Object.defineProperties(context, {
        running: { get() { return this.runningValue(); } },
        canStart: { get() { return this.canStartValue(); } },
    });
    return context;
}
const error = (sequence = 1) => ({ sequence, type: "error", message: "Synthetic capture failure" });
const finished = (sequence, index) => ({ sequence, type: "finished",
    output_path: `C:/synthetic/fixture-${index}.mp4` });
const reply = (host, events = [], state = "idle") => JSON.stringify({
    version: 1, ok: true, host_id: host, state, elapsed_ms: 0,
    output_directory: "C:/synthetic", events,
});
const offline = JSON.stringify({ version: 1, ok: false });

// Reproduce both #109 error-loss paths without replaying pre-shell failures.
let r = recorder();
check(!r.start(), "Start waits for initial observation, avoiding ambiguous stale journal replay");
check(r.applyResponse(reply("old-host", [error(), finished(2, 0)])), "startup baseline accepted");
check(r.lastError === "" && r.lastFile === "", "shell startup does not replay old failure or lastFile");
check(r.owns("c:\\synthetic\\fixture-0.mp4"), "baseline still remembers finished ownership");
check(r.applyResponse(reply("old-host", [error(3)])) && r.lastError !== "", "post-baseline error visible");
check(r.applyResponse(reply("old-host", [error(3)])) && r.lastError !== "", "idle journal replay retains failure");
r.disconnected("Synthetic transport failure");
check(r.applyResponse(reply("old-host")) && r.lastError !== "" && r.connectionError === "",
    "transport recovery clears only transport error");
check(r.applyResponse(reply("old-host", [{ sequence: 4, type: "started" }], "recording"))
    && r.lastError === "", "successful recording clears failure");
check(r.applyResponse(reply("new-host", [error()])) && r.lastError !== "",
    "replacement host first-response error not discarded");
check(!r.pendingStart, "replacement failure needs no pending Start");

r = recorder();
check(!r.applyResponse(offline) && r.statusValue() === "Glazier stopped", "short stopped-host copy");
check(r.applyResponse(reply("new-host", [error()])) && r.lastError !== "",
    "first host after offline observation has fresh errors even without Start");
for (const observeOffline of [false, true]) {
    r = recorder();
    if (observeOffline) r.applyResponse(offline);
    else r.applyResponse(reply("existing-host", [error()]));
    check(r.start(), "cold Start accepted");
    // A Start can cold-start the host, so it must carry the shell-owned host options.
    check(r.launched.command.slice(1, 4).join(" ") === "--no-hotkeys --theme-file C:/synthetic/theme-tokens.json"
        && r.launched.command.includes("--record"), "cold Start uses shell-owned host options");
    check(!r.Glazier.ownedHost && !r.Glazier.launchedHost,
        "forwarded Start never assigns native ownership or launched-host journal freshness");
    check(r.applyResponse(reply("cold-host", [error()])) && r.lastError !== "",
        "cold Start first-response error visible");
    check(!r.pendingStart, "cold Start error completes pending attempt");
    check(r.applyResponse(reply("cold-host")) && r.lastError !== "", "idle response retains cold failure");
    check(r.start() && r.lastError === "", "explicit retry clears failure");
}
r = recorder();
r.applyResponse(reply("idle-host"));
check(r.start(), "timeout attempt accepted");
r.expireStart();
check(!r.pendingStart && r.lastError.startsWith("Glazier did not start recording."), "Start timeout visible");
check(r.applyResponse(reply("idle-host")) && r.lastError !== "", "valid idle response retains timeout");
r.disconnected("Synthetic transport failure");
check(r.applyResponse(reply("idle-host")) && r.lastError !== "", "reconnection retains timeout");
check(r.applyResponse(reply("idle-host", [error()])) && r.lastError === "Synthetic capture failure",
    "specific capture failure replaces generic timeout");
check(r.applyResponse(reply("idle-host", [{ sequence: 2, type: "started" }], "recording"))
    && r.lastError === "", "late successful recording clears timeout/failure");
check(!r.applyResponse('{"version":2,"ok":true}') && r.incompatible, "explicit mismatch disables recorder");
check(!r.applyResponse(offline) && !r.incompatible && r.canStart, "offline v1 recovers compatibility");
check(!r.applyResponse("{") && !r.incompatible, "malformed response stays transient");
check(r.applyResponse(reply("idle-host")) && r.connectionError === "", "valid reply clears transient failure");
r = recorder();
r.applyResponse(reply("idle-host"));
r.start();
r.expireStart();
check(r.applyResponse(reply("idle-host", [], "recording")) && r.lastError === "",
    "confirmed recording clears timeout even if started event rolled out of journal");

// Exercise the actual store handlers, including an event racing the initial read.
for (const input of ["", "{synthetic corruption", "null", "{}"]) {
    r = recorder();
    r.store.input = input;
    r.restoreStore();
    check(r.finishedFiles.length === 0 && r.store.restored, "missing/corrupt store grants no ownership");
    r.remember("C:/synthetic/fixture-0.mp4");
    check(JSON.parse(r.store.saved).length === 1, "store recovers on new finished file");
}
r = recorder();
r.remember("C:/synthetic/fixture-1.mp4");
r.store.input = '["c:/synthetic/fixture-0.mp4",null,42]';
r.restoreStore();
check(r.finishedFiles.length === 2 && r.owns("C:/synthetic/fixture-0.mp4")
    && r.owns("C:/synthetic/fixture-1.mp4"), "restore merges valid saved entries and in-flight finished event");
for (let i = 2; i <= 500; i++) r.remember(`C:/synthetic/fixture-${i}.mp4`);
check(r.finishedFiles.length === 500 && !r.owns("C:/synthetic/fixture-0.mp4")
    && r.owns("C:/synthetic/fixture-500.mp4"), "cap retains newest 500");
r.remember("c:\\SYNTHETIC\\fixture-500.mp4");
check(r.finishedFiles.length === 500 && r.owns("C:/synthetic/fixture-1.mp4"), "normalized duplicate does not evict");
const saved = r.store.saved;
r = recorder();
r.store.input = saved;
r.restoreStore();
check(r.finishedFiles.length === 500 && r.owns("C:/synthetic/fixture-500.mp4")
    && !r.owns("C:/synthetic/fixture-0.mp4"), "store handler restores capped ownership in fresh context");
check(!r.owns("C:/synthetic/unreported.mp4") && !r.owns(null), "unreported/null entries not owned");
r = recorder();
r.store.input = JSON.stringify(Array.from({ length: 501 }, (_, i) => `c:/synthetic/fixture-${i}.mp4`));
r.restoreStore();
check(r.finishedFiles.length === 500 && !r.owns("C:/synthetic/fixture-0.mp4")
    && r.owns("C:/synthetic/fixture-500.mp4"), "oversized saved ownership bounded on load");

console.log(`Glazier recorder headless logic: ${assertions} assertions passed.`);
