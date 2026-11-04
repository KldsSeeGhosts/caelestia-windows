[CmdletBinding()]
param([Parameter(Mandatory)][string]$QtPrefix, [Parameter(Mandatory)][string]$BuildRoot)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Caelestia-QmlFixture.ps1"
$result = Invoke-QmlFixture -QtPrefix $QtPrefix -BuildRoot $BuildRoot -Name background-handback -ShellFixture -UseQuickshell -Render `
    -ShellConfig '{"background":{"desktopClock":{"enabled":true,"background":{"enabled":true,"blur":true}}}}' `
    -Sources @('windows/tests/WindowsBackgroundHandbackTest.qml') -FixtureFile 'windows/tests/WindowsBackgroundHandbackTest.qml' `
    -Marker CAELESTIA_BACKGROUND_HANDBACK -MinimumAssertions 16 -TimeoutMs 30000
$result | ConvertTo-Json -Depth 8
if (-not $result.passed) { throw "Background handback fixture failed. See $($result.stderr)." }
