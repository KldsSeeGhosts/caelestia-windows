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
$retryDirectory = Join-Path $runRoot 'retry-source'
$wallsDirectory = Join-Path $runRoot 'walls'
# A permission-denied destination for the real marker test. Only this
# disposable staging directory is changed, and the deny is removed in finally.
$stagingName = '.caelestia-import-staging'
$deniedDirectory = Join-Path $runRoot 'denied-walls'
$deniedStaging = Join-Path $deniedDirectory $stagingName
$icacls = Join-Path $env:SystemRoot 'System32\icacls.exe'
$currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$denyApplied = $false
$env:CAELESTIA_TEST_OUTPUT_ROOT = $runRoot
try {
    New-Item -ItemType Directory -Force -Path $sourceDirectory, $retryDirectory | Out-Null
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

    # A second small image with an unrelated name, used to prove the abandoned
    # temporary cleanup in the copy script.
    $cleanupSource = Join-Path $sourceDirectory 'Cleanup Probe.png'
    Copy-Item -LiteralPath $sourcePath -Destination $cleanupSource

    # The fixture starts a real copy of this file and cancels it as soon as the
    # temporary destination appears. The file is sparse: only the first
    # fraction is read before the kill, and it is deleted with the run root.
    $largeSource = Join-Path $sourceDirectory 'Interrupted Copy.png'
    $stream = [IO.File]::Create($largeSource)
    try {
        $stream.SetLength(1073741824)
    } finally {
        $stream.Dispose()
    }

    # Same file name as the interrupted source, so a retry that still uses the
    # plain name proves no truncated final file was left behind.
    $retrySource = Join-Path $retryDirectory 'Interrupted Copy.png'
    Copy-Item -LiteralPath $sourcePath -Destination $retrySource

    # A real permission failure, so the marker comes from the job script's own
    # unwrapped exception rather than a pre-formatted fixture string. The
    # staging cleanup is best-effort, and the copy that follows reports the
    # denied write.
    New-Item -ItemType Directory -Force -Path $deniedStaging | Out-Null
    & $icacls $deniedStaging /deny "*${currentSid}:(OI)(CI)(W)" 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Could not create the permission-denied fixture folder.' }
    $denyApplied = $true

    $result = Invoke-QmlFixture -QtPrefix $QtPrefix -BuildRoot $BuildRoot -Name wallpaper-folder -ShellFixture -UseQuickshell `
        -Environment @{
            CAELESTIA_WALLPAPER_DIR = $wallsDirectory.Replace('\', '/')
            CAELESTIA_WALLPAPER_SOURCE = $sourcePath.Replace('\', '/')
            CAELESTIA_WALLPAPER_CLEANUP_SOURCE = $cleanupSource.Replace('\', '/')
            CAELESTIA_WALLPAPER_LARGE_SOURCE = $largeSource.Replace('\', '/')
            CAELESTIA_WALLPAPER_RETRY_SOURCE = $retrySource.Replace('\', '/')
            CAELESTIA_WALLPAPER_DENIED_DIR = $deniedDirectory.Replace('\', '/')
        } `
        -Sources @('windows/tests/WallpaperFolderTest.qml') -FixtureFile 'windows/tests/WallpaperFolderTest.qml' `
        -Marker CAELESTIA_WALLPAPER_FOLDER -MinimumAssertions 160 -TimeoutMs 150000
    $result | ConvertTo-Json -Depth 8
    if (-not $result.passed) {
        Get-Content -LiteralPath $result.stdout -Tail 80 -Encoding UTF8 | Write-Output
        Get-Content -LiteralPath $result.stderr -Tail 20 -Encoding UTF8 | Write-Output
        throw "Wallpaper folder fixture failed. See $($result.stderr)."
    }

    # The failure and timeout categories must reach the diagnostics, not only
    # the generic notification the user sees.
    $fixtureLog = Get-Content -LiteralPath $result.stdout -Raw
    if ($fixtureLog -notmatch 'CAELESTIA_WALLPAPER_FOLDER_DIAG kind=copy result=failed [^\r\n]*category=io') {
        throw 'A failed copy did not report its error category in the diagnostics.'
    }
    if ($fixtureLog -notmatch 'CAELESTIA_WALLPAPER_FOLDER_DIAG kind=folder result=failed [^\r\n]*category=timeout') {
        throw 'A timed-out folder job did not report its timeout in the diagnostics.'
    }
    # The permission failure is real, so its marker and inner exception type
    # prove the script unwrapped MethodInvocationException. The HRESULT is the
    # only numeric detail the log may copy from the exception.
    if ($fixtureLog -notmatch 'CAELESTIA_WALLPAPER_FOLDER_DIAG kind=copy result=failed code=2 category=access exception=UnauthorizedAccessException hresult=0x[0-9a-f]{8}') {
        throw 'A real permission failure did not report its inner exception and HRESULT.'
    }
    # core/redact.hpp treats paths as private. No diagnostic line may carry the
    # exception message, a drive path, a UNC path, or either fixture canary.
    $diagnostics = [regex]::Matches($fixtureLog, '(?m)^.*CAELESTIA_WALLPAPER_FOLDER_DIAG[^\r\n]*')
    if ($diagnostics.Count -lt 3) { throw 'The fixture did not emit the expected diagnostic lines.' }
    foreach ($match in $diagnostics) {
        $line = $match.Value
        if ($line -match 'stderr=') { throw "A diagnostic line still carries raw stderr: $line" }
        if ($line -match 'canary-drive-private|canary-unc-private') { throw "A diagnostic line carries a user path: $line" }
        if ($line -match [regex]::Escape($runRoot)) { throw "A diagnostic line carries the fixture path: $line" }
        if ($line -match '[A-Za-z]:[\\/]|\\\\') { throw "A diagnostic line carries a filesystem path: $line" }
    }

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

    # The GUI thread must not run the copy or the folder creation itself, and the
    # publish must stay a rename of a temporary the scan cannot list.
    $service = Get-Content -LiteralPath (Join-Path $repoRoot 'windows/shell/adapters/services/WallpaperFolderService.qml') -Raw
    if ($service -notmatch '(?m)^\s*Process\s*\{') { throw 'The wallpaper folder service no longer runs filesystem work in a process.' }
    if ($service -match 'CUtils\.copyFile|FsUtils\.makePath') {
        throw 'The wallpaper folder service calls a synchronous filesystem API on the GUI thread.'
    }
    if ($service -notmatch '\.caelestia-import-') { throw 'The wallpaper folder service lost its temporary copy name.' }
    if ($service -notmatch '\.caelestia-import-staging') { throw 'The wallpaper folder service lost its hidden staging folder.' }
    if ($service -notmatch 'EnumerateFiles\(\$staging') {
        throw 'The wallpaper folder cleanup no longer enumerates only its own staging folder.'
    }
    if ($service -match 'EnumerateFiles\(\$folder') {
        throw 'The wallpaper folder cleanup enumerates the user wallpapers folder.'
    }
    if ($service -notmatch 'Guid\]::TryParseExact') {
        throw 'The wallpaper folder cleanup no longer requires an exact GUID temporary name.'
    }
    if ($service -match 'stderr=') { throw 'The wallpaper folder diagnostic still logs raw stderr.' }
    if ($service -notmatch 'File\]::Move') { throw 'The wallpaper folder service no longer publishes with a rename.' }
    if ($service -notmatch 'jobTimeoutMs') { throw 'The wallpaper folder service lost its job timeout.' }
} finally {
    # Remove the temporary deny before the run root is deleted. The deny only
    # covers a disposable directory below OutputRoot.
    if ($denyApplied) {
        try {
            & $icacls $deniedDirectory /remove:d "*${currentSid}" /T 2>$null | Out-Null
        } catch {
        }
    }
    # The run root holds the large source image. It is disposable and must not
    # outlive this test.
    $resolvedRun = [IO.Path]::GetFullPath($runRoot)
    $resolvedOut = [IO.Path]::GetFullPath($OutputRoot).TrimEnd('\') + '\'
    if ($resolvedRun.StartsWith($resolvedOut, [StringComparison]::OrdinalIgnoreCase) -and
        (Split-Path -Leaf $resolvedRun) -like 'wallpaper-folder-*') {
        Remove-Item -LiteralPath $resolvedRun -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $resolvedRun) {
            Write-Warning "Could not remove the disposable wallpaper folder test root: $resolvedRun"
        }
    }
}
