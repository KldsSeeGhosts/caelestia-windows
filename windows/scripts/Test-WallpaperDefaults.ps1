[CmdletBinding()]
param([Parameter(Mandatory)][string]$QtPrefix, [string]$BuildRoot)
$ErrorActionPreference = 'Stop'
$defaultsPath = Join-Path $PSScriptRoot '..\shell\windows.json'
$defaults = Get-Content -LiteralPath $defaultsPath -Raw -Encoding UTF8 | ConvertFrom-Json
# A missing key would also be acceptable to the QML default, but the shipped
# fresh profile must state the opt-out so nobody reads the payload as a
# recommendation to use Wallpaper Engine.
if ($null -eq $defaults.windows.wallpaperEngine -or
    $defaults.windows.wallpaperEngine.enabled -ne $false) {
    throw 'windows/shell/windows.json must ship windows.wallpaperEngine.enabled=false.'
}
# Nexus hosts the opt-in. Keep the explanation and unavailable states wired to
# the facade instead of a dead row that only flips a local toggle. A handed-back
# engine still runs but no longer covers the desktop, so the status must not
# claim that it does.
$servicesPage = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\shell\adapters\modules\nexus\pages\ServicesPage.qml') -Raw -Encoding UTF8
foreach ($required in @(
    'Needs Wallpaper Engine installed and running',
    'resumes its wallpapers on all displays',
    'stops Wallpaper Engine wallpapers without quitting Wallpaper Engine',
    'handed the desktop back',
    'its wallpaper covers the desktop until it does',
    'checked: WallpaperEngine.enabled',
    'onToggled: WallpaperEngine.setEnabled(checked)',
    'Not installed',
    'Installed, not running'
)) {
    if ($servicesPage.IndexOf($required, [StringComparison]::Ordinal) -lt 0) {
        throw "Nexus Services no longer explains the Wallpaper Engine opt-in: missing '$required'."
    }
}
. "$PSScriptRoot\Caelestia-QmlFixture.ps1"
# Each fixture runs in its own process because a profile is classified and a
# wallpaper source resolved once per start. Separate profiles are how the fresh
# restart, upgrade, pick restart, damaged-record and retry paths are exercised
# for real.
$fixtures = @(
    [ordered]@{ name = 'wallpaper-defaults'; source = 'windows/tests/WallpaperDefaultsTest.qml'
        marker = 'CAELESTIA_WALLPAPER_DEFAULTS'; minimum = 95 },
    [ordered]@{ name = 'wallpaper-engine-off'; source = 'windows/tests/WallpaperEngineDisabledTest.qml'
        marker = 'CAELESTIA_WALLPAPER_ENGINE_OFF'; minimum = 24 },
    [ordered]@{ name = 'wallpaper-restart'; source = 'windows/tests/WallpaperRestartTest.qml'
        marker = 'CAELESTIA_WALLPAPER_RESTART'; minimum = 25 },
    [ordered]@{ name = 'wallpaper-upgrade'; source = 'windows/tests/WallpaperUpgradeTest.qml'
        marker = 'CAELESTIA_WALLPAPER_UPGRADE'; minimum = 18 },
    [ordered]@{ name = 'wallpaper-provenance'; source = 'windows/tests/WallpaperProvenanceTest.qml'
        marker = 'CAELESTIA_WALLPAPER_PROVENANCE'; minimum = 8 },
    [ordered]@{ name = 'wallpaper-record-retry'; source = 'windows/tests/WallpaperRecordRetryTest.qml'
        marker = 'CAELESTIA_WALLPAPER_RECORD_RETRY'; minimum = 25 },
    [ordered]@{ name = 'wallpaper-invalid-record'; source = 'windows/tests/WallpaperInvalidRecordTest.qml'
        marker = 'CAELESTIA_WALLPAPER_INVALID'; minimum = 12 },
    [ordered]@{ name = 'wallpaper-future-record'; source = 'windows/tests/WallpaperFutureRecordTest.qml'
        marker = 'CAELESTIA_WALLPAPER_FUTURE'; minimum = 7 },
    [ordered]@{ name = 'wallpaper-engine-config'; source = 'windows/tests/WallpaperEngineConfigTest.qml'
        marker = 'CAELESTIA_WALLPAPER_ENGINE_CONFIG'; minimum = 29 },
    # One scenario, two profiles: the released behaviour for an existing
    # profile and the fresh-profile policy are asserted from the same code.
    [ordered]@{ name = 'wallpaper-engine-handback-existing'; source = 'windows/tests/WallpaperEngineHandbackExistingTest.qml'
        extraSources = @('windows/tests/WallpaperEngineHandbackScenario.qml')
        marker = 'CAELESTIA_WALLPAPER_ENGINE_HANDBACK'; minimum = 14 },
    [ordered]@{ name = 'wallpaper-engine-handback-fresh'; source = 'windows/tests/WallpaperEngineHandbackFreshTest.qml'
        extraSources = @('windows/tests/WallpaperEngineHandbackScenario.qml')
        marker = 'CAELESTIA_WALLPAPER_ENGINE_HANDBACK'; minimum = 12 }
)
foreach ($fixture in $fixtures) {
    $sources = @($fixture.source)
    if ($fixture.Contains('extraSources')) {
        $sources += $fixture.extraSources
    }
    $result = Invoke-QmlFixture -QtPrefix $QtPrefix -BuildRoot $BuildRoot -Name $fixture.name -ShellFixture `
        -FakeDirectories @('windows/tests/fakes/shell', 'windows/tests/fakes/native', 'windows/tests/fakes/wallpaper') `
        -Sources $sources -FixtureFile $fixture.source `
        -Marker $fixture.marker -MinimumAssertions $fixture.minimum
    $result | ConvertTo-Json -Depth 8
    if (-not $result.passed) {
        throw "Wallpaper fixture '$($fixture.name)' failed. See $($result.stderr)."
    }
}
