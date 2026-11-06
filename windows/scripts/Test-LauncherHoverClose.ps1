[CmdletBinding()]
param([Parameter(Mandatory)][string]$QtPrefix, [Parameter(Mandatory)][string]$BuildRoot)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Caelestia-QmlFixture.ps1"
$result = Invoke-QmlFixture -QtPrefix $QtPrefix -BuildRoot $BuildRoot -Name launcher-hover -ShellFixture -UseQuickshell `
    -Sources @('windows/tests/LauncherHoverCloseTest.qml') -FixtureFile 'windows/tests/LauncherHoverCloseTest.qml' `
    -Marker CAELESTIA_LAUNCHER_HOVER -MinimumAssertions 14
$result | ConvertTo-Json -Depth 8
if (-not $result.passed) { throw "Launcher hover fixture failed. See $($result.stderr)." }
