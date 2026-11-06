[CmdletBinding()]
param([Parameter(Mandatory)][string]$QtPrefix, [Parameter(Mandatory)][string]$BuildRoot)
$ErrorActionPreference = 'Stop'
& "$PSScriptRoot\Test-UpdatesStatus.ps1"
. "$PSScriptRoot\Caelestia-QmlFixture.ps1"
$result = Invoke-QmlFixture -QtPrefix $QtPrefix -BuildRoot $BuildRoot -Name updates-page -ShellFixture -UseQuickshell `
    -Sources @('windows/tests/UpdatesPageTest.qml') -FixtureFile 'windows/tests/UpdatesPageTest.qml' `
    -Marker CAELESTIA_UPDATES -MinimumAssertions 18
$result | ConvertTo-Json -Depth 8
if (-not $result.passed) { throw "Updates page fixture failed. See $($result.stderr)." }
