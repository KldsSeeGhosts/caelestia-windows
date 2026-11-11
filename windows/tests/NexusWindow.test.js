const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { test } = require("node:test");
const root = path.resolve(__dirname, "../..");
const read = file => fs.readFileSync(path.join(root, file), "utf8");
const factory = read("windows/shell/adapters/modules/nexus/WindowFactory.qml");

function extract(source, name) {
    const match = source.match(new RegExp(`^( +)function ${name}\\(([^)]*)\\): \\w+ \\{([\\s\\S]*?)\\n\\1\\}`, "m"));
    assert.ok(match);
    return `function ${name}(${match[2].replace(/: \w+/g, "")}) {${match[3]}\n}`;
}

test("factory activates both first opens and reused/restored windows in the caller's dispatch", () => {
    const events = [];
    const win = {
        visible: true, minimized: true,
        requestActivate() { events.push("activate"); },
        openPage(idx) { events.push(`page-${idx}`); this.requestActivate(); }
    };
    const context = {
        root: { windows: [], activeWindow() { return this.windows.at(-1); } },
        dummy: {}, nexusComp: { createObject() { events.push("create"); return win; } }
    };
    vm.createContext(context);
    vm.runInContext(extract(factory, "create"), context);
    assert.equal(context.create(null, {}), win);
    assert.deepEqual(events, ["create", "activate"]);
    events.length = 0;
    assert.equal(context.create(null, {}), win);
    assert.equal(win.minimized, false);
    assert.deepEqual(events, ["activate"]);
    events.length = 0;
    context.create(null, {pageIdx: 3});
    assert.deepEqual(events, ["page-3", "activate"]);
    assert.equal(context.root.windows.length, 1);
});

test("all panel entry points open Nexus before releasing their source panel", () => {
    const utilities = read("windows/shell/adapters/modules/utilities/cards/Toggles.qml");
    const toggle = utilities.slice(utilities.indexOf('roleValue: "settings"'), utilities.indexOf('roleValue: "dnd"'));
    assert.ok(toggle.indexOf("WindowFactory.create()") < toggle.indexOf("root.screenState.utilities = false"));
    const popout = read("windows/shell/adapters/modules/bar/popouts/Wrapper.qml");
    const detach = extract(popout, "detach");
    assert.ok(detach.indexOf("WindowFactory.openPage(") < detach.indexOf("root.hasCurrent = false"));
    const launcher = read("windows/shell/adapters/modules/launcher/services/Actions.qml");
    const settings = launcher.slice(launcher.indexOf('command[0] === "settings"'), launcher.indexOf('command[0] === "chooseWallpaper"'));
    assert.ok(settings.indexOf("WindowFactory.create()") < settings.indexOf("list.screenState.launcher = false"));
});

test("Windows binaries and installer shortcuts share the Caelestia multi-size icon", () => {
    const ico = fs.readFileSync(path.join(root, "assets/caelestia.ico"));
    assert.equal(ico.readUInt16LE(0), 0);
    assert.equal(ico.readUInt16LE(2), 1);
    const sizes = Array.from({length: ico.readUInt16LE(4)}, (_, i) => ico[6 + i * 16] || 256);
    assert.deepEqual(sizes, [16, 20, 24, 32, 40, 48, 64, 128, 256]);
    for (let i = 0; i < sizes.length; i++) {
        const offset = ico.readUInt32LE(6 + i * 16 + 12);
        const length = ico.readUInt32LE(6 + i * 16 + 8);
        assert.ok(length > 0 && offset + length <= ico.length);
    }
    assert.match(read("windows/scripts/Build-Prototype.ps1"), /-DQS_ICON_FILE:FILEPATH=\$repoRoot\/assets\/caelestia.ico/);
    assert.match(read("windows/scripts/Caelestia-InstallCommon.ps1"), /\\qs\.exe,0/);
});
