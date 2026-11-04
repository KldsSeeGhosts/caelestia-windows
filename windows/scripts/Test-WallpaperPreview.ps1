[CmdletBinding()]
param([Parameter(Mandatory)][string]$QtPrefix, [string]$BuildRoot)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Caelestia-QmlFixture.ps1"
$result = Invoke-QmlFixture -QtPrefix $QtPrefix -BuildRoot $BuildRoot -Name wallpaper-preview -ShellFixture `
    -FakeDirectories @('windows/tests/fakes/shell', 'windows/tests/fakes/native', 'windows/tests/fakes/wallpaper') `
    -Sources @('windows/tests/WallpaperPreviewTest.qml') -FixtureFile 'windows/tests/WallpaperPreviewTest.qml' `
    -Marker CAELESTIA_WALLPAPER_PREVIEW -MinimumAssertions 8
$result | ConvertTo-Json -Depth 8
if (-not $result.passed) { throw "Wallpaper preview fixture failed. See $($result.stderr)." }
