[CmdletBinding()]
param([Parameter(Mandatory)][string]$QtPrefix, [string]$BuildRoot)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Caelestia-QmlFixture.ps1"
$result = Invoke-QmlFixture -QtPrefix $QtPrefix -BuildRoot $BuildRoot -Name hover-regions -ShellFixture -UseQuickshell `
    -Sources @('windows/tests/WindowsHoverRegionsTest.qml') -FixtureFile 'windows/tests/WindowsHoverRegionsTest.qml' `
    -Marker CAELESTIA_HOVER_REGIONS -MinimumAssertions 30
$result | ConvertTo-Json -Depth 8
if (-not $result.passed) { throw "Hover region fixture failed. See $($result.stderr)." }
