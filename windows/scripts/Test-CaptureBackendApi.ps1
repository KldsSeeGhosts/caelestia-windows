[CmdletBinding()]
param([Parameter(Mandatory)][string]$QtPrefix, [Parameter(Mandatory)][string]$BuildRoot)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Caelestia-QmlFixture.ps1"
$result = Invoke-QmlFixture -QtPrefix $QtPrefix -BuildRoot $BuildRoot -Name capture-backend-api -ShellFixture -UseQuickshell `
    -Sources @('windows/tests/CaptureBackendApiTest.qml') -FixtureFile 'windows/tests/CaptureBackendApiTest.qml' `
    -Marker CAELESTIA_CAPTURE_BACKEND_API -MinimumAssertions 15
$result | ConvertTo-Json -Depth 8
if (-not $result.passed) { throw "Capture backend API fixture failed. See $($result.stderr)." }
