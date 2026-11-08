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
# the facade instead of a dead row that only flips a local toggle.
$servicesPage = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\shell\adapters\modules\nexus\pages\ServicesPage.qml') -Raw -Encoding UTF8
foreach ($required in @(
    'Needs Wallpaper Engine installed and running',
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
$result = Invoke-QmlFixture -QtPrefix $QtPrefix -BuildRoot $BuildRoot -Name wallpaper-defaults -ShellFixture `
    -FakeDirectories @('windows/tests/fakes/shell', 'windows/tests/fakes/native', 'windows/tests/fakes/wallpaper') `
    -Sources @('windows/tests/WallpaperDefaultsTest.qml') -FixtureFile 'windows/tests/WallpaperDefaultsTest.qml' `
    -Marker CAELESTIA_WALLPAPER_DEFAULTS -MinimumAssertions 40
$result | ConvertTo-Json -Depth 8
if (-not $result.passed) { throw "Wallpaper defaults fixture failed. See $($result.stderr)." }
