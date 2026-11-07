// Actual adapter JS only. No host, clipboard, capture, input or desktop.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const root = path.join(__dirname, "../..");
const glazier = fs.readFileSync(path.join(root, "windows/shell/adapters/services/Glazier.qml"), "utf8");
const recorder = fs.readFileSync(path.join(root, "windows/shell/adapters/services/Recorder.qml"), "utf8");
let count = 0;
function check(value, message) { assert.ok(value, message); count++; }
function functions(source) {
    return [...source.matchAll(/^    (function \w+\([^\n]*\n[\s\S]*?^    })/gm)]
        .map(m => m[1].replace(/\): (?:void|bool|string|var)\s*\{/, ") {")).join("\n");
}
const context = {
    executable: "", configuredPath: "", configReady: false, lifecyclePath: "",
    bundledPath: "C:/synthetic/caelestia-capture.exe", themeFile: "C:/synthetic/theme.json",
    WindowsFiles: { isFile: p => p === context.bundledPath },
    hostLifecycle: {
        acquire(...args) { context.acquired = args; },
        command(args) { context.command = args; return true; },
    },
};
vm.createContext(context);
vm.runInContext(functions(glazier), context);
check(context.hostClass(context.bundledPath) === "CaelestiaCaptureHost", "first-party window identity");
check(context.hostClass("C:\\synthetic\\CAELESTIA-CAPTURE.EXE") === "CaelestiaCaptureHost", "case and separators");
check(context.hostClass("C:/legacy/glazier.exe") === "GlazierHost", "legacy override retains safe class");
check(context.ensureLifecycle(context.bundledPath), "first-party acquire accepted");
check(context.acquired[1] === "CaelestiaCaptureHost", "native registry receives first-party class");
check(context.acquired[2].join("|") === "--no-hotkeys|--theme-file|C:/synthetic/theme.json", "launch stays compatible");
check(context.sendHostCommand(["--record"], "C:/legacy/glazier.exe"), "legacy command accepted");
check(context.acquired[0] === "C:/legacy/glazier.exe" && context.acquired[1] === "GlazierHost",
    "recorder override uses that executable's class, not stale bundled identity");
check(context.resolvePath(context.bundledPath, "C:/legacy/glazier.exe", () => true) === context.bundledPath,
    "existing bundled-first precedence");
check(context.resolvePath(context.bundledPath, "C:/legacy/glazier.exe", p => p.includes("legacy")) === "C:/legacy/glazier.exe",
    "legacy executable config fallback retained");
context.configure('{"executable":"C:\\\\legacy\\\\glazier.exe"}');
check(context.configuredPath === "C:/legacy/glazier.exe" && context.configReady, "legacy JSON configuration preserved");
check(/\/glazier\.json"/.test(glazier), "legacy profile configuration path preserved");
for (const target of ["screenshot", "picker"]) check(glazier.includes(`target: "${target}"`), `${target} IPC alias preserved`);
check(recorder.includes('command: [root.executable, "--status"]'), "status uses binary default without launch-only flags");
check(recorder.includes('CAELESTIA_GLAZIER_EXE') && recorder.includes('CAELESTIA_CAPTURE_EXE'),
    "legacy and first-party environment aliases retained");
check(recorder.includes('["[!.]*.mp4"]') && recorder.includes('"/caelestia/recordings.json"'),
    "recording exclusions and finished-file journal path retained");
check(!glazier.includes('"--managed"') && !recorder.includes('"--managed"'), "no host/client managed identity mismatch");
console.log(`Capture integration adapter logic: ${count} assertions passed.`);
