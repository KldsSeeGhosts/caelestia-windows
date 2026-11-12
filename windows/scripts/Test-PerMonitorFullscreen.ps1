[CmdletBinding()]
param([Parameter(Mandatory)][string]$QtPrefix, [Parameter(Mandatory)][string]$BuildRoot)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Caelestia-QmlFixture.ps1"
$result = Invoke-QmlFixture -QtPrefix $QtPrefix -BuildRoot $BuildRoot -Name per-monitor-fullscreen -ShellFixture -UseQuickshell `
    -FakeDirectories @('windows/tests/fakes/fullscreen') `
    -Sources @('windows/tests/PerMonitorFullscreenTest.qml') -FixtureFile 'windows/tests/PerMonitorFullscreenTest.qml' `
    -Marker CAELESTIA_PER_MONITOR_FULLSCREEN -MinimumAssertions 23 -TimeoutMs 30000
$result | ConvertTo-Json -Depth 8
if (-not $result.passed) { throw "Per-monitor fullscreen fixture failed. See $($result.stderr)." }
