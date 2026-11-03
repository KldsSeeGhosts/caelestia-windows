[CmdletBinding()]
param([Parameter(Mandatory)][string]$QtPrefix)

# Offscreen regression for #267: Wallpapers.qml is the single owner of dynamic
# palette regeneration. The fixture splices the real currentImage binding,
# applyPalette() and its image/smart-scheme/discovery handlers, so a second
# generation path, the old startup gate or a stale handler fails instead of
# passing on a copy. The mock generator records its source like path.txt does.
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$runner = Join-Path $QtPrefix 'bin\qml.exe'
if (-not (Test-Path -LiteralPath $runner -PathType Leaf)) { throw "Missing QML runner: $runner" }
$wallpapers = Get-Content -LiteralPath (Join-Path $repoRoot 'windows\shell\adapters\services\Wallpapers.qml') -Raw
$engine = Get-Content -LiteralPath (Join-Path $repoRoot 'windows\services\wallpaperengine\WallpaperEngine.qml') -Raw
$fixture = Get-Content -LiteralPath (Join-Path $repoRoot 'windows\tests\WallpaperColoursTest.qml') -Raw

function Get-UniqueMatch([string]$Text, [string]$Pattern) {
    $matches = [regex]::Matches($Text, $Pattern)
    if ($matches.Count -ne 1) { throw "Expected one production block matching: $Pattern" }
    return $matches[0].Value
}

$currentImage = Get-UniqueMatch $wallpapers '(?ms)^    readonly property string currentImage:.*?: fileCurrent\r?$'
$apply = Get-UniqueMatch $wallpapers '(?ms)^    function applyPalette\(force\): void \{.*?^    \}\r?$'
$handler = Get-UniqueMatch $wallpapers '(?m)^    onCurrentImageChanged: applyPalette\(false\)\r?$'
$smart = Get-UniqueMatch $wallpapers '(?m)^        function onSmartSchemeChanged\(\): void \{ root\.applyPalette\(true\); \}\r?$'
$snapshot = Get-UniqueMatch $wallpapers '(?m)^        function onSnapshotReadyChanged\(\): void \{ root\.applyPalette\(false\); \}\r?$'
$setWallpaper = Get-UniqueMatch $wallpapers '(?ms)^    function setWallpaper\(path\): bool \{.*?^    \}'

# One owner: the engine may not regenerate colours, the picker may not bypass
# the currentImage change, and the dedupe must use the persisted bridge source.
if ($engine -match 'matchColours|lastPaletteKey|SchemeGenerator') {
    throw 'WallpaperEngine still contains a palette generation path.'
}
if (([regex]::Matches($wallpapers, 'SchemeGenerator\.applyWallpaper\(')).Count -ne 1) {
    throw 'Wallpapers should call SchemeGenerator.applyWallpaper exactly once.'
}
if ($setWallpaper -match 'SchemeGenerator\.applyWallpaper') {
    throw 'setWallpaper still regenerates colours directly.'
}
if (-not $wallpapers.Contains('schemeStatePath') -or -not $wallpapers.Contains('scheme.json') -or
    -not $wallpapers.Contains('schemeSourcePath') -or -not $wallpapers.Contains('wallpaper/path.txt') -or
    -not $wallpapers.Contains('schemeSourceLoaded') -or -not $wallpapers.Contains('watchChanges: true')) {
    throw 'Wallpapers does not compare against the persisted scheme state.'
}
if ($wallpapers -cmatch 'Colours\.') {
    throw 'Wallpapers references Colours, which closes a singleton cycle.'
}
if ($wallpapers -match 'paletteReady|paletteImage') {
    throw 'Wallpapers kept the time-based startup gate.'
}

# Map the adapter's singletons onto fixture mocks.
$currentImage = $currentImage.Replace('WallpaperEngine', 'root.engine')
$apply = $apply.Replace('WallpaperEngine', 'root.engine')
$apply = $apply.Replace('Paths.samePath', 'root.samePath')
$apply = $apply.Replace('SchemeGenerator', 'root.schemeGenerator')
$apply = $apply.Replace('GlobalConfig.services.smartScheme', 'root.services.smartScheme')

$fixture = $fixture.Replace('    // WALLPAPER_CURRENT_IMAGE', $currentImage.TrimEnd())
$fixture = $fixture.Replace('    // WALLPAPER_APPLY', $apply.TrimEnd())
$fixture = $fixture.Replace('    // WALLPAPER_HANDLER', $handler.TrimEnd())
$fixture = $fixture.Replace('        // WALLPAPER_SMART_CHANGED', $smart.TrimEnd())
$fixture = $fixture.Replace('        // WALLPAPER_SNAPSHOT_SETTLED', $snapshot.TrimEnd())

$stage = Join-Path ([IO.Path]::GetTempPath()) ('caelestia-wallpaper-colours-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage | Out-Null
try {
    $test = Join-Path $stage 'WallpaperColoursTest.qml'
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
        throw 'Wallpaper colours fixture timed out.'
    }
    $output = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
    Write-Output $output

    # The assertion count is part of the marker: dropping a scenario must fail.
    $marker = [regex]::Match($output, 'CAELESTIA_WALLPAPER_COLOURS_PASS 17\b')
    if ($process.ExitCode -ne 0 -or -not $marker.Success -or
        $output -match 'CAELESTIA_WALLPAPER_COLOURS_FAIL|TypeError|ReferenceError|binding loop') {
        throw 'Wallpaper colours fixture failed.'
    }
    Write-Output 'PASS wallpaper colours: persisted source, async WE snapshot, smart toggle, fixed/dynamic switch and dedupe.'
} finally {
    $safeStage = [IO.Path]::GetFullPath($stage).TrimEnd('\')
    if ((Split-Path -Parent $safeStage) -ne [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') -or
        (Split-Path -Leaf $safeStage) -notlike 'caelestia-wallpaper-colours-*') {
        throw 'Unsafe wallpaper colours fixture cleanup path.'
    }
    Remove-Item -LiteralPath $safeStage -Recurse -Force
}
