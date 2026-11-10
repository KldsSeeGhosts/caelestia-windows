[CmdletBinding()]
param([Parameter(Mandatory)][string]$QtPrefix, [string]$BuildRoot)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Caelestia-QmlFixture.ps1"
$result = Invoke-QmlFixture -QtPrefix $QtPrefix -BuildRoot $BuildRoot -Name wallpaper-ipc -ShellFixture `
    -FakeDirectories @('windows/tests/fakes/shell', 'windows/tests/fakes/native', 'windows/tests/fakes/wallpaper') `
    -Sources @('windows/tests/WallpaperIpcTest.qml') -FixtureFile 'windows/tests/WallpaperIpcTest.qml' `
    -Marker CAELESTIA_WALLPAPER_IPC -MinimumAssertions 20
$result | ConvertTo-Json -Depth 8
if (-not $result.passed) { throw "Wallpaper IPC fixture failed. See $($result.stderr)." }
