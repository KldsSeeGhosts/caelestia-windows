[CmdletBinding()]
param([Parameter(Mandatory)][string]$QtPrefix, [Parameter(Mandatory)][string]$BuildRoot)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Caelestia-QmlFixture.ps1"
$result = Invoke-QmlFixture -QtPrefix $QtPrefix -BuildRoot $BuildRoot -Name a11y-notifications -ShellFixture -UseQuickshell `
    -Sources @('windows/tests/AccessibilityNotificationsTest.qml') -FixtureFile 'windows/tests/AccessibilityNotificationsTest.qml' `
    -Marker CAELESTIA_A11Y -MinimumAssertions 14
$result | ConvertTo-Json -Depth 8
if (-not $result.passed) { throw "Notification accessibility fixture failed. See $($result.stderr)." }
