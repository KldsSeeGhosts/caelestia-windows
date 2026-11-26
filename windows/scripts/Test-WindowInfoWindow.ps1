[CmdletBinding()]
param([Parameter(Mandatory)][string]$QtPrefix, [Parameter(Mandatory)][string]$BuildRoot)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Caelestia-QmlFixture.ps1"
$result = Invoke-QmlFixture -QtPrefix $QtPrefix -BuildRoot $BuildRoot -Name windowinfo-window -ShellFixture -UseQuickshell `
    -Sources @('windows/tests/WindowInfoWindowTest.qml') -FixtureFile 'windows/tests/WindowInfoWindowTest.qml' `
    -Marker CAELESTIA_WINDOWINFO_WINDOW -MinimumAssertions 12 -TimeoutMs 30000
$result | ConvertTo-Json -Depth 8
if (-not $result.passed) { throw "WindowInfo window fixture failed. See $($result.stderr)." }
