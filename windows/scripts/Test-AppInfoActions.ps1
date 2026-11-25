#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory)][string]$QtPrefix, [string]$BuildRoot)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Caelestia-QmlFixture.ps1"
$result = Invoke-QmlFixture -QtPrefix $QtPrefix -BuildRoot $BuildRoot -Name appinfo-actions -ShellFixture -UseQuickshell `
    -Sources @('windows/tests/AppInfoActionsTest.qml') -FixtureFile 'windows/tests/AppInfoActionsTest.qml' `
    -Marker CAELESTIA_APPINFO_ACTIONS -MinimumAssertions 20 -TimeoutMs 30000
$result | ConvertTo-Json -Depth 8
if (-not $result.passed) { throw "AppInfo actions fixture failed. See $($result.stderr)." }
