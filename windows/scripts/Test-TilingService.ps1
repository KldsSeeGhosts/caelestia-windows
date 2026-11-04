[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QtPrefix,
    [string]$BuildRoot
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Caelestia-QmlFixture.ps1"
$result = Invoke-QmlFixture -QtPrefix $QtPrefix -BuildRoot $BuildRoot -Name tiling `
    -Sources @('windows/services/tiling/TilingService.qml',
        'windows/services/tiling/TilingServiceTest.qml') `
    -FixtureFile 'windows/services/tiling/TilingServiceTest.qml' -Marker CAELESTIA_TILING_FIXTURE -MinimumAssertions 213
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath ($result.stdout -replace '\.stdout\.log$', '.json') -Encoding UTF8
$result | ConvertTo-Json -Depth 8
if (-not $result.passed) { throw "Service fixture failed. See $($result.stdout) and $($result.stderr)." }
