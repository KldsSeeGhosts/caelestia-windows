const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const test = require("node:test");

const harness = fs.readFileSync(path.resolve(__dirname, "../scripts/Caelestia-QmlFixture.ps1"), "utf8");

test("offscreen fixtures resolve the matching SDK platform plugin before launching", () => {
    const preflight = harness.indexOf("'qoffscreen.dll'");
    const launch = harness.indexOf("[Diagnostics.Process]::Start($info)");
    assert.ok(preflight > 0 && launch > preflight);
    assert.match(harness, /EnvironmentVariables\['QT_QPA_PLATFORM_PLUGIN_PATH'\]\s*=\s*\$platformPlugins/);
    assert.match(harness, /EnvironmentVariables\['QT_PLUGIN_PATH'\]\s*=\s*Join-Path \$QtPrefix 'plugins'/);
    assert.match(harness, /developer Qt and installed runtime differ/);
});
