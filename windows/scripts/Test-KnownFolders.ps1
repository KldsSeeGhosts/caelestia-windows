[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QtPrefix,
    [Parameter(Mandatory)][string]$BuildRoot,
    [string]$RunRoot,
    # Keep the isolated run directory after a pass too.
    [switch]$Keep
)
# Checks the Windows known-folder resolution without touching the live profile:
# the plugin resolver is compared with SHGetKnownFolderPath, and the staged QML
# confirms that Paths uses it while an explicit paths.wallpaperDir still wins.
# The whole run lives in a disposable directory under the temp path.
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$BuildRoot = [IO.Path]::GetFullPath($BuildRoot)
$QtPrefix = [IO.Path]::GetFullPath($QtPrefix)
if (-not $RunRoot) { $RunRoot = [IO.Path]::GetTempPath() }
$RunRoot = [IO.Path]::GetFullPath($RunRoot)
$run = Join-Path $RunRoot ('caelestia-knownfolders-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + $PID)
$profile = Join-Path $run 'profile'
$qmlRoot = Join-Path $BuildRoot 'install\qml'
$testExe = Join-Path $BuildRoot 'caelestia\lib\knownfolders-tests.exe'
$passed = $false

try {
    New-Item -ItemType Directory -Force -Path $run, $profile | Out-Null
    foreach ($directory in @('config', 'state', 'runtime', 'cache', 'data')) {
        New-Item -ItemType Directory -Force -Path (Join-Path $profile $directory) | Out-Null
    }
    if (-not (Test-Path -LiteralPath $testExe -PathType Leaf)) {
        throw "Missing known-folder test: $testExe (run windows/scripts/Build-Prototype.ps1 -Tests first)."
    }

    $stage = & "$PSScriptRoot\Stage-ShellPrototype.ps1" -Destination (Join-Path $run 'stage') `
        -ProfileRoot $profile -Prototype shell-live
    $stage = [IO.Path]::GetFullPath($stage)
    Copy-Item -LiteralPath "$repoRoot\windows\tests\KnownFoldersTest.qml" `
        -Destination (Join-Path $stage 'knownfolders-test.qml')

    $previousPath = $env:PATH
    $env:PATH = "$QtPrefix\bin;$qmlRoot\Caelestia\lib;$env:PATH"
    Push-Location -LiteralPath $run
    try {
        & $testExe -o "$run\native-tests.txt,txt" | Out-Null
        $nativeExit = $LASTEXITCODE
    } finally {
        Pop-Location
        $env:PATH = $previousPath
    }
    $nativePassed = $nativeExit -eq 0 -and
        (Test-Path -LiteralPath "$run\native-tests.txt" -PathType Leaf) -and
        (Select-String -LiteralPath "$run\native-tests.txt" -Pattern 'Totals:.*\b0 failed\b' -Quiet)

    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = Join-Path $BuildRoot 'quickshell\qs.exe'
    $info.Arguments = '--no-color --path "' + (Join-Path $stage 'knownfolders-test.qml') + '"'
    $info.WorkingDirectory = $stage
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $environment = $info.EnvironmentVariables
    foreach ($name in @('CAELESTIA_WALLPAPER_DIR', 'CAELESTIA_WALLPAPERS_DIR')) {
        $environment.Remove($name)
    }
    $environment['PATH'] = "$QtPrefix\bin;$qmlRoot\Caelestia\lib;$env:PATH"
    $environment['QML_IMPORT_PATH'] = "$stage\imports;$qmlRoot;$QtPrefix\qml"
    $environment['QML2_IMPORT_PATH'] = "$stage\imports;$qmlRoot;$QtPrefix\qml"
    $environment['QML_DISK_CACHE_PATH'] = "$profile\cache"
    $environment['CAELESTIA_CONFIG_DIR'] = "$profile\config"
    $environment['CAELESTIA_STATE_DIR'] = "$profile\state"
    $environment['CAELESTIA_RUNTIME_DIR'] = "$profile\runtime"
    $environment['CAELESTIA_PROFILE_ROOT'] = $profile
    $environment['QS_RUNTIME_DIR'] = "$profile\runtime"
    $environment['QT_QPA_PLATFORM'] = 'offscreen'
    $process = [Diagnostics.Process]::Start($info)
    $outTask = $process.StandardOutput.ReadToEndAsync()
    $errTask = $process.StandardError.ReadToEndAsync()
    $timedOut = -not $process.WaitForExit(20000)
    if ($timedOut) { $process.Kill(); $process.WaitForExit() }
    $output = $outTask.GetAwaiter().GetResult() + "`n" + $errTask.GetAwaiter().GetResult()
    $output | Set-Content -LiteralPath "$run\qml.log" -Encoding UTF8
    $qmlPassed = -not $timedOut -and $process.ExitCode -eq 0 -and
        $output.Contains('CAELESTIA_KNOWN_FOLDERS_PASS') -and
        $output -notmatch 'CAELESTIA_KNOWN_FOLDERS_FAIL|TypeError|ReferenceError|binding loop'

    $passed = $nativePassed -and $qmlPassed
    [ordered]@{
        passed = $passed
        nativeTestsPassed = $nativePassed
        nativeTestsExitCode = $nativeExit
        nativeTestsLog = "$run\native-tests.txt"
        qmlPassed = $qmlPassed
        qmlExitCode = $process.ExitCode
        timedOut = $timedOut
        qmlLog = "$run\qml.log"
        sourceRevision = (& git -C $repoRoot rev-parse HEAD).Trim()
        backendRevision = (Get-Content "$BuildRoot\logs\build.json" -Raw | ConvertFrom-Json).backendRevision
    } | ConvertTo-Json

    if (-not $passed) {
        if (-not $nativePassed) { Get-Content -LiteralPath "$run\native-tests.txt" -ErrorAction SilentlyContinue }
        if (-not $qmlPassed) { Get-Content -LiteralPath "$run\qml.log" -ErrorAction SilentlyContinue }
        throw "Known-folder test failed (artifacts: $run)."
    }
} finally {
    if ($passed -and -not $Keep) {
        Remove-Item -LiteralPath $run -Recurse -Force -ErrorAction SilentlyContinue
    }
}
