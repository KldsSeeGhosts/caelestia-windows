[CmdletBinding()]
param([Parameter(Mandatory)][string]$QtPrefix, [Parameter(Mandatory)][string]$BuildRoot)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Caelestia-QmlFixture.ps1"
$result = Invoke-QmlFixture -QtPrefix $QtPrefix -BuildRoot $BuildRoot -Name nexus-window -ShellFixture -UseQuickshell `
    -Sources @('windows/tests/NexusWindowTest.qml') -FixtureFile 'windows/tests/NexusWindowTest.qml' `
    -Marker CAELESTIA_NEXUS_WINDOW -MinimumAssertions 12 -TimeoutMs 30000
$result | ConvertTo-Json -Depth 8
if (-not $result.passed) { throw "Nexus window fixture failed. See $($result.stderr)." }
