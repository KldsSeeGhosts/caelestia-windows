[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QtPrefix,
    [string]$BuildRoot
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Caelestia-QmlFixture.ps1"
$result = Invoke-QmlFixture -QtPrefix $QtPrefix -BuildRoot $BuildRoot -Name network `
    -Sources @('windows/services/network/NetworkService.qml',
        'windows/services/network/NetworkServiceTest.qml') `
    -FixtureFile 'windows/services/network/NetworkServiceTest.qml' -Marker CAELESTIA_NETWORK_FIXTURE -MinimumAssertions 150
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath ($result.stdout -replace '\.stdout\.log$', '.json') -Encoding UTF8
$result | ConvertTo-Json -Depth 8
if (-not $result.passed) { throw "Service fixture failed. See $($result.stdout) and $($result.stderr)." }

$identity = Invoke-QmlFixture -QtPrefix $QtPrefix -Name network-identity `
    -FakeDirectories @('windows/tests/fakes/network-identity') `
    -Sources @('windows/services/network/NativeNetworkBackend.qml',
        'windows/services/network/NativeNetworkIdentityTest.qml') `
    -FixtureFile 'windows/services/network/NativeNetworkIdentityTest.qml' `
    -Marker CAELESTIA_NETWORK_IDENTITY -MinimumAssertions 12
$identity | ConvertTo-Json -Depth 8
if (-not $identity.passed) { throw "Native identity projection fixture failed. See $($identity.stderr)." }
