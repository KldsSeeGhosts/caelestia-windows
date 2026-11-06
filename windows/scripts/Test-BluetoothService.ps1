[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QtPrefix,
    [string]$BuildRoot
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Caelestia-QmlFixture.ps1"
$result = Invoke-QmlFixture -QtPrefix $QtPrefix -BuildRoot $BuildRoot -Name bluetooth `
    -Sources @('windows/services/bluetooth/BluetoothService.qml',
        'windows/services/bluetooth/BluetoothServiceTest.qml') `
    -FixtureFile 'windows/services/bluetooth/BluetoothServiceTest.qml' -Marker CAELESTIA_BLUETOOTH_FIXTURE -MinimumAssertions 100
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath ($result.stdout -replace '\.stdout\.log$', '.json') -Encoding UTF8
$result | ConvertTo-Json -Depth 8
if (-not $result.passed) { throw "Service fixture failed. See $($result.stdout) and $($result.stderr)." }
