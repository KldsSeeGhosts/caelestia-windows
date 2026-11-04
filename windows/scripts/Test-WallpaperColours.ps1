[CmdletBinding()]
param([Parameter(Mandatory)][string]$QtPrefix, [string]$BuildRoot)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Caelestia-QmlFixture.ps1"
$result = Invoke-QmlFixture -QtPrefix $QtPrefix -BuildRoot $BuildRoot -Name wallpaper-colours -ShellFixture `
    -FakeDirectories @('windows/tests/fakes/shell', 'windows/tests/fakes/native', 'windows/tests/fakes/wallpaper') `
    -Sources @('windows/tests/WallpaperColoursTest.qml') -FixtureFile 'windows/tests/WallpaperColoursTest.qml' `
    -Marker CAELESTIA_WALLPAPER_COLOURS -MinimumAssertions 35
$result | ConvertTo-Json -Depth 8
if (-not $result.passed) { throw "Wallpaper colours fixture failed. See $($result.stderr)." }
