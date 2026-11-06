[CmdletBinding()]
# Discovered by the candidate's service-fixture gate.
param([Parameter(Mandatory)][string]$QtPrefix, [string]$BuildRoot)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Caelestia-QmlFixture.ps1"
$result = Invoke-QmlFixture -QtPrefix $QtPrefix -BuildRoot $BuildRoot -Name wallpaper-screen-target -ShellFixture `
    -FakeDirectories @('windows/tests/fakes/shell', 'windows/tests/fakes/native', 'windows/tests/fakes/wallpaper') `
    -Sources @('windows/tests/WallpaperScreenTargetTest.qml') -FixtureFile 'windows/tests/WallpaperScreenTargetTest.qml' `
    -Environment @{ CAELESTIA_COMBINED_LIVE = '1' } `
    -Marker CAELESTIA_WALLPAPER_SCREEN_TARGET -MinimumAssertions 20
$result | ConvertTo-Json -Depth 8
if (-not $result.passed) { throw "Wallpaper screen target fixture failed. See $($result.stderr)." }
