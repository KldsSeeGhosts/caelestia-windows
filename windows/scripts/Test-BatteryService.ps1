[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QtPrefix,
    [string]$BuildRoot
)

$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Caelestia-QmlFixture.ps1"
# Keep the shared stage and per-fixture log suffixes used by evidence callers.
$runName = 'battery-fixture-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
$battery = Invoke-QmlFixture -QtPrefix $QtPrefix -BuildRoot $BuildRoot -Name battery -RunName $runName -LogSuffix battery `
    -Sources @('windows/services/battery/BatteryService.qml', 'windows/services/battery/BatteryServiceTest.qml') `
    -FixtureFile 'windows/services/battery/BatteryServiceTest.qml' -Marker CAELESTIA_BATTERY_FIXTURE -MinimumAssertions 128
$profiles = Invoke-QmlFixture -QtPrefix $QtPrefix -BuildRoot $BuildRoot -Name battery -RunName $runName -LogSuffix profiles `
    -Sources @('windows/services/battery/PowerProfilesService.qml', 'windows/services/battery/PowerProfilesServiceTest.qml',
        'windows/services/battery/PowerProfilesBackend.qml') `
    -FixtureFile 'windows/services/battery/PowerProfilesServiceTest.qml' -Marker CAELESTIA_POWER_PROFILES_FIXTURE -MinimumAssertions 132
$battery.name = 'battery'
$battery.minimumAssertions = 128
$profiles.name = 'profiles'
$profiles.minimumAssertions = 132
# Retain the aggregate and legacy battery fixture fields for existing callers.
$result = [ordered]@{
    passed = $battery.passed -and $profiles.passed
    timedOut = $battery.timedOut -or $profiles.timedOut
    exitCode = $battery.exitCode
    battery = $battery; profiles = $profiles; fixture = $battery.fixture
    diagnostics = @($battery.diagnostics) + @($profiles.diagnostics)
    sourceRevision = $battery.sourceRevision; sourceDirty = $battery.sourceDirty
    qtVersion = $battery.qtVersion; runnerSha256 = $battery.runnerSha256
    command = $battery.command; stage = $battery.stage
    sources = @($battery.sources) + @($profiles.sources)
}
$result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath ($battery.stdout -replace '\.battery\.stdout\.log$', '.json') -Encoding UTF8
$result | ConvertTo-Json -Depth 8
if (-not $result.passed) {
    throw "Battery fixture failed. See $($battery.stderr) and $($profiles.stderr)."
}
