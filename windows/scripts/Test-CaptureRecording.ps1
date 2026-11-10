[CmdletBinding()]
param([Parameter(Mandatory)][string]$QtPrefix, [Parameter(Mandatory)][string]$BuildRoot)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Caelestia-QmlFixture.ps1"
$result = Invoke-QmlFixture -QtPrefix $QtPrefix -BuildRoot $BuildRoot -Name capture-recording -ShellFixture -UseQuickshell `
    -Sources @('windows/tests/CaptureRecordingTest.qml') -FixtureFile 'windows/tests/CaptureRecordingTest.qml' `
    -Marker CAELESTIA_CAPTURE_RECORDING -MinimumAssertions 22 -TimeoutMs 20000
$result | ConvertTo-Json -Depth 8
if (-not $result.passed) { throw "Capture recording fixture failed. See $($result.stdout) and $($result.stderr)." }
