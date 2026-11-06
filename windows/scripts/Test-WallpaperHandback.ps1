[CmdletBinding()]
param([Parameter(Mandatory)][string]$QtPrefix, [string]$BuildRoot)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Caelestia-QmlFixture.ps1"
$result = Invoke-QmlFixture -QtPrefix $QtPrefix -BuildRoot $BuildRoot -Name wallpaper-handback -ShellFixture `
    -FakeDirectories @('windows/tests/fakes/shell', 'windows/tests/fakes/native', 'windows/tests/fakes/wallpaper') `
    -Sources @('windows/tests/WallpaperHandbackTest.qml') -FixtureFile 'windows/tests/WallpaperHandbackTest.qml' `
    -Marker CAELESTIA_WALLPAPER_HANDBACK -MinimumAssertions 52
$result | ConvertTo-Json -Depth 8
if (-not $result.passed) { throw "Wallpaper handback fixture failed. See $($result.stderr)." }
