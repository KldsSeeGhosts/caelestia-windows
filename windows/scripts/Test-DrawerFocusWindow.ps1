[CmdletBinding()]
param([Parameter(Mandatory)][string]$QtPrefix, [Parameter(Mandatory)][string]$BuildRoot)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Caelestia-QmlFixture.ps1"
$result = Invoke-QmlFixture -QtPrefix $QtPrefix -BuildRoot $BuildRoot -Name drawer-focus-window -ShellFixture -UseQuickshell `
    -Sources @('windows/tests/DrawerFocusWindowTest.qml') -FixtureFile 'windows/tests/DrawerFocusWindowTest.qml' `
    -Marker CAELESTIA_DRAWER_FOCUS -MinimumAssertions 97 -TimeoutMs 30000
$result | ConvertTo-Json -Depth 8
if (-not $result.passed) { throw "Drawer focus companion fixture failed. See $($result.stderr)." }
