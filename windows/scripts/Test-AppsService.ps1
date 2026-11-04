[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QtPrefix,
    [string]$BuildRoot
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Caelestia-QmlFixture.ps1"
$result = Invoke-QmlFixture -QtPrefix $QtPrefix -BuildRoot $BuildRoot -Name apps -KeepRelativePaths `
    -Sources @('windows/services/apps/AppsService.qml',
        'windows/services/apps/AppFrequencyStore.qml',
        'windows/services/apps/AppStoragePath.js',
        'windows/services/apps/AppsServiceTest.qml',
        'utils/scripts/fzf.js',
        'utils/scripts/fuzzysort.js') `
    -FixtureFile 'windows/services/apps/AppsServiceTest.qml' -Marker CAELESTIA_APPS_FIXTURE -MinimumAssertions 100
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath ($result.stdout -replace '\.stdout\.log$', '.json') -Encoding UTF8
$result | ConvertTo-Json -Depth 8
if (-not $result.passed) { throw "Service fixture failed. See $($result.stdout) and $($result.stderr)." }
