[CmdletBinding()]
param([Parameter(Mandatory)][string]$QtPrefix, [Parameter(Mandatory)][string]$BuildRoot)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Caelestia-QmlFixture.ps1"
$result = Invoke-QmlFixture -QtPrefix $QtPrefix -BuildRoot $BuildRoot -Name idle-status -ShellFixture -UseQuickshell `
    -FakeDirectories @('windows/tests/fakes/idle') `
    -Sources @('windows/tests/IdleInhibitStatusTest.qml') -FixtureFile 'windows/tests/IdleInhibitStatusTest.qml' `
    -Marker CAELESTIA_IDLE_STATUS -MinimumAssertions 10
$result | ConvertTo-Json -Depth 8
if (-not $result.passed) { throw "Idle status fixture failed. See $($result.stderr)." }
