const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const test = require("node:test");

const source = fs.readFileSync(path.resolve(__dirname, "../shell/adapters/modules/nexus/pages/bluetooth/BluetoothPairingLogic.js"), "utf8")
    .replace(/^\s*\.pragma library\s*$/gm, "");
const context = vm.createContext({});
vm.runInContext(source, context, { filename: "BluetoothPairingLogic.js" });

test("named devices sort before unnamed and MAC-only devices", () => {
    const devices = [
        { name: "AA-BB-CC-DD-EE-FF", deviceName: "AA-BB-CC-DD-EE-FF", address: "AA:BB:CC:DD:EE:FF" },
        { name: "Headphones", deviceName: "Headphones" },
        { name: "11-22-33-44-55-66", deviceName: "" },
        { name: "AABBCCDDEEFF", deviceName: "AABBCCDDEEFF" },
        { name: "Keyboard", deviceName: "Keyboard" }
    ];
    assert.deepEqual(devices.sort(context.compareDevices).map(device => device.name), [
        "Headphones", "Keyboard", "11-22-33-44-55-66", "AA-BB-CC-DD-EE-FF", "AABBCCDDEEFF"
    ]);
});

test("pairing devices stay first within the named and unnamed groups", () => {
    const devices = [
        { name: "AA-BB-CC-DD-EE-FF", deviceName: "AA-BB-CC-DD-EE-FF", pairing: true },
        { name: "Headphones", deviceName: "Headphones", pairing: true },
        { name: "Keyboard", deviceName: "Keyboard" }
    ];
    assert.deepEqual(devices.sort(context.compareDevices).map(device => device.name), [
        "Headphones", "AA-BB-CC-DD-EE-FF", "Keyboard"
    ]);
});
