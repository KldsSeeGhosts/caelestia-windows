[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QtPrefix,
    [string]$BuildRoot
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Caelestia-QmlFixture.ps1"
$result = Invoke-QmlFixture -QtPrefix $QtPrefix -BuildRoot $BuildRoot -Name hypr `
    -Sources @('windows/services/hypr/HyprService.qml',
        'windows/services/hypr/HyprServiceTest.qml') `
    -FixtureFile 'windows/services/hypr/HyprServiceTest.qml' -Marker CAELESTIA_HYPR_FIXTURE -MinimumAssertions 120
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath ($result.stdout -replace '\.stdout\.log$', '.json') -Encoding UTF8
$result | ConvertTo-Json -Depth 8
if (-not $result.passed) { throw "Service fixture failed. See $($result.stdout) and $($result.stderr)." }
