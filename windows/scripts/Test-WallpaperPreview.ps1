[CmdletBinding()]
param([Parameter(Mandatory)][string]$QtPrefix)

# Offscreen regression for #261: launcher focus must not preview a cloud
# placeholder, and the desktop current path must not become that file until
# the entry is opened. The real preview functions are spliced in, so a copy
# of the guard cannot pass while production drifts.
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$runner = Join-Path $QtPrefix 'bin\qml.exe'
if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) { throw "Missing QML runner: $runner" }

function Get-UniqueMatch([string]$Text, [string]$Pattern) {
    $matches = [regex]::Matches($Text, $Pattern)
    if ($matches.Count -ne 1) { throw "Expected one production block matching: $Pattern" }
    return $matches[0].Value
}

$wallpapers = Get-Content -LiteralPath (Join-Path $repoRoot 'windows\shell\adapters\services\Wallpapers.qml') -Raw
$launcher = Get-Content -LiteralPath (Join-Path $repoRoot 'modules\launcher\WallpaperList.qml') -Raw
$tile = Get-Content -LiteralPath (Join-Path $repoRoot 'windows\shell\adapters\modules\launcher\items\WallpaperItem.qml') -Raw
$fixture = Get-Content -LiteralPath (Join-Path $repoRoot 'windows\tests\WallpaperPreviewTest.qml') -Raw

$current = Get-UniqueMatch $wallpapers '(?m)^    readonly property string current: showPreview && !externalWallpaperActive \? previewPath : currentImage\r?$'
$preview = Get-UniqueMatch $wallpapers '(?ms)^    function preview\(path\): void \{.*?^    \}\r?$'
$previewEntry = Get-UniqueMatch $wallpapers '(?ms)^    function previewEntry\(entry\): void \{.*?^    \}\r?$'
$stop = Get-UniqueMatch $wallpapers '(?m)^    function stopPreview\(\): void \{ showPreview = false; \}\r?$'
$setWallpaper = Get-UniqueMatch $wallpapers '(?ms)^    function setWallpaper\(path\): bool \{.*?^    \}'

if ($preview -notmatch 'onDisk === false' -or $previewEntry -notmatch 'onDisk === false') {
    throw 'Wallpaper preview does not refuse an unopened placeholder.'
}
if ($launcher -notmatch 'Wallpapers\.previewEntry\(item\.modelData\)' -or $launcher -match 'Wallpapers\.preview\(') {
    throw 'Launcher focus still previews the current path unconditionally.'
}
if ($tile -notmatch 'source: root\.modelData\.onDisk === false \? ""') {
    throw 'The launcher tile still decodes an unopened placeholder.'
}
if ($setWallpaper -notmatch 'root\.markOpened\(local\)' -or $setWallpaper -notmatch 'Native\.Wallpaper\.setWallpaper') {
    throw 'Opening a wallpaper no longer applies it.'
}

$preview = $preview.Replace('Paths.samePath', 'root.samePath')
$fixture = $fixture.Replace('    // WALLPAPER_CURRENT', $current.TrimEnd())
$fixture = $fixture.Replace('    // WALLPAPER_PREVIEW_ENTRY', $previewEntry.TrimEnd())
$fixture = $fixture.Replace('    // WALLPAPER_PREVIEW', $preview.TrimEnd())
$fixture = $fixture.Replace('    // WALLPAPER_STOP', $stop.TrimEnd())

$stage = Join-Path ([IO.Path]::GetTempPath()) ('caelestia-wallpaper-preview-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage | Out-Null
try {
    $test = Join-Path $stage 'WallpaperPreviewTest.qml'
    [IO.File]::WriteAllText($test, $fixture, (New-Object Text.UTF8Encoding($false)))
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $runner
    $info.Arguments = '"' + $test + '"'
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.EnvironmentVariables['QT_QPA_PLATFORM'] = 'offscreen'
    $info.EnvironmentVariables['QT_FORCE_STDERR_LOGGING'] = '1'
    $process = [Diagnostics.Process]::Start($info)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(20000)) {
        $process.Kill()
        throw 'Wallpaper preview fixture timed out.'
    }
    $output = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
    Write-Output $output
    $marker = [regex]::Match($output, 'CAELESTIA_WALLPAPER_PREVIEW_PASS 6\b')
    if ($process.ExitCode -ne 0 -or -not $marker.Success -or
        $output -match 'CAELESTIA_WALLPAPER_PREVIEW_FAIL|TypeError|ReferenceError') {
        throw 'Wallpaper preview fixture failed.'
    }
    Write-Output 'PASS wallpaper preview: placeholder focus does not reach the desktop until the entry is opened.'
} finally {
    $safeStage = [IO.Path]::GetFullPath($stage).TrimEnd('\')
    if ((Split-Path -Parent $safeStage) -ne [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') -or
        (Split-Path -Leaf $safeStage) -notlike 'caelestia-wallpaper-preview-*') {
        throw 'Unsafe wallpaper preview fixture cleanup path.'
    }
    Remove-Item -LiteralPath $safeStage -Recurse -Force
}
