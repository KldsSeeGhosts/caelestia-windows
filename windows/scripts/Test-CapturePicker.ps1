[CmdletBinding()]
param([Parameter(Mandatory)][string]$QtPrefix, [Parameter(Mandatory)][string]$BuildRoot)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Caelestia-QmlFixture.ps1"
$result = Invoke-QmlFixture -QtPrefix $QtPrefix -BuildRoot $BuildRoot -Name capture-picker -ShellFixture -UseQuickshell `
    -Sources @('windows/tests/CapturePickerTest.qml') -FixtureFile 'windows/tests/CapturePickerTest.qml' `
    -Marker CAELESTIA_CAPTURE_PICKER -MinimumAssertions 155 -TimeoutMs 60000
$result | ConvertTo-Json -Depth 8
if (-not $result.passed) { throw "Capture picker fixture failed. See $($result.stderr)." }
