[CmdletBinding()]
param([Parameter(Mandatory)][string]$QtPrefix)

# Offscreen regression for #214: the visible wallpaper source after a genuine
# Wallpaper Engine handback. Wallpaper Engine leaves IDesktopWallpaper empty,
# missing or on a system-black image, and the background Image then paints
# nothing while the window stays black. The fixture splices the real source
# selection, last-good bookkeeping, handback adoption, explicit-pick adoption,
# file verification and wallpaperChanged guard from Wallpapers.qml, so adapter
# drift fails here.
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
$engine = Get-Content -LiteralPath (Join-Path $repoRoot 'windows\services\wallpaperengine\WallpaperEngine.qml') -Raw
$fixture = Get-Content -LiteralPath (Join-Path $repoRoot 'windows\tests\WallpaperHandbackTest.qml') -Raw

$fallback = Get-UniqueMatch $wallpapers '(?m)^    readonly property string fallback: [^\r\n]+'
$lastGood = Get-UniqueMatch $wallpapers '(?m)^    property string lastGoodFile: [^\r\n]+'
$handback = Get-UniqueMatch $wallpapers '(?m)^    readonly property string handbackWallpaper: [^\r\n]+'
$currentImage = Get-UniqueMatch $wallpapers '(?ms)^    readonly property string currentImage:.*?(?=^    property bool showPreview:)'
$current = Get-UniqueMatch $wallpapers '(?m)^    readonly property string current: [^\r\n]+'
$visible = Get-UniqueMatch $wallpapers '(?ms)^    function visibleOwnSource\(\): string \{.*?^    \}'
$usable = Get-UniqueMatch $wallpapers '(?ms)^    function usableFile\(path\): bool \{.*?^    \}'
$note = Get-UniqueMatch $wallpapers '(?ms)^    function noteGoodFile\(path\): void \{.*?^    \}'
$adoptPicked = Get-UniqueMatch $wallpapers '(?ms)^    function adoptPickedFile\(path\): void \{.*?^    \}'
$adopt = Get-UniqueMatch $wallpapers '(?ms)^    function adoptHandbackSource\(\): void \{.*?^    \}'
$setWallpaper = Get-UniqueMatch $wallpapers '(?ms)^    function setWallpaper\(path\): bool \{.*?^    \}'
$fileChanged = Get-UniqueMatch $wallpapers '(?ms)^    onFileCurrentChanged: \{.*?^    \}'
$externalChanged = Get-UniqueMatch $wallpapers '(?ms)^    onExternalWallpaperActiveChanged: \{.*?^    \}'
$handbackAdopt = Get-UniqueMatch $wallpapers '(?ms)^        function onDesktopHandedBackChanged\(\): void \{.*?^        \}'
$wallpaperChanged = Get-UniqueMatch $wallpapers '(?ms)^        function onWallpaperChanged\(\): void \{.*?^        \}'
# The ownership latch is production state: splice onRunningChanged so the
# process-stop boundary fails here if a stop starts clearing the handback.
$runningChanged = Get-UniqueMatch $engine '(?ms)^    onRunningChanged: \{.*?^    \}'

# The bundled asset is the required fallback when no verified local file
# survives, and the source selection must never hand the system SPI path to the
# desktop at a handback.
if ($fallback -notmatch 'assets/wallpaper\.webp' -or
    -not (Test-Path -LiteralPath (Join-Path $repoRoot 'assets\wallpaper.webp') -PathType Leaf)) {
    throw 'Wallpapers.fallback is not the bundled assets/wallpaper.webp.'
}
if ($handback -notmatch 'usableFile\(lastGoodFile\)' -or $handback -notmatch 'fallback') {
    throw 'The handback wallpaper is not the verified last file with the bundled fallback.'
}
if ($currentImage -match 'fileCurrent') {
    throw 'currentImage still reaches the unverified native fileCurrent directly.'
}
if ($currentImage -notmatch 'visibleOwnSource\(\)' -or $currentImage -notmatch 'desktopHandedBack') {
    throw 'currentImage no longer uses the verified own-desktop source on a handback.'
}
if ($visible -notmatch 'usableFile\(fileCurrent\)' -or $visible -notmatch 'handbackWallpaper') {
    throw 'visibleOwnSource does not verify the current file before using it.'
}
if ($usable -notmatch 'Native\.FsUtils\.classify' -or $usable -notmatch '=== "file"') {
    throw 'usableFile does not require an existing local file.'
}
if ($adopt -notmatch 'lastGoodFile' -or $adopt -notmatch 'fallback' -or
    $adopt -notmatch 'fileCurrent = source') {
    throw 'adoptHandbackSource does not replace the desktop source with the verified image.'
}
# An explicit pick is the only accepted source while handed back, and it must
# stay independent of the filename: a deliberately black image is a Caelestia
# pick, not a system path to filter.
if ($adoptPicked -notmatch 'noteGoodFile\(local\)' -or $adoptPicked -notmatch 'fileCurrent = local' -or
    $adoptPicked -match '(?i)black|system|endsWith|includes\(|split\(') {
    throw 'adoptPickedFile no longer accepts every explicit pick by path.'
}
if ($setWallpaper -notmatch 'adoptPickedFile\(local\)') {
    throw 'setWallpaper no longer adopts an explicit pick while handed back.'
}
if ($handbackAdopt -notmatch 'desktopHandedBack' -or $handbackAdopt -notmatch 'stopPreview' -or
    $handbackAdopt -notmatch 'adoptHandbackSource') {
    throw 'The handback connection does not drop the preview and adopt the verified source.'
}
# While handed back, the engine-era notification is ignored outright, even for
# an existing file: the gate must run before currentWallpaper() is read.
$gateIndex = $wallpaperChanged.IndexOf('if (WallpaperEngine.desktopHandedBack)')
$readIndex = $wallpaperChanged.IndexOf('currentWallpaper()')
if ($gateIndex -lt 0 -or $readIndex -lt 0 -or $gateIndex -gt $readIndex -or
    $wallpaperChanged -notmatch '(?s)if \(WallpaperEngine\.desktopHandedBack\)\s*\r?\n\s*return;') {
    throw 'wallpaperChanged still adopts a native path while handed back.'
}
# Process-stop discovery must not clear the handback latch: only a new engine
# process resets it. The native notifier has no ordering contract with process
# discovery, so a stop that reopens adoption loses the verified source.
$runningGuard = $runningChanged.IndexOf('if (running)')
$latchClear = $runningChanged.IndexOf('desktopHandedBack = false')
$elseBranch = $runningChanged.IndexOf('} else')
if ($runningGuard -lt 0 -or $latchClear -lt 0 -or $runningGuard -gt $latchClear -or
    ($elseBranch -ge 0 -and $elseBranch -lt $latchClear)) {
    throw 'onRunningChanged does not clear the handback latch only for a new engine process.'
}

# Map the production singletons onto the fixture mocks.
function Convert-Block([string]$Block) {
    $result = $Block.Replace('WallpaperEngine', 'root.engine')
    $result = $result.Replace('Native.FsUtils', 'root.nativeHost.fsUtils')
    $result = $result.Replace('Native.Wallpaper.currentWallpaper()', 'root.nativeHost.wallpaper.currentWallpaper()')
    $result = $result.Replace('Paths.samePath', 'root.samePath')
    return $result
}

# The engine handler is indented one level into the fixture's engine object.
$runningChanged = ($runningChanged -split "\r?\n" | ForEach-Object {
    if ($_ -eq '') { $_ } else { '    ' + $_ }
}) -join "`n"

$fixture = $fixture.Replace('    // WALLPAPER_LAST_GOOD', (Convert-Block $lastGood).TrimEnd())
$fixture = $fixture.Replace('    // WALLPAPER_HANDBACK_WALLPAPER', (Convert-Block $handback).TrimEnd())
$fixture = $fixture.Replace('    // WALLPAPER_CURRENT_VISIBLE', (Convert-Block $current).TrimEnd())
$fixture = $fixture.Replace('    // WALLPAPER_CURRENT_IMAGE', (Convert-Block $currentImage).TrimEnd())
$fixture = $fixture.Replace('    // WALLPAPER_VISIBLE_OWN', (Convert-Block $visible).TrimEnd())
$fixture = $fixture.Replace('    // WALLPAPER_USABLE_FILE', (Convert-Block $usable).TrimEnd())
$fixture = $fixture.Replace('    // WALLPAPER_NOTE_GOOD', (Convert-Block $note).TrimEnd())
$fixture = $fixture.Replace('    // WALLPAPER_ADOPT_PICKED', (Convert-Block $adoptPicked).TrimEnd())
$fixture = $fixture.Replace('    // WALLPAPER_ADOPT_HANDBACK', (Convert-Block $adopt).TrimEnd())
$fixture = $fixture.Replace('    // WALLPAPER_FILE_CHANGED', (Convert-Block $fileChanged).TrimEnd())
$fixture = $fixture.Replace('    // WALLPAPER_EXTERNAL_CHANGED', (Convert-Block $externalChanged).TrimEnd())
$fixture = $fixture.Replace('        // WALLPAPER_HANDBACK_ADOPT', (Convert-Block $handbackAdopt).TrimEnd())
$fixture = $fixture.Replace('        // WALLPAPER_CHANGED', (Convert-Block $wallpaperChanged).TrimEnd())
$fixture = $fixture.Replace('        // WALLPAPER_ENGINE_RUNNING_CHANGED', $runningChanged.TrimEnd())

$stage = Join-Path ([IO.Path]::GetTempPath()) ('caelestia-wallpaper-handback-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage | Out-Null
try {
    $test = Join-Path $stage 'WallpaperHandbackTest.qml'
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
        throw 'Wallpaper handback fixture timed out.'
    }
    $output = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
    Write-Output $output

    # The assertion count is part of the marker: dropping a scenario must fail.
    $marker = [regex]::Match($output, 'CAELESTIA_WALLPAPER_HANDBACK_PASS 46\b')
    if ($process.ExitCode -ne 0 -or -not $marker.Success -or
        $output -match 'CAELESTIA_WALLPAPER_HANDBACK_FAIL|TypeError|ReferenceError|binding loop') {
        throw 'Wallpaper handback fixture failed.'
    }
    Write-Output 'PASS wallpaper handback: while handed back an empty, missing or existing engine-era native path cannot replace the verified source, process-stop discovery preserves it while a new process fails closed, an explicit pick (including black) still applies, a deleted last good file falls back to the bundled asset, and a usable change still applies on the own desktop.'
} finally {
    $safeStage = [IO.Path]::GetFullPath($stage).TrimEnd('\')
    if ((Split-Path -Parent $safeStage) -ne [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') -or
        (Split-Path -Leaf $safeStage) -notlike 'caelestia-wallpaper-handback-*') {
        throw 'Unsafe wallpaper handback fixture cleanup path.'
    }
    Remove-Item -LiteralPath $safeStage -Recurse -Force
}
