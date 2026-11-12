'use strict';
// Source-policy checks only. Never launch or crash the production executable.
const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const root = path.resolve(__dirname, '../..');
const read = name => fs.readFileSync(path.join(root, name), 'utf8');

test('the shared production builder explicitly enables crash handling', () => {
    const builder = read('windows/scripts/Build-Prototype.ps1');
    assert.match(builder, /'configure-backend'[\s\S]*?'-DCRASH_HANDLER=ON'/);
    assert.doesNotMatch(builder, /-DCRASH_HANDLER=OFF/);
    assert.match(read('windows/ci/Invoke-PairIntegration.ps1'), /Build-Prototype\.ps1/);
    assert.deepEqual(fs.readFileSync(path.join(root, '.github/workflows/windows-build.yml')),
        fs.readFileSync(path.join(root, 'windows/ci/windows-build.yml.template')));
});

test('unsupervised launch paths disable the entire compiled-in handler', () => {
    const launcher = read('windows/scripts/Start-Caelestia.ps1');
    assert.match(launcher, /if \(\$Smoke\) \{[^{}]*EnvironmentVariables\['QS_DISABLE_CRASH_HANDLER'\] = '1'[^{}]*Process\]::Start/);
    assert.match(read('windows/scripts/Test-Smoke.ps1'), /'QS_DISABLE_CRASH_HANDLER' = '1'/);
    const fixture = read('windows/scripts/Caelestia-QmlFixture.ps1');
    const assignment = "$info.EnvironmentVariables['QS_DISABLE_CRASH_HANDLER'] = '1'";
    assert.equal(fixture.split(assignment).length, 2);
    assert.ok(fixture.indexOf(assignment) > fixture.indexOf('foreach ($key in $Environment.Keys)'));
    assert.ok(fixture.indexOf(assignment) < fixture.indexOf('[Diagnostics.Process]::Start'));
    assert.match(read('windows/bench/method.py'), /"QS_DISABLE_CRASH_HANDLER": "1"/);
    // launch.cpp checks presence before init/setRelaunchInfo, so disabling the
    // handler also prevents dump directories, retention and relaunch.
});

test('uninstall keeps the unowned shared crash cache and explains manual removal', () => {
    assert.match(read('windows/scripts/Uninstall-Caelestia.ps1'),
        /Write-Output 'Kept shared Quickshell crash diagnostics: %LOCALAPPDATA%\\quickshell\\cache\\crashes/);
    const common = read('windows/scripts/Caelestia-InstallCommon.ps1');
    assert.match(common, /Shared Quickshell crash diagnostics[\s\S]*?kept either way/);
});
