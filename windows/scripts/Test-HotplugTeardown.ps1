[CmdletBinding()]
param([Parameter(Mandatory)][string]$QtPrefix, [Parameter(Mandatory)][string]$BuildRoot)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Caelestia-QmlFixture.ps1"
$result = Invoke-QmlFixture -QtPrefix $QtPrefix -BuildRoot $BuildRoot -Name hotplug-teardown -ShellFixture -UseQuickshell `
    -FakeDirectories @('windows/tests/fakes/hotplug') `
    -Sources @('windows/tests/HotplugTeardownTest.qml') -FixtureFile 'windows/tests/HotplugTeardownTest.qml' `
    -Marker CAELESTIA_HOTPLUG_TEARDOWN -MinimumAssertions 21 -TimeoutMs 30000
$result | ConvertTo-Json -Depth 8
if (-not $result.passed) { throw "Hotplug teardown fixture failed. See $($result.stderr)." }
