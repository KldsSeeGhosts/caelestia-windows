[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QtPrefix,
    [Parameter(Mandatory)][string]$BuildRoot,
    [string]$RunRoot
)
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$BuildRoot = [IO.Path]::GetFullPath($BuildRoot)
if (-not $RunRoot) { $RunRoot = Join-Path $repoRoot 'windows\.local\clipboard-smoke' }
$run = Join-Path ([IO.Path]::GetFullPath($RunRoot)) (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
$profile = Join-Path $run 'profile'
$stage = & "$PSScriptRoot\Stage-ShellPrototype.ps1" -Destination (Join-Path $run 'stage') -ProfileRoot $profile -Prototype shell-live
foreach ($directory in @('config', 'state', 'runtime', 'cache', 'data')) {
    New-Item -ItemType Directory -Force (Join-Path $profile $directory) | Out-Null
}
Copy-Item -LiteralPath "$repoRoot\windows\services\clipboard\ClipboardHistorySmoke.qml" -Destination "$stage\clipboard-smoke.qml"
# The temporary profile only enables the option. The fixture never opens the
# picker, so Windows clipboard history is neither read nor modified.
'{"windows":{"clipboard":{"enabled":true}}}' |
    Set-Content -LiteralPath "$profile\config\shell.json" -Encoding UTF8
$qmlRoot = Join-Path $BuildRoot 'install\qml'
# The clipboard logic test is built with the plugin and covers the decisions
# the QML smoke cannot reach: the SetHistoryItemAsContent status and the
# event-driven refresh gate.
$logicTest = Join-Path $BuildRoot 'caelestia\lib\clipboard-logic-tests.exe'
if (-not (Test-Path -LiteralPath $logicTest -PathType Leaf)) {
    throw "Missing clipboard logic test: $logicTest (run windows/scripts/Build-Prototype.ps1 first)."
}
# Sends a native QVariantList through QML property chains into the shipped
# ClipboardHistory.js; the QML smoke below only feeds it JS arrays.
$qmlTest = Join-Path $BuildRoot 'caelestia\lib\clipboard-qml-tests.exe'
if (-not (Test-Path -LiteralPath $qmlTest -PathType Leaf)) {
    throw "Missing clipboard QML boundary test: $qmlTest (run windows/scripts/Build-Prototype.ps1 first)."
}
$previousPath = $env:PATH
$env:PATH = "$QtPrefix\bin;$qmlRoot\Caelestia\lib;$env:PATH"
# Never run the clipboard logic tests with the repository, worktree, install
# prefix or the user profile as the working directory: the cache-cleanup
# regressions exercise early shutdown and must not face real files.
Push-Location -LiteralPath $run
try {
    & $logicTest -o "$run\logic-tests.txt,txt" | Out-Null
    $logicExit = $LASTEXITCODE
    & $qmlTest -o "$run\qml-tests.txt,txt" | Out-Null
    $qmlTestExit = $LASTEXITCODE
} finally {
    Pop-Location
    $env:PATH = $previousPath
}
$logicPassed = $logicExit -eq 0 -and $qmlTestExit -eq 0 -and
    (Test-Path -LiteralPath "$run\logic-tests.txt" -PathType Leaf) -and
    (Select-String -LiteralPath "$run\logic-tests.txt" -Pattern 'Totals:.*\b0 failed\b' -Quiet) -and
    (Test-Path -LiteralPath "$run\qml-tests.txt" -PathType Leaf) -and
    (Select-String -LiteralPath "$run\qml-tests.txt" -Pattern 'Totals:.*\b0 failed\b' -Quiet)
$info = New-Object Diagnostics.ProcessStartInfo
$info.FileName = Join-Path $BuildRoot 'quickshell\qs.exe'
$info.Arguments = '--no-color --log-times --path "' + "$stage\clipboard-smoke.qml" + '"'
$info.WorkingDirectory = $stage
$info.UseShellExecute = $false
$info.CreateNoWindow = $true
$info.RedirectStandardOutput = $true
$info.RedirectStandardError = $true
$info.EnvironmentVariables['PATH'] = "$QtPrefix\bin;$qmlRoot\Caelestia\lib;$env:PATH"
$info.EnvironmentVariables['QML_IMPORT_PATH'] = "$stage\imports;$qmlRoot;$QtPrefix\qml"
$info.EnvironmentVariables['CAELESTIA_CONFIG_DIR'] = "$profile\config"
$info.EnvironmentVariables['CAELESTIA_STATE_DIR'] = "$profile\state"
$info.EnvironmentVariables['CAELESTIA_RUNTIME_DIR'] = "$profile\runtime"
$info.EnvironmentVariables['QML_DISK_CACHE_PATH'] = "$profile\cache"
foreach ($variable in @($info.EnvironmentVariables.Keys | Where-Object { $_ -like 'CAELESTIA_WINDOWS_*' })) {
    $info.EnvironmentVariables.Remove($variable)
}
$info.EnvironmentVariables['CAELESTIA_SHELL_SMOKE'] = '1'
$process = [Diagnostics.Process]::Start($info)
$outTask = $process.StandardOutput.ReadToEndAsync()
$errTask = $process.StandardError.ReadToEndAsync()
$timedOut = -not $process.WaitForExit(15000)
if ($timedOut) { $process.Kill(); $process.WaitForExit() }
$stdout = $outTask.GetAwaiter().GetResult()
$stderr = $errTask.GetAwaiter().GetResult()
$stdout | Set-Content -LiteralPath "$run\stdout.log" -Encoding UTF8
$stderr | Set-Content -LiteralPath "$run\stderr.log" -Encoding UTF8
$text = "$stdout`n$stderr"
$qmlPassed = -not $timedOut -and $process.ExitCode -eq 0 -and
    $text.Contains('CAELESTIA_CLIPBOARD_SMOKE_PASS') -and
    # The native destructor's marker proves the loader-owned instance itself
    # was destroyed after the option was disabled, not just Loader.item.
    $text.Contains('CAELESTIA_CLIPBOARD_NATIVE_DESTROYED') -and
    $text -notmatch '(?m)^\S+ \S+\s+(WARN|ERROR|FATAL|CRITICAL)\b'
$passed = $logicPassed -and $qmlPassed
$result = [ordered]@{
    passed = $passed; qmlPassed = $qmlPassed
    timedOut = $timedOut; exitCode = $process.ExitCode
    logicTestsPassed = $logicPassed; logicTestsExitCode = $logicExit
    logicTests = $logicTest; logicTestsLog = "$run\logic-tests.txt"
    qmlBoundaryTests = $qmlTest; qmlBoundaryTestsExitCode = $qmlTestExit; qmlBoundaryTestsLog = "$run\qml-tests.txt"
    sourceRevision = (& git -C $repoRoot rev-parse HEAD).Trim()
    sourceDirty = [bool](& git -C $repoRoot status --porcelain)
    backendRevision = (Get-Content "$BuildRoot\logs\build.json" -Raw | ConvertFrom-Json).backendRevision
    executableSha256 = (Get-FileHash -LiteralPath $info.FileName).Hash
    qtVersion = (& "$QtPrefix\bin\qtpaths.exe" --qt-version).Trim()
    command = $info.FileName; arguments = $info.Arguments
    stage = $stage; profile = $profile; stdout = "$run\stdout.log"; stderr = "$run\stderr.log"
}
$result | ConvertTo-Json | Set-Content -LiteralPath "$run\result.json" -Encoding UTF8
$result | ConvertTo-Json
if (-not $passed) {
    throw "Clipboard test failed: $run (logic=$logicPassed, qml=$qmlPassed)"
}
