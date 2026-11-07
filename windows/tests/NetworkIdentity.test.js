const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");
const vm = require("node:vm");

const source = fs.readFileSync(path.join(__dirname, "../services/network/Nmcli.qml"), "utf8").replace(/\r\n/g, "\n");
function setup() {
    const destroyed = [];
    const root = { _networkWrappers: {}, _networks: [], networkSources: [],
        get networks() { return this._networks; },
        accessPointComponent: { createObject(parent, { raw }) {
            return { raw, get ssid() { return this.raw.ssid; },
                get selectionId() { return this.raw.selectionId || ""; },
                destroy() { destroyed.push(this); } };
        } } };
    const context = vm.createContext({ root });
    for (const name of ["networkKey", "syncNetworks", "findNetwork", "findNetworkById"]) {
        const match = source.match(new RegExp(`function ${name}\\(([^)]*)\\): [^{]+\\{([\\s\\S]*?)\\n    \\}`));
        assert.ok(match, `actual ${name} function exists`);
        root[name] = vm.runInContext(`(function (${match[1]}) {${match[2]}\n})`, context);
    }
    return { root, destroyed };
}

test("same display/BSSID rows retain distinct native selection identities", () => {
    const { root } = setup();
    root.networkSources = [
        { selectionId: "adapter-profile-a", ssid: "Shared", bssid: "synthetic-bssid" },
        { selectionId: "adapter-profile-b", ssid: "Shared", bssid: "synthetic-bssid" },
    ];
    root.syncNetworks();
    assert.equal(root.networks.length, 2);
    assert.notEqual(root.networks[0], root.networks[1]);
    assert.equal(root.findNetwork("Shared"), null);
    assert.equal(root.findNetworkById("adapter-profile-b"), root.networks[1]);
});

test("same native ID preserves wrappers through raw row replacement", () => {
    const { root } = setup();
    root.networkSources = [{ selectionId: "stable", ssid: "Before" }];
    root.syncNetworks();
    const point = root.networks[0];
    root.networkSources = [{ selectionId: "stable", ssid: "After" }];
    root.syncNetworks();
    assert.equal(root.networks[0], point);
    assert.equal(point.ssid, "After");
});

test("removed selection cannot silently retarget to a same-name profile", () => {
    const { root, destroyed } = setup();
    root.networkSources = [{ selectionId: "old-profile", ssid: "Shared" }];
    root.syncNetworks();
    const previous = root.networks[0];
    root.networkSources = [{ selectionId: "replacement-profile", ssid: "Shared" }];
    root.syncNetworks();
    assert.equal(root.findNetworkById("old-profile"), null);
    assert.notEqual(root.networks[0], previous);
    assert.deepEqual(destroyed, [previous]);
});

test("legacy display-name lookup refuses collisions", () => {
    const { root } = setup();
    root.networkSources = [{ ssid: "Shared", bssid: "a" }, { ssid: "Shared", bssid: "b" }];
    root.syncNetworks();
    assert.equal(root.findNetwork("Shared"), null);
    assert.equal(root.findNetworkById(""), null);
});

test("detail lookup keeps a missing selected ID missing, without name fallback", () => {
    const text = fs.readFileSync(path.join(__dirname,
        "../shell/adapters/modules/nexus/pages/network/NetworkDetailPage.qml"), "utf8").replace(/\r\n/g, "\n");
    const expression = text.match(/readonly property var ap: ([\s\S]*?)\n    readonly property bool/);
    assert.ok(expression);
    const calls = [];
    const context = vm.createContext({
        root: { nState: { selectedNetworkId: "gone", selectedNetworkSsid: "Shared" } },
        Nmcli: { findNetworkById(id) { calls.push(id); return null; },
            findNetwork() { throw Error("unsafe display-name fallback"); } },
    });
    assert.equal(vm.runInContext(expression[1], context), null);
    assert.deepEqual(calls, ["gone"]);
    assert.match(text, /Nmcli\.forgetAccessPoint\(root\.ap\)/);
});
