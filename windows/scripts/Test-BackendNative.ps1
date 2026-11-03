<#
.SYNOPSIS
Runs the pinned Windows backend's native regression fixtures and writes a JSON manifest.

.DESCRIPTION
The backend's Windows fixtures are a separate CMake project under
windows/deps/quickshell/src/windows/test. Build them first:

    windows\scripts\Build-Prototype.ps1 -Tests -BuildRoot C:\b-backend-tests ...

This script runs the fixtures that register with CTest from
<BuildRoot>\quickshell-tests, then runs any declared fixture that the backend
does not register, so no compiled regression is left silently unexecuted.

The test build writes <BuildRoot>\logs\backend-tests-build.json. This script
consumes that record, so a target that failed to compile or link this run is a
failure even when an executable from an older build still exists. A missing or
stale record is an error, never a pass.

Every fixture needs a trait in $fixtureTraits. A fixture without one fails the
manifest with "unclassified fixture: add a trait" and is not run. Desktop
fixtures create a fresh, non-visible desktop with CreateDesktop and start the
child process on it through STARTUPINFO.lpDesktop, so their windows never
appear on the interactive desktop. They are skipped when the session has no
interactive desktop. -IncludeDesktop opts into running them on the current
desktop instead.

The manifest records the shell HEAD, the backend gitlink, the checked-out
backend revision and windows/sources.lock.json, the Qt and clang toolchain from
the test build's CMake cache, and each fixture's result, duration, skip reason
and case-level skipped totals. Fixture totals and case-level skipped totals are
separate because a passing fixture can still skip cases. Case totals come from
fixtures this script runs directly, and the manifest records how many fixtures
were measured.

Every run removes the previous manifest and writes a fresh one with a run ID
and timestamp before any fixture starts. It rewrites the manifest on every exit
path, including errors, so a stale pass can never survive.

The script exits non-zero when the shell's backend gitlink, the checked-out
backend and sources.lock.json disagree, when the backend has local changes, or
when any fixture fails to build or fails.

.PARAMETER BuildRoot
The build root passed to Build-Prototype.ps1. Defaults to
windows\.local\build, matching Build-Prototype.ps1. The test build must be at
<BuildRoot>\quickshell-tests.

.PARAMETER TestTimeoutSeconds
Per-test timeout for CTest and for each directly run fixture. Defaults to 120.

.PARAMETER IncludeDesktop
Runs desktop fixtures on the current interactive desktop instead of an isolated
one. Off by default because their windows and hooks then reach the user's
desktop.

.EXAMPLE
windows\scripts\Test-BackendNative.ps1 -BuildRoot C:\b-backend-tests

Runs every fixture the build produced, isolates desktop fixtures, and writes
<BuildRoot>\backend-native-tests\manifest.json.

.EXAMPLE
windows\scripts\Test-BackendNative.ps1 -BuildRoot C:\b-backend-tests -TestTimeoutSeconds 300

Gives the slower fixtures five minutes each.
#>
[CmdletBinding()]
param(
    [string]$BuildRoot,
    [ValidateRange(1, 3600)][int]$TestTimeoutSeconds = 120,
    [switch]$IncludeDesktop
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Caelestia-InstallCommon.ps1')
. (Join-Path $PSScriptRoot 'Caelestia-Versions.ps1')

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
if (-not $BuildRoot) { $BuildRoot = Join-Path $repoRoot 'windows\.local\build' }
$BuildRoot = [IO.Path]::GetFullPath($BuildRoot)
$backend = Join-Path $repoRoot 'windows\deps\quickshell'
$testBuild = Join-Path $BuildRoot 'quickshell-tests'
$runRoot = Join-Path $BuildRoot ('backend-native-tests\' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss'))
$ManifestPath = [IO.Path]::GetFullPath((Join-Path $BuildRoot 'backend-native-tests\manifest.json'))
$cachePath = Join-Path $testBuild 'CMakeCache.txt'
$buildLog = Join-Path $BuildRoot 'logs\build-backend-tests.log'
$buildRecordPath = Join-Path $BuildRoot 'logs\backend-tests-build.json'
$startedWall = [DateTime]::UtcNow

# One table classifies every fixture. `desktop` means the fixture creates real
# windows, installs desktop-scoped hooks or reads interactive shell state, so it
# runs on an isolated desktop. `qpa` is the platform plugin the fixture needs
# when it is run directly instead of through CTest.
$fixtureTraits = [ordered]@{
    screen_identity             = @{ desktop = $false }
    hyprland_monitor            = @{ desktop = $false }
    panel_animation             = @{ desktop = $false }
    screenshot_jobs             = @{ desktop = $false }
    fs_utils                    = @{ desktop = $false }
    redaction                   = @{ desktop = $false }
    log_scrub                   = @{ desktop = $false }
    log_redaction_guard         = @{ desktop = $false }
    tiling_layout               = @{ desktop = $false }
    dispatcher                  = @{ desktop = $false }
    tiling_observability        = @{ desktop = $false }
    tiling_manager              = @{ desktop = $false }
    tiling_reload               = @{ desktop = $false }
    pw_audio_control            = @{ desktop = $false }
    upower_status               = @{ desktop = $false }
    bt_pairing_policy           = @{ desktop = $false }
    virtual_desktops            = @{ desktop = $false }
    hotkeys_routing             = @{ desktop = $false }
    keyboard_hook               = @{ desktop = $false }
    mpris_status                = @{ desktop = $false }
    mpris_art_cache             = @{ desktop = $false }
    transition_trace            = @{ desktop = $false }
    foreground_observer         = @{ desktop = $false }
    activation_policy           = @{ desktop = $false }
    fullscreen_app_state        = @{ desktop = $false }
    panel_topmost               = @{ desktop = $false }
    power_profiles              = @{ desktop = $false }
    brightness_route            = @{ desktop = $false }
    display_identity            = @{ desktop = $false }
    native_desktop_recovery     = @{ desktop = $false }
    pw_session_worker           = @{ desktop = $false }
    idle_request                = @{ desktop = $false }
    input_settle                = @{ desktop = $false }
    super_drag_wait             = @{ desktop = $false }
    network_wifi_route          = @{ desktop = $false }
    panel_hidden_reembed        = @{ desktop = $true; qpa = 'windows'; reason = 'creates and shows native panel windows' }
    system_surface              = @{ desktop = $true; qpa = 'offscreen'; reason = 'creates visible native windows at 0,0' }
    desktop_zorder              = @{ desktop = $true; qpa = 'offscreen'; reason = 'creates visible native windows and installs host-scoped WinEvent hooks' }
    mpris_app_identity          = @{ desktop = $true; qpa = 'offscreen'; reason = 'reads real shell app entries' }
    notification_mirror_consent = @{ desktop = $true; qpa = 'offscreen'; reason = 'creates a real message-only window' }
    keyboard_layout             = @{ desktop = $true; qpa = 'offscreen'; reason = 'creates a real hidden window' }
    native_lifetime             = @{ desktop = $true; qpa = 'offscreen'; reason = 'creates real message-only windows' }
}

New-Item -ItemType Directory -Force -Path $runRoot, (Split-Path -Parent $ManifestPath) | Out-Null
$manifest = [ordered]@{
    schemaVersion = 2
    runId = [guid]::NewGuid().ToString('N')
    generatedAtUtc = [DateTime]::UtcNow.ToString('o')
    completed = $false
    passed = $false
    error = 'the run did not finish'
    shell = $null
    backend = $null
    toolchain = $null
    buildRecord = $null
    environment = [ordered]@{
        interactiveDesktop = [Environment]::UserInteractive -and ((Get-Process -Id $PID).SessionId -ne 0)
        includeDesktop = [bool]$IncludeDesktop
        sessionId = (Get-Process -Id $PID).SessionId
        testBuildDir = $testBuild
        runDir = $runRoot
        testTimeoutSeconds = $TestTimeoutSeconds
        desktopIsolation = 'CreateDesktop plus STARTUPINFO.lpDesktop, never SwitchDesktop'
    }
    commands = [ordered]@{
        ctest = $null
        direct = @()
        isolated = @()
        buildLog = $buildLog
        testBuildRecord = $buildRecordPath
    }
    totals = [ordered]@{
        fixtures = 0; passed = 0; failed = 0; skipped = 0
        ctestRegistered = 0; ctestUnregistered = 0
        desktopIsolated = 0
        casesSkipped = 0; fixturesWithCaseTotals = 0; fixturesWithoutCaseTotals = 0
        caseTotalsNote = 'Qt Test case totals come from fixtures run directly; CTest does not capture their output on Windows.'
        wallSeconds = 0
    }
    tests = @()
}

function Write-Manifest {
    Write-CaelestiaJsonAtomic $ManifestPath $manifest
}

# Replace, never leave, the previous result. A run that dies from here on
# leaves a fresh incomplete manifest instead of an old pass.
Remove-Item -LiteralPath $ManifestPath -Force -ErrorAction SilentlyContinue
Write-Manifest

function Get-CacheValue([string]$Name) {
    $prefix = $Name + ':'
    $line = $cache | Where-Object { $_.StartsWith($prefix) } | Select-Object -First 1
    if (-not $line) { return $null }
    return ($line -split '=', 2)[1]
}

# A reconfigure can store a bare compiler name instead of its resolved path,
# so accept either and fall back to the build record for the version.
function Resolve-Executable([string]$Value) {
    if (-not $Value) { return $null }
    if (Test-Path -LiteralPath $Value -PathType Leaf) { return (Resolve-Path -LiteralPath $Value).Path }
    $command = Get-Command $Value -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return $command.Source }
    return $null
}

function Get-TestTraits([string]$Name) {
    if (-not $fixtureTraits.Contains($Name)) { return $null }
    $trait = $fixtureTraits[$Name]
    if ($trait.desktop) {
        return @{ dependsOn = @('desktop'); qpa = $trait.qpa; reason = $trait.reason }
    }
    return @{ dependsOn = @(); qpa = 'offscreen'; reason = $null }
}

function Get-Totals([string]$Text) {
    if (-not $Text) { return $null }
    $match = [regex]::Match($Text, 'Totals: (\d+) passed, (\d+) failed(?:, (\d+) skipped)?')
    if (-not $match.Success) { return $null }
    return [ordered]@{
        passed = [int]$match.Groups[1].Value
        failed = [int]$match.Groups[2].Value
        skipped = if ($match.Groups[3].Success) { [int]$match.Groups[3].Value } else { 0 }
    }
}

function Get-FirstSkipReason([string]$Text) {
    if (-not $Text) { return $null }
    $match = [regex]::Match($Text, 'SKIP\s*:\s*([^\r\n]+)')
    if ($match.Success) { return $match.Groups[1].Value.Trim() }
    return $null
}

function Test-TargetArtifact([string]$Artifact, [string]$Target) {
    if ([IO.Path]::GetFileNameWithoutExtension($Artifact) -ieq $Target) { return $true }
    return $Artifact -match ("CMakeFiles[\\/]" + [regex]::Escape($Target) + "\.dir[\\/]")
}

# Map each failed target to the compiler or linker error that stopped it.
function Get-BuildFailureOutput([string]$LogPath, [string[]]$Targets) {
    $output = @{}
    if (-not (Test-Path -LiteralPath $LogPath -PathType Leaf)) { return $output }
    $current = $null
    $collected = @{}
    foreach ($line in Get-Content -LiteralPath $LogPath) {
        if ($line -match '^FAILED:\s+\[code=\d+\]\s+(\S+)') {
            $artifact = $Matches[1]
            $current = $null
            foreach ($target in $Targets) {
                if ($artifact -match [regex]::Escape($target)) { $current = $target; break }
            }
            continue
        }
        if ($line -match '^\[\d+/\d+\]') { $current = $null; continue }
        if (-not $current) { continue }
        if ($line -match 'error LNK\d+|fatal error LNK\d+|error C\d+|fatal error C\d+|: error:') {
            if (-not $collected.ContainsKey($current)) {
                $collected[$current] = New-Object 'System.Collections.Generic.List[string]'
            }
            if (-not $collected[$current].Contains($line.Trim())) {
                $collected[$current].Add($line.Trim())
            }
        }
    }
    foreach ($target in $collected.Keys) { $output[$target] = ($collected[$target] -join "`n") }
    return $output
}

# A desktop fixture gets its own invisible desktop. The child process starts on
# it through STARTUPINFO.lpDesktop, and the desktop is closed when the child
# exits. SwitchDesktop is never called, so the user's desktop is unchanged.
if (-not ('CaelestiaIsolatedDesktop' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class CaelestiaIsolatedDesktop {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct STARTUPINFO {
        public int cb;
        public string lpReserved;
        public string lpDesktop;
        public string lpTitle;
        public int dwX;
        public int dwY;
        public int dwXSize;
        public int dwYSize;
        public int dwXCountChars;
        public int dwYCountChars;
        public int dwFillAttribute;
        public int dwFlags;
        public short wShowWindow;
        public short cbReserved2;
        public IntPtr lpReserved2;
        public IntPtr hStdInput;
        public IntPtr hStdOutput;
        public IntPtr hStdError;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct PROCESS_INFORMATION {
        public IntPtr hProcess;
        public IntPtr hThread;
        public int dwProcessId;
        public int dwThreadId;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr CreateDesktopW(string lpszDesktop, string lpszDevice, IntPtr pDevmode, int dwFlags, int dwDesiredAccess, IntPtr lpsa);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool CloseDesktop(IntPtr hDesktop);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool CreateProcessW(string lpApplicationName, string lpCommandLine, IntPtr lpProcessAttributes, IntPtr lpThreadAttributes, bool bInheritHandles, int dwCreationFlags, IntPtr lpEnvironment, string lpCurrentDirectory, ref STARTUPINFO lpStartupInfo, out PROCESS_INFORMATION lpProcessInformation);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern int WaitForSingleObject(IntPtr hHandle, int dwMilliseconds);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetExitCodeProcess(IntPtr hProcess, out int lpExitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool TerminateProcess(IntPtr hProcess, int uExitCode);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool CloseHandle(IntPtr hObject);

    // PowerShell can marshal a zero handle back from a direct call to this
    // function, so keep the call and the error read in C#.
    public static IntPtr CreateDesktopForTest(string name, out int error) {
        var handle = CreateDesktopW(name, null, IntPtr.Zero, 0, 0x000F01FF, IntPtr.Zero);
        error = Marshal.GetLastWin32Error();
        return handle;
    }
}
'@
}

function Invoke-IsolatedFixture([string]$Executable, [string]$Name, [string]$Log) {
    $started = [DateTime]::UtcNow
    $desktopName = 'caelestia-' + $manifest.runId.Substring(0, 8) + '-' + $Name
    [int]$createError = 0
    $desktop = [CaelestiaIsolatedDesktop]::CreateDesktopForTest($desktopName, [ref]$createError)
    if ($desktop -eq [IntPtr]::Zero) {
        return [pscustomobject]@{
            Started = $false; IsolationFailed = $true; ExitCode = $null; TimedOut = $false
            Duration = [Math]::Round(([DateTime]::UtcNow - $started).TotalSeconds, 3)
            Log = $Log; Desktop = $null; Error = "CreateDesktop failed with Win32 error $createError"
        }
    }
    $process = [IntPtr]::Zero
    try {
        $info = [CaelestiaIsolatedDesktop+STARTUPINFO]::new()
        $info.cb = [Runtime.InteropServices.Marshal]::SizeOf($info)
        $info.lpDesktop = $desktopName
        $processInfo = [CaelestiaIsolatedDesktop+PROCESS_INFORMATION]::new()
        $commandLine = '"' + $Executable + '" -o "' + $Log + '",txt'
        $created = [CaelestiaIsolatedDesktop]::CreateProcessW($Executable, $commandLine,
            [IntPtr]::Zero, [IntPtr]::Zero, $false, 0, [IntPtr]::Zero, $runRoot, [ref]$info, [ref]$processInfo)
        if (-not $created) {
            $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            return [pscustomobject]@{
                Started = $false; IsolationFailed = $false; ExitCode = $null; TimedOut = $false
                Duration = [Math]::Round(([DateTime]::UtcNow - $started).TotalSeconds, 3)
                Log = $Log; Desktop = $desktopName; Error = "CreateProcess failed with Win32 error $errorCode"
            }
        }
        $process = $processInfo.hProcess
        [CaelestiaIsolatedDesktop]::CloseHandle($processInfo.hThread) | Out-Null
        $timedOut = [CaelestiaIsolatedDesktop]::WaitForSingleObject($process, $TestTimeoutSeconds * 1000) -eq 0x102
        if ($timedOut) {
            & taskkill.exe /PID $processInfo.dwProcessId /T /F 2>&1 | Out-Null
            if ([CaelestiaIsolatedDesktop]::WaitForSingleObject($process, 5000) -eq 0x102) {
                [CaelestiaIsolatedDesktop]::TerminateProcess($process, 1) | Out-Null
                [CaelestiaIsolatedDesktop]::WaitForSingleObject($process, 5000) | Out-Null
            }
        }
        $exitCode = 0
        if (-not [CaelestiaIsolatedDesktop]::GetExitCodeProcess($process, [ref]$exitCode)) { $exitCode = -1 }
        return [pscustomobject]@{
            Started = $true; IsolationFailed = $false; ExitCode = $exitCode; TimedOut = $timedOut
            Duration = [Math]::Round(([DateTime]::UtcNow - $started).TotalSeconds, 3)
            Log = $Log; Desktop = $desktopName; Error = $null
        }
    } finally {
        if ($process -ne [IntPtr]::Zero) { [CaelestiaIsolatedDesktop]::CloseHandle($process) | Out-Null }
        [CaelestiaIsolatedDesktop]::CloseDesktop($desktop) | Out-Null
    }
}

$plans = New-Object 'System.Collections.Generic.List[object]'
$ctestExit = $null
$revisionMatches = $false
$backendDirty = $true
$runError = $null

function Get-TargetBuildFailure([string]$Target) {
    if (-not $buildRecord.configureSucceeded) { return 'The test build did not configure this run.' }
    if ($recordTargets -notcontains $Target) { return "The test build record does not include $Target." }
    if (@($failedArtifacts | Where-Object { Test-TargetArtifact $_ $Target }).Count -gt 0) {
        return "Fixture $Target did not compile or link."
    }
    if (-not (Test-Path -LiteralPath (Join-Path $testBuild "$Target.exe") -PathType Leaf)) {
        return "The test build produced no $Target.exe."
    }
    if ($unknownBuildFailure) { return 'The test build did not complete and recorded no failed target.' }
    return $null
}

try {
    if (-not (Test-Path -LiteralPath $cachePath -PathType Leaf)) {
        throw "The backend test build is missing: $testBuild. Run windows\scripts\Build-Prototype.ps1 -Tests -BuildRoot $BuildRoot first."
    }
    $cache = Get-Content -LiteralPath $cachePath
    $qt6Dir = Get-CacheValue 'Qt6_DIR'
    $qtPrefix = if ($qt6Dir) { ($qt6Dir -replace '/', '\') -replace '\\lib\\cmake\\Qt6$', '' } else { $null }
    $qtPaths = if ($qtPrefix) { Resolve-Executable (Join-Path $qtPrefix 'bin\qtpaths.exe') } else { $null }
    $compilerCommand = Resolve-Executable (Get-CacheValue 'CMAKE_CXX_COMPILER')
    $cmakeCommand = Resolve-Executable (Get-CacheValue 'CMAKE_COMMAND')
    $ninjaCommand = Resolve-Executable (Get-CacheValue 'CMAKE_MAKE_PROGRAM')
    foreach ($required in @($qtPaths, $cmakeCommand, $ninjaCommand)) {
        if (-not $required) { throw "The test build cache does not name a usable Qt, CMake or Ninja toolchain." }
    }
    $cmakeBin = Split-Path -Parent $cmakeCommand
    $ctestCommand = Join-Path $cmakeBin 'ctest.exe'
    if (-not (Test-Path -LiteralPath $ctestCommand -PathType Leaf)) {
        throw "ctest.exe is missing beside $cmakeCommand."
    }
    # The fixtures need the Qt runtime. CTest ships beside the cmake that
    # configured the test build.
    $env:PATH = "$qtPrefix\bin;$cmakeBin;$env:PATH"

    $buildRecord = $null
    if (Test-Path -LiteralPath $buildRecordPath -PathType Leaf) {
        $buildRecord = Get-Content -LiteralPath $buildRecordPath -Raw | ConvertFrom-Json
    }
    $qtVersion = (& $qtPaths --qt-version).Trim()
    $clangVersion = if ($compilerCommand) { (@(& $compilerCommand --version))[0] }
        elseif ($buildRecord -and $buildRecord.compiler) { $buildRecord.compiler }
        else { 'clang version not recorded' }
    $cmakeVersion = (@(& $cmakeCommand --version))[0]
    $ninjaVersion = (@(& $ninjaCommand --version))[0]

    $shellHead = (& git -C $repoRoot rev-parse HEAD).Trim()
    $shellDirty = [bool]@(& git -C $repoRoot status --porcelain)
    $lock = Get-Content -LiteralPath (Join-Path $repoRoot 'windows\sources.lock.json') -Raw | ConvertFrom-Json
    $gitlinkLine = & git -C $repoRoot ls-tree HEAD -- $lock.quickshell.path
    if ($LASTEXITCODE -ne 0 -or -not $gitlinkLine) { throw "Could not read the backend gitlink from $repoRoot." }
    $gitlink = ($gitlinkLine -split '\s+')[2]
    $backendHead = (& git -C $backend rev-parse HEAD).Trim()
    $backendDirty = [bool]@(& git -C $backend status --porcelain)
    $lockRevision = $lock.quickshell.revision
    $revisionMatches = ($gitlink -eq $backendHead) -and ($gitlink -eq $lockRevision)
    $manifest.shell = [ordered]@{ head = $shellHead; dirty = $shellDirty }
    $manifest.backend = [ordered]@{
        gitlink = $gitlink; checkedOut = $backendHead; sourcesLock = $lockRevision
        matches = $revisionMatches; dirty = $backendDirty
    }
    $manifest.toolchain = [ordered]@{
        qt = $qtVersion; qtPrefix = $qtPrefix; clang = $clangVersion; cmake = $cmakeVersion
        ninja = $ninjaVersion; windows = [Environment]::OSVersion.VersionString; source = $cachePath
    }
    if (-not $revisionMatches) {
        throw "Backend revision mismatch: gitlink $gitlink, checked-out $backendHead, sources.lock $lockRevision."
    }
    if ($backendDirty) {
        throw "The backend has local changes at $backend. The fixtures would not test the pinned revision."
    }
    $interactiveDesktop = $manifest.environment.interactiveDesktop

    # CTest is the registration of record. Parse its listing to pair each test
    # name with its executable, then run every declared fixture the backend did
    # not register directly.
    $listLog = Join-Path $runRoot 'ctest-list.log'
    $ErrorActionPreference = 'Continue'
    & $ctestCommand --test-dir $testBuild -N -V *>&1 | ForEach-Object { "$_" } | Set-Content -LiteralPath $listLog -Encoding UTF8
    $listExit = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($listExit -ne 0) { throw "ctest -N failed. See $listLog." }

    $commands = @{}
    $names = @{}
    foreach ($line in Get-Content -LiteralPath $listLog) {
        if ($line -match '^\s*(\d+): Test command:\s*(.*)$') {
            $commands[[int]$Matches[1]] = $Matches[2].Trim()
            continue
        }
        if ($line -match '^\s*Test\s+#(\d+):\s+(.+)$') {
            $names[[int]$Matches[1]] = $Matches[2].Trim()
        }
    }
    $registered = New-Object 'System.Collections.Generic.List[object]'
    foreach ($id in ($names.Keys | Sort-Object)) {
        $executable = $null
        $command = $commands[$id]
        if ($command) {
            if ($command -match '^"([^"]+)"') { $executable = $Matches[1] }
            else { $executable = ($command -split '\s+')[0] }
        }
        $registered.Add([pscustomobject]@{ name = $names[$id]; executable = $executable })
    }
    if ($registered.Count -eq 0) { throw "CTest registered no tests in $testBuild. See $listLog." }

    # The test build record is the only evidence that a target was built by the
    # current build. An old executable next to a failed target is not a pass.
    $testCmake = Join-Path $backend 'src\windows\test\CMakeLists.txt'
    $declaredTargets = @([regex]::Matches((Get-Content -LiteralPath $testCmake -Raw), 'qs_add_test_executable\((\w+)') |
        ForEach-Object { $_.Groups[1].Value })
    if ($declaredTargets.Count -eq 0) { throw "No test targets were declared in $testCmake." }
    if (-not $buildRecord) {
        throw "The backend test build record is missing: $buildRecordPath. Run windows\scripts\Build-Prototype.ps1 -Tests -BuildRoot $BuildRoot."
    }
    $manifest.buildRecord = [ordered]@{
        path = $buildRecordPath
        generatedAtUtc = $buildRecord.generatedAtUtc
        backendRevision = $buildRecord.backendRevision
        configureSucceeded = [bool]$buildRecord.configureSucceeded
        buildSucceeded = [bool]$buildRecord.buildSucceeded
        failedArtifacts = @($buildRecord.failedArtifacts | Where-Object { $_ })
        targets = @($buildRecord.targets | Where-Object { $_ })
    }
    if ($buildRecord.backendRevision -ne $backendHead) {
        throw "The test build record is for backend $($buildRecord.backendRevision), not the checked-out $backendHead. Rerun windows\scripts\Build-Prototype.ps1 -Tests."
    }
    $recordTargets = @($buildRecord.targets | Where-Object { $_ })
    $failedArtifacts = @($buildRecord.failedArtifacts | Where-Object { $_ })
    $unknownBuildFailure = (-not $buildRecord.buildSucceeded) -and ($failedArtifacts.Count -eq 0)
    $buildErrors = Get-BuildFailureOutput $buildLog $declaredTargets

    # Build one plan per declared target. A plan owns the fixture's
    # classification, build result and run mode, so the manifest cannot report a
    # different story.
    $registeredByTarget = @{}
    foreach ($entry in $registered) {
        $target = if ($entry.executable) { [IO.Path]::GetFileNameWithoutExtension($entry.executable) } else { $entry.name + '_test' }
        if ($declaredTargets -contains $target) { $registeredByTarget[$target] = $entry }
    }
    foreach ($target in $declaredTargets) {
        $name = $target -replace '_test$', ''
        $entry = $registeredByTarget[$target]
        $traits = Get-TestTraits $name
        $plan = [pscustomobject]@{
            name = $name
            target = $target
            executable = Join-Path $testBuild "$target.exe"
            registered = [bool]$entry
            dependsOn = @()
            qpa = 'offscreen'
            mode = 'ctest'
            result = $null
            duration = 0.0
            skipReason = $null
            failure = $null
            buildFailure = $null
            skippedCases = $null
            runBy = 'none'
            isolation = $null
            log = $null
        }
        if ($traits) {
            $plan.dependsOn = @($traits.dependsOn)
            $plan.qpa = $traits.qpa
        }
        $buildFailure = Get-TargetBuildFailure $target
        if (-not $traits) {
            $plan.mode = 'fail'
            $plan.result = 'failed'
            $plan.failure = "unclassified fixture: add a trait for '$name' in windows\scripts\Test-BackendNative.ps1"
        } elseif ($buildFailure) {
            $errorText = $buildErrors[$target]
            $plan.mode = 'fail'
            $plan.result = 'failed'
            $plan.failure = if ($errorText) { "$buildFailure`n$errorText" } else { "$buildFailure See $buildLog." }
            $plan.buildFailure = [ordered]@{ target = $target; output = $errorText; log = $buildLog }
        } elseif ($plan.dependsOn -contains 'desktop') {
            if (-not $interactiveDesktop) {
                $plan.mode = 'skip'
                $plan.result = 'skipped'
                $plan.skipReason = "no interactive desktop session; $($traits.reason)"
            } elseif ($IncludeDesktop) {
                $plan.mode = 'direct'
            } else {
                $plan.mode = 'isolated'
            }
        } elseif (-not $plan.registered) {
            $plan.mode = 'direct'
        }
        $plans.Add($plan)
    }
    foreach ($entry in $registered) {
        $target = if ($entry.executable) { [IO.Path]::GetFileNameWithoutExtension($entry.executable) } else { $entry.name + '_test' }
        if ($declaredTargets -contains $target) { continue }
        $plans.Add([pscustomobject]@{
            name = $entry.name; target = $target; executable = $entry.executable; registered = $true
            dependsOn = @(); qpa = 'offscreen'; mode = 'fail'; result = 'failed'; duration = 0.0
            skipReason = $null; buildFailure = $null; skippedCases = $null; runBy = 'none'; isolation = $null; log = $null
            failure = "unclassified fixture: CTest registered '$($entry.name)' with no declared target"
        })
    }

    $excluded = @($plans | Where-Object { $_.registered -and $_.mode -ne 'ctest' } | ForEach-Object { $_.name })
    $ctestPlans = @($plans | Where-Object { $_.mode -eq 'ctest' })
    if ($ctestPlans.Count -gt 0) {
        $junitPath = Join-Path $runRoot 'ctest-junit.xml'
        $ctestLog = Join-Path $runRoot 'ctest.log'
        $ctestArguments = @('--test-dir', $testBuild, '--output-on-failure', '--timeout', "$TestTimeoutSeconds",
            '--output-junit', $junitPath, '--no-tests=error')
        if ($excluded.Count -gt 0) {
            $pattern = '^(' + (($excluded | ForEach-Object { [regex]::Escape($_) }) -join '|') + ')$'
            $ctestArguments += @('--exclude-regex', $pattern)
        }
        $manifest.commands.ctest = 'ctest ' + ($ctestArguments -join ' ')
        # Run from the disposable run directory. CTest still executes each
        # fixture in its own build directory, never the repository or a home
        # directory.
        Push-Location -LiteralPath $runRoot
        try {
            $ErrorActionPreference = 'Continue'
            & $ctestCommand @ctestArguments *>&1 | ForEach-Object { "$_" } | Tee-Object -FilePath $ctestLog
            $ctestExit = $LASTEXITCODE
            $ErrorActionPreference = 'Stop'
        } finally {
            Pop-Location
        }
        if (-not (Test-Path -LiteralPath $junitPath -PathType Leaf)) {
            throw "CTest produced no JUnit result at $junitPath. See $ctestLog."
        }
        [xml]$junit = Get-Content -LiteralPath $junitPath -Raw
        $cases = @{}
        foreach ($case in $junit.SelectNodes('//testcase')) { $cases[$case.GetAttribute('name')] = $case }
        foreach ($plan in $ctestPlans) {
            $case = $cases[$plan.name]
            if (-not $case) {
                $plan.mode = 'fail'
                $plan.result = 'failed'
                $plan.failure = "CTest produced no result for this test. See $ctestLog."
                continue
            }
            $plan.duration = [double]$case.GetAttribute('time')
            $totals = $null
            $systemOut = $case.SelectSingleNode('system-out')
            if ($systemOut) { $totals = Get-Totals $systemOut.InnerText }
            $failureNode = $case.SelectSingleNode('failure')
            $skippedNode = $case.SelectSingleNode('skipped')
            if ($failureNode) {
                $plan.result = 'failed'
                $plan.failure = $failureNode.InnerText.Trim()
                if ($totals) { $plan.skippedCases = $totals.skipped }
            } elseif ($skippedNode) {
                $plan.result = 'skipped'
                $plan.skipReason = $skippedNode.GetAttribute('message')
                if (-not $plan.skipReason) { $plan.skipReason = 'CTest reported the test as skipped.' }
                if ($totals) { $plan.skippedCases = $totals.skipped }
            } elseif ($totals -and $totals.passed -eq 0 -and $totals.failed -eq 0 -and $totals.skipped -gt 0) {
                $plan.result = 'skipped'
                $plan.skipReason = Get-FirstSkipReason $systemOut.InnerText
                if (-not $plan.skipReason) { $plan.skipReason = "Qt Test reported $($totals.skipped) skipped cases and no passes." }
                $plan.skippedCases = $totals.skipped
            } else {
                $plan.result = 'passed'
                if ($totals) { $plan.skippedCases = $totals.skipped }
            }
            $plan.runBy = 'ctest'
            $plan.mode = 'done'
        }
    }

    # Direct fixtures write their Qt Test log through -o. The bounded helper
    # starts the headless ones with a hard time limit. The isolated path needs
    # its own launcher only because .NET cannot set STARTUPINFO.lpDesktop.
    foreach ($plan in $plans) {
        if ($plan.mode -notin @('direct', 'isolated')) { continue }
        $plan.log = Join-Path $runRoot "$($plan.name).qt.txt"
        $previousQpa = $env:QT_QPA_PLATFORM
        $env:QT_QPA_PLATFORM = $plan.qpa
        $run = $null
        $timedOut = $false
        try {
            if ($plan.mode -eq 'isolated') {
                $run = Invoke-IsolatedFixture $plan.executable $plan.name $plan.log
                if (-not $run.Started) {
                    if ($run.IsolationFailed) {
                        $plan.mode = 'skip'
                        $plan.result = 'skipped'
                        $plan.skipReason = "desktop fixture; run with -IncludeDesktop ($($run.Error))"
                    } else {
                        $plan.mode = 'fail'
                        $plan.result = 'failed'
                        $plan.failure = "Could not start on an isolated desktop. $($run.Error)."
                    }
                    $plan.runBy = 'none'
                    continue
                }
                $manifest.commands.isolated += "'$($run.Desktop)' $($plan.executable) -o $($plan.log),txt"
                $plan.isolation = 'isolated-desktop'
                $plan.runBy = 'isolated-desktop'
            } else {
                $started = [DateTime]::UtcNow
                $run = Invoke-CaelestiaBounded -File $plan.executable -Arguments ('-o "' + $plan.log + '",txt') `
                    -TimeoutSeconds $TestTimeoutSeconds -WorkingDirectory $runRoot
                $plan.duration = ([DateTime]::UtcNow - $started).TotalSeconds
                $manifest.commands.direct += "$($plan.executable) -o $($plan.log),txt"
                $plan.runBy = 'direct'
                $plan.isolation = if ($plan.dependsOn -contains 'desktop') { 'interactive-desktop' } else { $null }
            }
        } catch {
            $plan.mode = 'fail'
            $plan.result = 'failed'
            $plan.failure = "Fixture runner error: $_"
            continue
        } finally {
            if ($null -eq $previousQpa) { Remove-Item Env:\QT_QPA_PLATFORM -ErrorAction SilentlyContinue }
            else { $env:QT_QPA_PLATFORM = $previousQpa }
        }
        if ($null -eq $run) {
            $plan.result = 'failed'
            $plan.failure = "Did not start or exceeded $TestTimeoutSeconds seconds. See $($plan.log)."
            $plan.mode = 'done'
            continue
        }
        if ($plan.mode -eq 'isolated') { $plan.duration = $run.Duration; $timedOut = [bool]$run.TimedOut }
        $text = ''
        if (Test-Path -LiteralPath $plan.log -PathType Leaf) { $text = [string](Get-Content -LiteralPath $plan.log -Raw) }
        $totals = Get-Totals $text
        if ($timedOut) {
            $plan.result = 'failed'
            $plan.failure = "Timed out after $TestTimeoutSeconds seconds. See $($plan.log)."
        } elseif ($run.ExitCode -ne 0) {
            $plan.result = 'failed'
            $plan.failure = "Exited with code $($run.ExitCode). See $($plan.log)."
        } elseif (-not $totals) {
            $plan.result = 'failed'
            $plan.failure = "Qt Test printed no Totals line. See $($plan.log)."
        } elseif ($totals.failed -gt 0) {
            $plan.result = 'failed'
            $plan.failure = "Qt Test reported $($totals.failed) failed cases. See $($plan.log)."
        } elseif ($totals.passed -eq 0 -and $totals.skipped -gt 0) {
            $plan.result = 'skipped'
            $plan.skipReason = Get-FirstSkipReason $text
            if (-not $plan.skipReason) { $plan.skipReason = "Qt Test reported $($totals.skipped) skipped cases and no passes." }
            $plan.skippedCases = $totals.skipped
        } else {
            $plan.result = 'passed'
            $plan.skippedCases = $totals.skipped
        }
        $plan.mode = 'done'
    }
} catch {
    $runError = "$_"
}
$manifest.error = $runError

$manifest.tests = @($plans | ForEach-Object {
    [ordered]@{
        name = $_.name
        result = $(if ($_.result) { $_.result } else { 'failed' })
        durationSeconds = [Math]::Round([double]$_.duration, 3)
        skipReason = $_.skipReason
        skippedCases = $_.skippedCases
        ctestRegistered = [bool]$_.registered
        dependsOn = @($_.dependsOn)
        runBy = $_.runBy
        isolation = $_.isolation
        command = $_.executable
        failure = $(if ($_.failure) { $_.failure }
            elseif ($_.result -eq 'failed') {
                if ($manifest.error) { "did not run: $($manifest.error)" } else { 'the run ended before this fixture ran' }
            } else { $null })
        buildFailure = $_.buildFailure
    }
})
$manifest.totals.fixtures = $manifest.tests.Count
$manifest.totals.passed = @($manifest.tests | Where-Object { $_.result -eq 'passed' }).Count
$manifest.totals.failed = @($manifest.tests | Where-Object { $_.result -eq 'failed' }).Count
$manifest.totals.skipped = @($manifest.tests | Where-Object { $_.result -eq 'skipped' }).Count
$manifest.totals.ctestRegistered = @($manifest.tests | Where-Object { $_.ctestRegistered }).Count
$manifest.totals.ctestUnregistered = @($manifest.tests | Where-Object { -not $_.ctestRegistered }).Count
$manifest.totals.desktopIsolated = @($manifest.tests | Where-Object { $_.isolation -eq 'isolated-desktop' }).Count
$measured = @($manifest.tests | Where-Object { $null -ne $_.skippedCases })
$manifest.totals.fixturesWithCaseTotals = $measured.Count
$manifest.totals.fixturesWithoutCaseTotals = $manifest.totals.fixtures - $measured.Count
# CTest cannot capture these fixtures' Qt Test output on Windows, so case
# totals come only from fixtures this script runs directly. Recording how many
# fixtures were measured stops a partial count from reading as a full total.
$manifest.totals.casesSkipped = (@($measured | ForEach-Object { [int]$_.skippedCases } | Measure-Object -Sum).Sum)
if ($null -eq $manifest.totals.casesSkipped) { $manifest.totals.casesSkipped = 0 }
$manifest.totals.wallSeconds = [Math]::Round(([DateTime]::UtcNow - $startedWall).TotalSeconds, 3)

$manifest.completed = $true
$manifest.passed = (-not $manifest.error) -and ($manifest.totals.failed -eq 0) -and
    (($null -eq $ctestExit) -or ($ctestExit -eq 0)) -and $revisionMatches -and (-not $backendDirty)
Write-Manifest

$summary = "$($manifest.totals.passed) passed, $($manifest.totals.failed) failed, $($manifest.totals.skipped) skipped, " +
    "$($manifest.totals.fixtures) fixtures ($($manifest.totals.ctestRegistered) CTest, $($manifest.totals.ctestUnregistered) direct), " +
    "$($manifest.totals.casesSkipped) skipped cases measured in $($manifest.totals.fixturesWithCaseTotals) fixtures " +
    "($($manifest.totals.fixturesWithoutCaseTotals) unmeasured), " +
    "$($manifest.totals.desktopIsolated) isolated desktop runs. Manifest: $ManifestPath"
if (-not $manifest.passed) {
    foreach ($test in $manifest.tests) {
        if ($test.result -eq 'failed') { Write-Output "FAIL $($test.name): $($test.failure)" }
    }
    if ($manifest.error) { Write-Output "ERROR $($manifest.error)" }
    throw "Backend native tests failed: $summary"
}
Write-Output "PASS backend native tests: $summary"
