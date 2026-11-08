[CmdletBinding()]
param([Parameter(Mandatory)][string]$QtPrefix, [string]$BuildRoot, [string]$OutputRoot)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\Caelestia-QmlFixture.ps1"
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
if (-not $OutputRoot) {
    $OutputRoot = if ($env:CAELESTIA_TEST_OUTPUT_ROOT) { $env:CAELESTIA_TEST_OUTPUT_ROOT }
        else { Join-Path ([IO.Path]::GetTempPath()) ('caelestia-wallpaper-folder-' + [guid]::NewGuid().ToString('N')) }
}
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
if ($OutputRoot -eq $repoRoot -or
    $OutputRoot.StartsWith($repoRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Wallpaper folder test output must stay outside the source checkout.'
}
if ($OutputRoot.StartsWith('\\') -or $OutputRoot.StartsWith('//')) {
    throw 'Wallpaper folder test output must be on a local filesystem.'
}
$runRoot = Join-Path $OutputRoot ('wallpaper-folder-' + [guid]::NewGuid().ToString('N'))
$sourceDirectory = Join-Path $runRoot 'source'
$wallsDirectory = Join-Path $runRoot 'walls'
New-Item -ItemType Directory -Force -Path $sourceDirectory | Out-Null
$sourcePath = Join-Path $sourceDirectory 'Picked Image.png'

# Public synthetic 2x2 PNG. The copy job never decodes it; a real file on a
# real disposable directory is what proves the copy and rescan paths.
Add-Type -AssemblyName System.Drawing
$bitmap = [Drawing.Bitmap]::new(2, 2)
try {
    $bitmap.SetPixel(0, 0, [Drawing.Color]::Magenta)
    $bitmap.SetPixel(1, 0, [Drawing.Color]::Cyan)
    $bitmap.SetPixel(0, 1, [Drawing.Color]::Yellow)
    $bitmap.SetPixel(1, 1, [Drawing.Color]::Black)
    $bitmap.Save($sourcePath, [Drawing.Imaging.ImageFormat]::Png)
} finally {
    $bitmap.Dispose()
}

$env:CAELESTIA_TEST_OUTPUT_ROOT = $runRoot
$result = Invoke-QmlFixture -QtPrefix $QtPrefix -BuildRoot $BuildRoot -Name wallpaper-folder -ShellFixture -UseQuickshell `
    -Environment @{
        CAELESTIA_WALLPAPER_DIR = $wallsDirectory.Replace('\', '/')
        CAELESTIA_WALLPAPER_SOURCE = $sourcePath.Replace('\', '/')
    } `
    -Sources @('windows/tests/WallpaperFolderTest.qml') -FixtureFile 'windows/tests/WallpaperFolderTest.qml' `
    -Marker CAELESTIA_WALLPAPER_FOLDER -MinimumAssertions 120 -TimeoutMs 90000
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

# The GUI thread must not run the copy or the folder creation itself.
$service = Get-Content -LiteralPath (Join-Path $repoRoot 'windows/shell/adapters/services/WallpaperFolderService.qml') -Raw
if ($service -notmatch '(?m)^\s*Process\s*\{') { throw 'The wallpaper folder service no longer runs filesystem work in a process.' }
if ($service -match 'CUtils\.copyFile|FsUtils\.makePath') {
    throw 'The wallpaper folder service calls a synchronous filesystem API on the GUI thread.'
}
