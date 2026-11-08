[CmdletBinding()]
param([Parameter(Mandatory)][string]$QtPrefix, [string]$BuildRoot)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Caelestia-QmlFixture.ps1"
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$result = Invoke-QmlFixture -QtPrefix $QtPrefix -BuildRoot $BuildRoot -Name wallpaper-folder -ShellFixture -UseQuickshell `
    -Environment @{ CAELESTIA_WALLPAPER_DIR = 'C:/walls' } `
    -Sources @('windows/tests/WallpaperFolderTest.qml') -FixtureFile 'windows/tests/WallpaperFolderTest.qml' `
    -Marker CAELESTIA_WALLPAPER_FOLDER -MinimumAssertions 50
$result | ConvertTo-Json -Depth 8
if (-not $result.passed) { throw "Wallpaper folder fixture failed. See $($result.stderr)." }

# The fixture loads both real adapters. These text checks keep each surface
# wired to the shared components, so a later move of one page cannot quietly
# drop its folder actions or empty explanation.
foreach ($surface in @(
    @{ name = 'launcher'; path = 'windows/shell/adapters/modules/launcher/WallpaperList.qml' },
    @{ name = 'nexus'; path = 'windows/shell/adapters/modules/nexus/pages/wallandstyle/WallpaperSelect.qml' }
)) {
    $text = Get-Content -LiteralPath (Join-Path $repoRoot $surface.path) -Raw
    if ($text -notmatch 'qs\.components\.wallpaper') { throw "$($surface.name) wallpaper picker does not import the shared folder components." }
    if ($text -notmatch 'WallpaperFolder\s*\{') { throw "$($surface.name) wallpaper picker has no folder actions." }
}
$launcherEmpty = Get-Content -LiteralPath (Join-Path $repoRoot 'windows/shell/adapters/modules/launcher/ContentList.qml') -Raw
if ($launcherEmpty -notmatch 'WallpaperEmptyState\s*\{') { throw 'The launcher empty state lost the folder explanation.' }
$nexusEmpty = Get-Content -LiteralPath (Join-Path $repoRoot 'windows/shell/adapters/modules/nexus/pages/wallandstyle/WallpaperSelect.qml') -Raw
if ($nexusEmpty -notmatch 'WallpaperEmptyState\s*\{') { throw 'The Nexus empty state lost the folder explanation.' }
