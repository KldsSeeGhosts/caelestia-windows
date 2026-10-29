// Wiring and real snapshot-expression checks, not native delivery/GUI proof.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const test = require("node:test");
const repo = path.resolve(__dirname, "../..");
const read = file => fs.readFileSync(path.join(repo, file), "utf8");

test("production sidebar forwards the existing explicit-consent status row", () => {
    const manifest = JSON.parse(read("windows/combined-prototype/sources.d/sidebar.json"));
    assert.equal(manifest["modules/sidebar/Content.qml"], "modules/sidebar/SidebarContent.qml");
    const adapter = "windows/combined-prototype/adapters/modules/sidebar/Content.qml";
    assert.equal(manifest[adapter], "modules/sidebar/Content.qml");
    assert.match(read(adapter), /SidebarContent\s*\{\s*mirrorControl:\s*Notifs\.mirrorControlEnabled \? Notifs : null/);
    assert.match(read("modules/sidebar/Content.qml"), /property var mirrorControl:\s*null/);
    assert.match(read("modules/sidebar/Content.qml"), /mirrorControl:\s*root\.mirrorControl/);
    assert.doesNotMatch(read(adapter), /onCompleted|requestMirrorAccess|requestAccess|doNotDisturb\s*=/);
    const dock = read("modules/sidebar/NotifDock.qml");
    assert.match(dock, /visible:\s*root\.mirrorControl\?\.canRequestMirrorAccess === true/);
    assert.match(dock, /onClicked:\s*root\.mirrorControl\.requestMirrorAccess\(\)/);
});

test("State reports live notification status and policy without content or writes", () => {
    const source = read("windows/shell/shell.qml");
    const match = source.match(/notifications: \{([\s\S]*?)\n            \}/);
    assert.ok(match);
    const Notifs = {
        enabled: true, status: "local", mirrorOptIn: true,
        mirrorAccessState: "Denied", mirrorStatus: "denied",
        systemMirrorActive: false, doNotDisturb: true,
        list: [{ summary: "private-sentinel", body: "private-body" }],
    };
    const expectedKeys = [
        "enabled", "status", "mirrorOptIn", "access", "mirrorStatus",
        "mirrorActive", "doNotDisturb", "fullscreenPolicy",
    ];
    for (const policy of [0, 1]) {
        const snapshot = vm.runInNewContext(`({${match[1]}})`, {
            Notifs: Object.freeze(Notifs),
            GlobalConfig: { notifs: { fullscreen: policy } },
        });
        assert.deepEqual(Object.keys(snapshot), expectedKeys);
        assert.equal(snapshot.access, "Denied");
        assert.equal(snapshot.mirrorActive, false);
        assert.equal(snapshot.doNotDisturb, true);
        assert.equal(snapshot.fullscreenPolicy, policy === 0 ? "On" : "Off");
        assert.doesNotMatch(JSON.stringify(snapshot), /private-|summary|body|list|history|aumid/i);
    }
});
