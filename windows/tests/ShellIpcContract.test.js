const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

const root = path.resolve(__dirname, "../..");
const read = file => fs.readFileSync(path.join(root, file), "utf8").replace(/\r\n/g, "\n");
const shell = read("windows/shell/shell.qml");
const toaster = read("windows/shell/adapters/ipc/ToasterIpc.qml");

function targetBlock(target) {
    const match = shell.match(new RegExp(String.raw`IpcHandler \{\n        target: "${target}"\n([\s\S]*?)\n    \}`));
    assert.ok(match, `missing ${target} IPC target`);
    return match[1];
}

test("upstream IPC mutations keep upstream void return contracts", () => {
    const drawers = targetBlock("drawers");
    assert.match(drawers, /function toggle\(drawer: string\): void/);
    assert.doesNotMatch(drawers, /function toggle\(drawer: string\): bool/);

    const mpris = targetBlock("mpris");
    for (const name of ["play", "pause", "playPause", "next", "previous", "stop"])
        assert.match(mpris, new RegExp(String.raw`function ${name}\(\): void`));

    assert.match(targetBlock("audio"), /function cycleOutput\(\): void/);
    assert.match(targetBlock("nexus"), /function open\(\): void/);
    for (const name of ["info", "success", "warn", "error"])
        assert.match(toaster, new RegExp(String.raw`function ${name}\(title: string, message: string, icon: string\): void`));
});

test("drawer and MPRIS public surface matches the staged Windows backend", () => {
    assert.match(shell, /return \["launcher", "dashboard", "session", "sidebar", "utilities", "osd", "bar", "quota"\]/);
    assert.match(shell, /"playbackState", "isPlaying", "canPlay", "canPause", "canSeek", "canGoNext", "canGoPrevious"/);
});

function body(source, name) {
    const match = source.match(new RegExp(String.raw`^([ ]+)function ${name}\(([^)]*)\): \w+ (\{[\s\S]*?\n\1\})`, "m"));
    assert.ok(match, `missing ${name} function`);
    return `function ${name}(${match[2].replace(/: \w+/g, "")}) ${match[3]}`;
}

test("drawer toggles return nothing and media playback and capabilities are public", () => {
    const state = {quota: false};
    const root = {
        ipcDrawerState: () => state,
        ipcSetDrawer: (name, open) => state[name] = open,
        ipcActivePlayer: () => ({
            canSeek: true, shuffle: false, loopState: 2, shuffleSupported: true, loopSupported: true,
            canControl: true, canTogglePlaying: true, trackArtists: "Fixture artist",
            dbusName: "private", desktopEntry: "private", uniqueId: 4, trackArtUrl: "private", metadata: {}
        })
    };
    const context = vm.createContext({root, Players: {canStop: () => false}});
    vm.runInContext(body(targetBlock("drawers"), "toggle") + "\n" + body(targetBlock("mpris"), "getActive"), context);
    assert.equal(context.toggle("quota"), undefined);
    assert.equal(state.quota, true);
    assert.equal(context.getActive("canSeek"), "true");
    assert.equal(context.getActive("shuffle"), "false");
    assert.equal(context.getActive("loopState"), "2");
    assert.equal(context.getActive("canStop"), "false");
    for (const prop of ["shuffleSupported", "loopSupported", "canControl", "canTogglePlaying"])
        assert.equal(context.getActive(prop), "true");
    assert.equal(context.getActive("trackArtists"), "Fixture artist");
    for (const prop of ["dbusName", "desktopEntry", "uniqueId", "trackArtUrl", "metadata"])
        assert.equal(context.getActive(prop), "Invalid property");
});

test("Nexus toggle reports success when opening and closing, while open stays void", () => {
    const factory = {
        windowCount: 0,
        create() { this.windowCount++; return {}; },
        closeAll() { this.windowCount = 0; }
    };
    const root = {parityEnabled: true};
    const context = vm.createContext({root, Nexus: {WindowFactory: factory}});
    vm.runInContext([body(shell, "openNexus"), body(targetBlock("nexus"), "open"),
        body(targetBlock("nexus"), "toggle")].join("\n"), context);
    root.openNexus = context.openNexus;
    assert.equal(context.toggle(), true);
    assert.equal(factory.windowCount, 1);
    assert.equal(context.toggle(), true);
    assert.equal(factory.windowCount, 0);
    assert.equal(context.open(), undefined);
    assert.equal(factory.windowCount, 1);
    root.parityEnabled = false;
    assert.equal(context.toggle(), false);
    assert.equal(factory.windowCount, 1);
});

test("QML IPC code does not use Object.hasOwn, which QJSEngine lacks", () => {
    for (const file of ["windows/shell/shell.qml", "windows/shell/adapters/ipc/ToasterIpc.qml"])
        assert.doesNotMatch(read(file), /Object\.hasOwn\s*\(/);
    assert.match(toaster, /Object\.prototype\.hasOwnProperty\.call\(types, kind\)/);
});

test("Windows-only IPC extensions are documented separately from upstream parity", () => {
    const docs = read("windows/docs/KEYBINDS.md");
    assert.match(docs, /core upstream targets keep upstream's return contracts/);
    assert.match(docs, /Windows-only extensions are explicit/);
    assert.match(docs, /includes `bar` and `quota`/);
});
