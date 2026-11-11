// Headless checks that the staged Windows Nexus pages do not present settings
// whose keys have no Windows consumer. This is a staging/UI contract check, not
// a rendered-page test.
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { test } = require("node:test");

const repo = path.resolve(__dirname, "../..");
const read = file => fs.readFileSync(path.join(repo, file), "utf8").replace(/\r\n/g, "\n");
const manifest = JSON.parse(read("windows/shell/sources.json"));

test("Notifications uses a Windows adapter without toast-event controls", () => {
    const adapter = "windows/shell/adapters/modules/nexus/pages/services/NotificationsPage.qml";
    assert.equal(manifest[adapter], "modules/nexus/pages/services/NotificationsPage.qml");
    const source = read(adapter);
    for (const flag of ["chargingChanged", "gameModeChanged", "dndChanged",
        "audioOutputChanged", "audioInputChanged", "capsLockChanged", "numLockChanged",
        "kbLayoutChanged", "vpnChanged", "nowPlaying"]) {
        assert.ok(!source.includes(`GlobalConfig.utilities.toasts.${flag}`),
            `${flag} is still presented without a Windows producer`);
    }
    assert.ok(!source.includes('Tr.tr("Toast events")'), "the empty Toast events section remains");
    for (const supported of ["GlobalConfig.notifs.fullscreen", "GlobalConfig.utilities.toasts.fullscreen",
        "GlobalConfig.utilities.maxToasts"]) {
        assert.ok(source.includes(supported), `supported control ${supported} was removed`);
    }
});

test("Services omits settings without a Windows stats, scan or vendor consumer", () => {
    const source = read("windows/shell/adapters/modules/nexus/pages/ServicesPage.qml");
    for (const key of ["GlobalConfig.dashboard.resourceUpdateInterval",
        "GlobalConfig.nexus.networkRescanInterval", "GlobalConfig.services.gpuType"]) {
        assert.ok(!source.includes(key), `${key} is still presented as a live control`);
    }
    for (const label of ["System stats refresh", "Wi-Fi rescan", "GPU"]) {
        assert.ok(!source.includes(`Tr.tr("${label}")`), `${label} still has a row label`);
    }
    assert.ok(source.includes('Tr.tr("Media refresh")'), "the supported polling control was removed");
    assert.ok(source.includes('Tr.tr("Smart colour scheme")'), "the supported scheme control was removed");
});
