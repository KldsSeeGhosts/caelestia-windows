[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QtPrefix,
    [Parameter(Mandatory)][string]$BuildRoot,
    [string]$RunRoot
)

# Offscreen session-drawer accessibility gate. The production graph is
# staged, then the test SessionManager replaces the real singleton so a
# dispatched action is observable without any native session call. The harness
# drives the real Content.qml with key events: activation dispatches once with no
# confirmation step, and Tab/Shift+Tab wrap inside the drawer so focus and Escape
# never leave it. It prints PASS only after every check.
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$BuildRoot = [IO.Path]::GetFullPath($BuildRoot)
if (-not $RunRoot) { $RunRoot = Join-Path $BuildRoot 'session-a11y' }
$run = Join-Path ([IO.Path]::GetFullPath($RunRoot)) (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
$profile = Join-Path $run 'profile'
$stage = & "$PSScriptRoot\Stage-ShellPrototype.ps1" -Destination (Join-Path $run 'stage') -ProfileRoot $profile -Prototype shell-live
foreach ($directory in @('config', 'state', 'runtime', 'cache', 'data')) {
    New-Item -ItemType Directory -Force (Join-Path $profile $directory) | Out-Null
}
# Keep the animated session GIF out of the run; only the buttons are under test.
# Vim keybinds start off so the plain KeyNavigation wrap is exercised first; the
# harness turns them on for its own vim row.
'{"session":{"vimKeybinds":false},"paths":{"sessionGif":""}}' | Set-Content -LiteralPath "$profile\config\shell.json" -Encoding UTF8

# Replace the staged singleton before any QML loads. The marker proves the
# production adapter cannot dispatch a session action in this run.
$stubSource = Join-Path $repoRoot 'windows\tests\fixtures\session\SessionManager.qml'
$stubTarget = Join-Path $stage 'imports\Caelestia\Services\SessionManager.qml'
if (-not (Test-Path -LiteralPath $stubTarget -PathType Leaf)) {
    throw "The staged session singleton is missing: $stubTarget"
}
Copy-Item -LiteralPath $stubSource -Destination $stubTarget -Force
if ((Get-Content -LiteralPath $stubTarget -Raw) -notmatch 'CAELESTIA_SESSION_KEYBOARD_STUB') {
    throw 'The test SessionManager stub was not staged.'
}

# Keep the staged profile routing when replacing the entry point. The test
# harness is a ShellRoot, so it runs as the shell itself.
$shellPath = Join-Path $stage 'shell.qml'
$pragmas = @([regex]::Matches([IO.File]::ReadAllText($shellPath),
    '(?m)^//@ pragma (?:DataDir|StateDir|CacheDir) [^\r\n]+') | ForEach-Object { $_.Value })
if ($pragmas.Count -ne 3) { throw 'Expected all three staged profile-directory pragmas.' }
$harness = [IO.File]::ReadAllText((Join-Path $repoRoot 'windows\tests\AccessibilitySessionTest.qml'))
[IO.File]::WriteAllText($shellPath, (($pragmas -join "`n") + "`n" + $harness), (New-Object Text.UTF8Encoding($false)))

$qmlRoot = Join-Path $BuildRoot 'install\qml'
$exe = Join-Path $BuildRoot 'quickshell\qs.exe'
if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "Missing Quickshell runtime: $exe" }
$info = New-Object Diagnostics.ProcessStartInfo
$info.FileName = $exe
$info.Arguments = '-p "' + $shellPath + '" --no-duplicate'
$info.WorkingDirectory = $stage
$info.UseShellExecute = $false
$info.CreateNoWindow = $true
$info.RedirectStandardOutput = $true
$info.RedirectStandardError = $true
$info.EnvironmentVariables['PATH'] = "$QtPrefix\bin;$qmlRoot\Caelestia\lib;$qmlRoot\M3Shapes;$env:PATH"
$info.EnvironmentVariables['QML_IMPORT_PATH'] = "$stage\imports;$qmlRoot;$QtPrefix\qml"
$info.EnvironmentVariables['QML2_IMPORT_PATH'] = "$stage\imports;$qmlRoot;$QtPrefix\qml"
$info.EnvironmentVariables['QML_DISK_CACHE_PATH'] = "$profile\cache"
$info.EnvironmentVariables['CAELESTIA_CONFIG_DIR'] = "$profile\config"
$info.EnvironmentVariables['CAELESTIA_STATE_DIR'] = "$profile\state"
$info.EnvironmentVariables['CAELESTIA_RUNTIME_DIR'] = "$profile\runtime"
$info.EnvironmentVariables['CAELESTIA_SHELL_LIVE'] = '1'
$info.EnvironmentVariables['QS_WINDOWS_TRAY_HOOK'] = '0'
$info.EnvironmentVariables['QS_WINDOWS_BLUR'] = '0'
$info.EnvironmentVariables['QT_QPA_PLATFORM'] = 'offscreen'
$info.EnvironmentVariables['QT_FORCE_STDERR_LOGGING'] = '1'
$info.EnvironmentVariables['QT_QUICK_BACKEND'] = 'software'
$info.EnvironmentVariables['QSG_RENDER_LOOP'] = 'basic'
# The stub is the only session manager in this run, but keep every native
# opt-in out even if the caller's environment carried one.
foreach ($variable in @($info.EnvironmentVariables.Keys | Where-Object { $_ -like 'CAELESTIA_WINDOWS_*' })) {
    $info.EnvironmentVariables.Remove($variable)
}
foreach ($variable in @('CAELESTIA_SHELL_SMOKE', 'CAELESTIA_SHELL_SMOKE_CI')) {
    if ($info.EnvironmentVariables.ContainsKey($variable)) { $info.EnvironmentVariables.Remove($variable) }
}

$process = [Diagnostics.Process]::Start($info)
$outTask = $process.StandardOutput.ReadToEndAsync()
$errTask = $process.StandardError.ReadToEndAsync()
$timedOut = -not $process.WaitForExit(90000)
if ($timedOut) {
    $process.Kill()
    $process.WaitForExit()
}
$stdout = $outTask.GetAwaiter().GetResult()
$stderr = $errTask.GetAwaiter().GetResult()
$stdout | Set-Content -LiteralPath "$run\stdout.log" -Encoding UTF8
$stderr | Set-Content -LiteralPath "$run\stderr.log" -Encoding UTF8
$text = "$stdout`n$stderr"
# The offscreen QPA plugin emits these two warnings itself; a real QML error
# still fails through severity lines or the explicit patterns below.
$offscreenOnly = 'QFontDatabase: Cannot find font directory|This plugin does not support setting window masks'
$diagnostics = @($text -split "`n" |
    Where-Object { $_ -match '^\s*(WARN|WARNING|ERROR|FATAL|CRITICAL)\b' } |
    Where-Object { $_ -notmatch $offscreenOnly })
$failures = @([regex]::Matches(
    $text,
    '(?im)^.*(?:CAELESTIA_SESSION_KEYBOARD_FAIL|ReferenceError|TypeError|SyntaxError|binding loop|Unable to assign|Cannot assign|Cannot read property|is not a type|is not a function|is not defined).*$'
) | ForEach-Object { $_.Value })
$checksMatch = [regex]::Match($text, 'CAELESTIA_SESSION_KEYBOARD_CHECKS (\d+)')
$checks = if ($checksMatch.Success) { [int]$checksMatch.Groups[1].Value } else { 0 }
# Four audit rows: immediate dispatch, the Tab/Shift+Tab wrap, Escape after the
# wrap, and the same wrap under vim keybinds, plus the accessible name/role and
# focus-ring rows every button must keep.
$minimumAssertions = 50
$passed = -not $timedOut -and $process.ExitCode -eq 0 -and
    $text.Contains('CAELESTIA_SESSION_KEYBOARD_PASS') -and $checks -ge $minimumAssertions -and
    $diagnostics.Count -eq 0 -and $failures.Count -eq 0
$result = [ordered]@{
    passed = $passed
    timedOut = $timedOut
    exitCode = $process.ExitCode
    checks = $checks
    assertions = $checks
    minimumAssertions = $minimumAssertions
    diagnostics = $diagnostics
    failures = $failures
    sourceRevision = (& git -C $repoRoot rev-parse HEAD).Trim()
    sourceDirty = [bool](& git -C $repoRoot status --porcelain)
    backendRevision = (Get-Content "$BuildRoot\logs\build.json" -Raw | ConvertFrom-Json).backendRevision
    executableSha256 = (Get-FileHash -LiteralPath $exe).Hash
    stubSha256 = (Get-FileHash -LiteralPath $stubTarget).Hash
    harnessSha256 = (Get-FileHash -LiteralPath $shellPath).Hash
    command = $exe
    arguments = $info.Arguments
    stage = $stage
    profile = $profile
    stdout = "$run\stdout.log"
    stderr = "$run\stderr.log"
}
$result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath "$run\result.json" -Encoding UTF8
$result | ConvertTo-Json -Depth 6
if (-not $passed) { throw "Session accessibility keyboard test failed: $run" }
