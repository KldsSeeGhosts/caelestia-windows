[CmdletBinding()]
param([Parameter(Mandatory)][string]$QtPrefix, [Parameter(Mandatory)][string]$BuildRoot)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Caelestia-QmlFixture.ps1"
$result = Invoke-QmlFixture -QtPrefix $QtPrefix -BuildRoot $BuildRoot -Name a11y-launcher -ShellFixture -UseQuickshell `
    -Sources @('windows/tests/AccessibilityLauncherTest.qml') -FixtureFile 'windows/tests/AccessibilityLauncherTest.qml' `
    -Marker CAELESTIA_A11Y -MinimumAssertions 8
$result | ConvertTo-Json -Depth 8
if (-not $result.passed) { throw "Launcher accessibility fixture failed. See $($result.stderr)." }
