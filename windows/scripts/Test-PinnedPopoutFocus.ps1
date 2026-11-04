[CmdletBinding()]
param([Parameter(Mandatory)][string]$QtPrefix, [Parameter(Mandatory)][string]$BuildRoot)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Caelestia-QmlFixture.ps1"
$result = Invoke-QmlFixture -QtPrefix $QtPrefix -BuildRoot $BuildRoot -Name pinned-popout-focus -ShellFixture -UseQuickshell `
    -Sources @('windows/tests/PinnedPopoutFocusTest.qml') -FixtureFile 'windows/tests/PinnedPopoutFocusTest.qml' `
    -Marker CAELESTIA_PINNED_FOCUS -MinimumAssertions 14 -TimeoutMs 30000
$result | ConvertTo-Json -Depth 8
if (-not $result.passed) { throw "Pinned popout focus fixture failed. See $($result.stderr)." }
