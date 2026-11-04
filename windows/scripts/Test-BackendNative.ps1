<#
.SYNOPSIS
Runs the pinned Windows backend's native regression fixtures and writes a JSON manifest.

.DESCRIPTION
Runs every fixture built by `Build-Prototype.ps1 -Tests` in <BuildRoot>\quickshell-tests.
Fixtures registered with CTest run through CTest, the rest run directly. Fixtures
that need a desktop run on a hidden desktop created for each one, and are skipped
when the session has no interactive desktop. A fixture without a trait entry in
$fixtureTraits fails as unclassified and is not run. A trait with helper = $true
marks an executable that a fixture launches; it is never run as a test.

A fixture that did not build in this run fails and is not run, even when an older
executable exists. Any failed or unfinished test build fails the gate, and a build
failure that cannot be traced to a fixture fails every fixture. A desktop fixture
that cannot be stopped, or whose desktop cannot be closed, fails the gate.

The backend gitlink, the checked-out backend and windows/sources.lock.json must agree,
and the backend must have no local changes.

Output: <BuildRoot>\backend-native-tests\manifest.json. The previous manifest is
removed before anything runs and the new one is written on every exit path. It
records the shell and backend revisions, the Qt and clang toolchain, the build
record, gate failures, and each fixture's result, duration and skip reason.
totals.casesSkipped sums the skipped cases of the fixtures whose Qt Test output had
a Totals line, fixturesWithCaseTotals counts those fixtures and
fixturesWithoutCaseTotals counts the rest.

Exit code: 0 when the manifest reports passed, otherwise nonzero.

.PARAMETER BuildRoot
The build root passed to Build-Prototype.ps1. Defaults to windows\.local\build.

.PARAMETER TestTimeoutSeconds
Per-fixture timeout for CTest and for each directly run fixture. Defaults to 120.

.PARAMETER IncludeDesktop
Runs desktop fixtures on the current interactive desktop instead of a hidden one.

.EXAMPLE
windows\scripts\Test-BackendNative.ps1 -BuildRoot C:\b-backend-tests
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

$fixtureTraits = [ordered]@{
    screen_identity             = @{ needsDesktop = $false }
    hyprland_monitor            = @{ needsDesktop = $false }
    panel_animation             = @{ needsDesktop = $false }
    screenshot_jobs             = @{ needsDesktop = $false }
    fs_utils                    = @{ needsDesktop = $false }
    redaction                   = @{ needsDesktop = $false }
    log_scrub                   = @{ needsDesktop = $false }
    log_redaction_guard         = @{ needsDesktop = $false }
    tiling_layout               = @{ needsDesktop = $false }
    dispatcher                  = @{ needsDesktop = $false }
    tiling_observability        = @{ needsDesktop = $false }
    tiling_manager              = @{ needsDesktop = $false }
    tiling_reload               = @{ needsDesktop = $false }
    pw_audio_control            = @{ needsDesktop = $false }
    upower_status               = @{ needsDesktop = $false }
    bt_pairing_policy           = @{ needsDesktop = $false }
    virtual_desktops            = @{ needsDesktop = $false }
    hotkeys_routing             = @{ needsDesktop = $false }
    keyboard_hook               = @{ needsDesktop = $false }
    mpris_status                = @{ needsDesktop = $false }
    mpris_art_cache             = @{ needsDesktop = $false }
    transition_trace            = @{ needsDesktop = $false }
    foreground_observer         = @{ needsDesktop = $false }
    activation_policy           = @{ needsDesktop = $false }
    fullscreen_app_state        = @{ needsDesktop = $false }
    panel_topmost               = @{ needsDesktop = $false }
    power_profiles              = @{ needsDesktop = $false }
    brightness_route            = @{ needsDesktop = $false }
    display_identity            = @{ needsDesktop = $false }
    native_desktop_recovery     = @{ needsDesktop = $false }
    pw_session_worker           = @{ needsDesktop = $false }
    idle_request                = @{ needsDesktop = $false }
    input_settle                = @{ needsDesktop = $false }
    super_drag_wait             = @{ needsDesktop = $false }
    network_wifi_route          = @{ needsDesktop = $false }
    capture_format              = @{ needsDesktop = $false }
    capture_device              = @{ needsDesktop = $false }
    # Not a test: tray_host_test starts it as the icon owner that exits without NIM_DELETE.
    tray_owner_helper           = @{ helper = $true }
    panel_hidden_reembed        = @{ needsDesktop = $true; qtPlatform = 'windows'; reason = 'creates and shows native panel windows' }
    system_surface              = @{ needsDesktop = $true; qtPlatform = 'offscreen'; reason = 'creates visible native windows at 0,0' }
    desktop_zorder              = @{ needsDesktop = $true; qtPlatform = 'offscreen'; reason = 'creates visible native windows and installs host-scoped WinEvent hooks' }
    mpris_app_identity          = @{ needsDesktop = $true; qtPlatform = 'offscreen'; reason = 'reads real shell app entries' }
    notification_mirror_consent = @{ needsDesktop = $true; qtPlatform = 'offscreen'; reason = 'creates a real message-only window' }
    keyboard_layout             = @{ needsDesktop = $true; qtPlatform = 'offscreen'; reason = 'creates a real hidden window' }
    native_lifetime             = @{ needsDesktop = $true; qtPlatform = 'offscreen'; reason = 'creates real message-only windows' }
    tray_hook                   = @{ needsDesktop = $true; qtPlatform = 'offscreen'; reason = 'creates a real hidden window' }
    tray_host                   = @{ needsDesktop = $true; qtPlatform = 'offscreen'; reason = 'starts a helper process that owns a real window' }
    video_node                  = @{ needsDesktop = $true; qtPlatform = 'offscreen'; reason = 'creates a never-shown D3D11 Quick window' }
}

New-Item -ItemType Directory -Force -Path $runRoot, (Split-Path -Parent $ManifestPath) | Out-Null
$manifest = [ordered]@{
    schemaVersion = 3
    runId = [guid]::NewGuid().ToString('N')
    generatedAtUtc = [DateTime]::UtcNow.ToString('o')
    completed = $false
    passed = $false
    error = 'the run did not finish'
    gateFailures = @()
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
        caseTotalsNote = 'casesSkipped sums the skipped cases of fixtures whose Qt Test output had a Totals line. fixturesWithCaseTotals counts those fixtures and fixturesWithoutCaseTotals the rest.'
        wallSeconds = 0
    }
    tests = @()
}

function Write-Manifest {
    Write-CaelestiaJsonAtomic $ManifestPath $manifest
}

Remove-Item -LiteralPath $ManifestPath -Force -ErrorAction SilentlyContinue
Write-Manifest

function Get-CacheValue([string]$Name) {
    $prefix = $Name + ':'
    $line = $cache | Where-Object { $_.StartsWith($prefix) } | Select-Object -First 1
    if (-not $line) { return $null }
    return ($line -split '=', 2)[1]
}

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
    if ($trait.helper) { return @{ helper = $true } }
    if ($trait.needsDesktop) {
        return @{ dependsOn = @('desktop'); qtPlatform = $trait.qtPlatform; reason = $trait.reason }
    }
    return @{ dependsOn = @(); qtPlatform = 'offscreen'; reason = $null }
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
    return $Artifact -match ('(?<![A-Za-z0-9_])' + [regex]::Escape($Target) + '(?:_autogen(?:_timestamp_deps)?)?(?![A-Za-z0-9_])')
}

function Get-BuildFailureOutput([string]$LogPath, [string[]]$Targets) {
    $output = @{}
    if (-not (Test-Path -LiteralPath $LogPath -PathType Leaf)) { return $output }
    $current = $null
    $collected = @{}
    foreach ($line in Get-Content -LiteralPath $LogPath) {
        if ($line -match '^FAILED:\s+\[code=\d+\]\s+(.+)$') {
            $artifact = $Matches[1]
            $current = $null
            foreach ($target in $Targets) {
                if (Test-TargetArtifact $artifact $target) { $current = $target; break }
            }
            continue
        }
        if ($line -match '^\[\d+/\d+\]') { $current = $null; continue }
        if (-not $current) { continue }
        if ($line -match 'error LNK\d+|fatal error LNK\d+|error C\d+|fatal error C\d+|: error:|AutoMoc|AUTOMOC|moc: ') {
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

# .NET Process cannot set STARTUPINFO.lpDesktop, hence the P/Invoke launcher.
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

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr OpenDesktopW(string lpszDesktop, int dwFlags, bool fInherit, int dwDesiredAccess);

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

    public static IntPtr CreateDesktopForTest(string name, out int error) {
        var handle = CreateDesktopW(name, null, IntPtr.Zero, 0, 0x000F01FF, IntPtr.Zero);
        error = Marshal.GetLastWin32Error();
        return handle;
    }

    public static bool DesktopExists(string name) {
        var handle = OpenDesktopW(name, 0, false, 0x0001);
        if (handle == IntPtr.Zero) return false;
        CloseDesktop(handle);
        return true;
    }
}
'@
}

function Invoke-IsolatedFixture([string]$Executable, [string]$Name, [string]$Log) {
    $started = [DateTime]::UtcNow
    $desktopName = 'caelestia-' + $manifest.runId.Substring(0, 8) + '-' + $Name
    $result = [pscustomobject]@{
        Started = $false; IsolationFailed = $false; ExitCode = $null; TimedOut = $false
        Duration = 0.0; Log = $Log; Desktop = $desktopName; Error = $null; CleanupError = $null
    }
    [int]$createError = 0
    $desktop = [CaelestiaIsolatedDesktop]::CreateDesktopForTest($desktopName, [ref]$createError)
    if ($desktop -eq [IntPtr]::Zero) {
        $result.IsolationFailed = $true
        $result.Desktop = $null
        $result.Error = "CreateDesktop failed with Win32 error $createError"
        return $result
    }
    $process = [IntPtr]::Zero
    $processId = 0
    $cleanup = New-Object 'System.Collections.Generic.List[string]'
    try {
        $info = [CaelestiaIsolatedDesktop+STARTUPINFO]::new()
        $info.cb = [Runtime.InteropServices.Marshal]::SizeOf($info)
        $info.lpDesktop = $desktopName
        $processInfo = [CaelestiaIsolatedDesktop+PROCESS_INFORMATION]::new()
        $commandLine = '"' + $Executable + '" -o "' + $Log + '",txt'
        $created = [CaelestiaIsolatedDesktop]::CreateProcessW($Executable, $commandLine,
            [IntPtr]::Zero, [IntPtr]::Zero, $false, 0, [IntPtr]::Zero, $runRoot, [ref]$info, [ref]$processInfo)
        if ($created) {
            $result.Started = $true
            $process = $processInfo.hProcess
            $processId = $processInfo.dwProcessId
            [CaelestiaIsolatedDesktop]::CloseHandle($processInfo.hThread) | Out-Null
            $result.TimedOut = [CaelestiaIsolatedDesktop]::WaitForSingleObject($process, $TestTimeoutSeconds * 1000) -eq 0x102
        } else {
            $result.Error = "CreateProcess failed with Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error())"
        }
    } catch {
        $result.Error = "Isolated launcher error: $_"
    } finally {
        if ($process -ne [IntPtr]::Zero) {
            if ([CaelestiaIsolatedDesktop]::WaitForSingleObject($process, 0) -eq 0x102) {
                $ErrorActionPreference = 'Continue'
                try { & taskkill.exe /PID $processId /T /F 2>&1 | Out-Null } catch { }
                if ([CaelestiaIsolatedDesktop]::WaitForSingleObject($process, 5000) -eq 0x102) {
                    [CaelestiaIsolatedDesktop]::TerminateProcess($process, 1) | Out-Null
                    [CaelestiaIsolatedDesktop]::WaitForSingleObject($process, 5000) | Out-Null
                }
            }
            if ([CaelestiaIsolatedDesktop]::WaitForSingleObject($process, 0) -eq 0x102) {
                $cleanup.Add("process $processId is still running after taskkill and TerminateProcess")
            } else {
                $exitCode = 0
                if (-not [CaelestiaIsolatedDesktop]::GetExitCodeProcess($process, [ref]$exitCode)) { $exitCode = -1 }
                $result.ExitCode = $exitCode
            }
            [CaelestiaIsolatedDesktop]::CloseHandle($process) | Out-Null
        }
        if (-not [CaelestiaIsolatedDesktop]::CloseDesktop($desktop)) {
            $cleanup.Add("CloseDesktop failed for '$desktopName'")
        }
        if ([CaelestiaIsolatedDesktop]::DesktopExists($desktopName)) {
            $cleanup.Add("desktop '$desktopName' still exists after it was closed")
        }
    }
    $result.Duration = [Math]::Round(([DateTime]::UtcNow - $started).TotalSeconds, 3)
    if ($cleanup.Count -gt 0) { $result.CleanupError = ($cleanup -join '; ') }
    return $result
}

function New-FixturePlan([string]$Name, [string]$Target, [string]$Executable, [bool]$Registered) {
    return [pscustomobject]@{
        name = $Name
        target = $Target
        executable = $Executable
        registered = $Registered
        dependsOn = @()
        qtPlatform = 'offscreen'
        mode = 'ctest'
        result = $null
        duration = 0.0
        skipReason = $null
        failure = $null
        buildFailure = $null
        cleanupFailure = $null
        skippedCases = $null
        runBy = 'none'
        isolation = $null
        log = $null
    }
}

$plans = New-Object 'System.Collections.Generic.List[object]'
$gateFailures = New-Object 'System.Collections.Generic.List[string]'
$ctestExit = $null
$revisionMatches = $false
$backendDirty = $true
$runError = $null

function Get-TargetBuildFailure([string]$Target) {
    if (-not $buildRecord.configureSucceeded) { return 'The test build did not configure this run.' }
    if ($recordTargets -notcontains $Target) { return "The test build record does not include $Target." }
    if (@($failedArtifacts | Where-Object { Test-TargetArtifact $_ $Target }).Count -gt 0) {
        return "Fixture $Target did not compile, generate or link."
    }
    if ($unattributedBuildFailure) {
        return "The test build failed outside any fixture target, so $Target.exe may be stale."
    }
    if (-not (Test-Path -LiteralPath (Join-Path $testBuild "$Target.exe") -PathType Leaf)) {
        return "The test build produced no $Target.exe."
    }
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
    $buildFailed = (-not $buildRecord.configureSucceeded) -or (-not $buildRecord.buildSucceeded)
    $unattributedArtifacts = @($failedArtifacts | Where-Object {
        $artifact = $_
        -not (@($declaredTargets | Where-Object { Test-TargetArtifact $artifact $_ }).Count)
    })
    $unattributedBuildFailure = $buildFailed -and ($failedArtifacts.Count -eq 0 -or $unattributedArtifacts.Count -gt 0)
    if ($buildFailed) {
        $detail = if ($failedArtifacts.Count -gt 0) { 'failed artifacts: ' + ($failedArtifacts -join '; ') } else { 'no failed artifact was recorded' }
        $gateFailures.Add("The backend test build did not succeed ($detail). See $buildLog.")
    }
    $buildErrors = Get-BuildFailureOutput $buildLog $declaredTargets

    $registeredByTarget = @{}
    foreach ($entry in $registered) {
        $target = if ($entry.executable) { [IO.Path]::GetFileNameWithoutExtension($entry.executable) } else { $entry.name + '_test' }
        if ($declaredTargets -contains $target) { $registeredByTarget[$target] = $entry }
    }
    foreach ($target in $declaredTargets) {
        $name = $target -replace '_test$', ''
        $entry = $registeredByTarget[$target]
        $traits = Get-TestTraits $name
        # A helper executable is launched by its fixture; it is never run as a test.
        if ($traits -and $traits.helper) { continue }
        $plan = New-FixturePlan $name $target (Join-Path $testBuild "$target.exe") ([bool]$entry)
        if ($traits) {
            $plan.dependsOn = @($traits.dependsOn)
            $plan.qtPlatform = $traits.qtPlatform
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
        $plan = New-FixturePlan $entry.name $target $entry.executable $true
        $plan.mode = 'fail'
        $plan.result = 'failed'
        $plan.failure = "unclassified fixture: CTest registered '$($entry.name)' with no declared target"
        $plans.Add($plan)
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

    foreach ($plan in $plans) {
        if ($plan.mode -notin @('direct', 'isolated')) { continue }
        $plan.log = Join-Path $runRoot "$($plan.name).qt.txt"
        $previousQtPlatform = $env:QT_QPA_PLATFORM
        $env:QT_QPA_PLATFORM = $plan.qtPlatform
        $run = $null
        $directFailure = $null
        $timedOut = $false
        try {
            if ($plan.mode -eq 'isolated') {
                $run = Invoke-IsolatedFixture $plan.executable $plan.name $plan.log
                $plan.cleanupFailure = $run.CleanupError
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
                $startInfo = New-Object Diagnostics.ProcessStartInfo
                $startInfo.FileName = $plan.executable
                $startInfo.Arguments = '-o "' + $plan.log + '",txt'
                $startInfo.WorkingDirectory = $runRoot
                $startInfo.UseShellExecute = $false
                $startInfo.CreateNoWindow = $true
                $startInfo.RedirectStandardOutput = $true
                $startInfo.RedirectStandardError = $true
                $child = $null
                try {
                    $child = [Diagnostics.Process]::Start($startInfo)
                } catch {
                    $directFailure = "Could not start: $($_.Exception.Message)"
                }
                if ($child) {
                    try {
                        $null = $child.StandardOutput.ReadToEndAsync()
                        $null = $child.StandardError.ReadToEndAsync()
                        if ($child.WaitForExit($TestTimeoutSeconds * 1000)) {
                            $child.WaitForExit()
                            $run = [pscustomobject]@{ ExitCode = $child.ExitCode }
                        } else {
                            $directFailure = "Timed out after $TestTimeoutSeconds seconds"
                            $savedPreference = $ErrorActionPreference
                            $ErrorActionPreference = 'Continue'
                            try { & taskkill.exe /PID $child.Id /T /F 2>&1 | Out-Null } catch { }
                            $ErrorActionPreference = $savedPreference
                            try { $child.Kill() } catch { }
                            if (-not $child.WaitForExit(5000)) { $directFailure += "; process $($child.Id) is still running" }
                        }
                    } finally {
                        $child.Dispose()
                    }
                }
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
            if ($null -eq $previousQtPlatform) { Remove-Item Env:\QT_QPA_PLATFORM -ErrorAction SilentlyContinue }
            else { $env:QT_QPA_PLATFORM = $previousQtPlatform }
        }
        if ($null -eq $run) {
            $plan.result = 'failed'
            $plan.failure = "$directFailure. See $($plan.log)."
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

foreach ($plan in $plans) {
    if (-not $plan.cleanupFailure) { continue }
    $plan.result = 'failed'
    $plan.failure = (@($plan.failure, "Cleanup failed: $($plan.cleanupFailure)") | Where-Object { $_ }) -join ' '
    $gateFailures.Add("Fixture '$($plan.name)' cleanup failed: $($plan.cleanupFailure)")
}
$manifest.gateFailures = @($gateFailures)

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
        cleanupFailure = $_.cleanupFailure
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
$manifest.totals.casesSkipped = (@($measured | ForEach-Object { [int]$_.skippedCases } | Measure-Object -Sum).Sum)
if ($null -eq $manifest.totals.casesSkipped) { $manifest.totals.casesSkipped = 0 }
$manifest.totals.wallSeconds = [Math]::Round(([DateTime]::UtcNow - $startedWall).TotalSeconds, 3)

$manifest.completed = $true
$manifest.passed = (-not $manifest.error) -and ($manifest.gateFailures.Count -eq 0) -and ($manifest.totals.failed -eq 0) -and
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
    foreach ($gateFailure in $manifest.gateFailures) { Write-Output "GATE $gateFailure" }
    if ($manifest.error) { Write-Output "ERROR $($manifest.error)" }
    throw "Backend native tests failed: $summary"
}
Write-Output "PASS backend native tests: $summary"
