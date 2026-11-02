[CmdletBinding()]
param([switch]$Stage)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Caelestia-InstallCommon.ps1')
$shellSource = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '..\shell\shell.qml'))
if ($shellSource -notmatch 'Quickshell\.reload\(false\)' -or $shellSource -match 'Quickshell\.reload\(true\)') {
    throw 'Normal restart must use soft reload to transfer existing native windows.'
}
$root = Resolve-CaelestiaDirectory (Join-Path ([IO.Path]::GetTempPath()) ('caelestia-lifecycle-' + [guid]::NewGuid().ToString('N')))
[IO.Directory]::CreateDirectory($root) | Out-Null
try {
    # A new start keeps the previous session's log, replaces the older .prev,
    # and never fails when a live shell still has the current log open.
    $logs = Join-Path $root 'logs'
    [IO.Directory]::CreateDirectory($logs) | Out-Null
    $stdoutPath = Join-Path $logs 'shell.stdout.log'
    $stdoutPrevious = Join-Path $logs 'shell.stdout.prev.log'
    [IO.File]::WriteAllText($stdoutPath, 'previous-session')
    Move-CaelestiaLogToPrevious $stdoutPath
    if ([IO.File]::ReadAllText($stdoutPrevious) -ne 'previous-session' -or [IO.File]::ReadAllText($stdoutPath) -ne '') {
        throw 'Log rotation did not keep the previous session.'
    }
    [IO.File]::WriteAllText($stdoutPath, 'newer-session')
    Move-CaelestiaLogToPrevious $stdoutPath
    if ([IO.File]::ReadAllText($stdoutPrevious) -ne 'newer-session') { throw 'Log rotation did not replace the older previous log.' }
    [IO.File]::WriteAllText($stdoutPath, 'live-session')
    $lockedLog = [IO.File]::Open($stdoutPath, 'Open', 'Read', 'None')
    try { Move-CaelestiaLogToPrevious $stdoutPath } finally { $lockedLog.Dispose() }
    if ([IO.File]::ReadAllText($stdoutPath) -ne 'live-session' -or [IO.File]::ReadAllText($stdoutPrevious) -ne 'newer-session') {
        throw 'A locked log was truncated or damaged the previous log.'
    }
    Write-Output 'PASS logs: previous session retained, .prev replaced, locked file is non-fatal.'

    # Cleanup failure must not replace the original launch error or trigger a
    # retry against task/launcher state that could not be verified.
    & {
        function Start-ScheduledTask { [CmdletBinding()] param([string]$TaskName) }
        function Stop-ScheduledTask { [CmdletBinding()] param([string]$TaskName) throw 'fixture cleanup failure' }
        function Wait-CaelestiaReady {
            [CmdletBinding()] param([string]$Prefix, [switch]$LegacyReady, [string]$TaskName)
            $script:waits++
            throw 'fixture launch failure'
        }
        function Unregister-ScheduledTask { [CmdletBinding()] param([string]$TaskName, [switch]$Confirm) }
        $script:waits = 0
        $detached = Join-Path $root 'detached'
        [IO.Directory]::CreateDirectory($detached) | Out-Null
        [IO.File]::WriteAllText((Join-Path $detached 'Start-Caelestia.ps1'), '')
        $failed = $false
        try { Start-CaelestiaDetached $detached -TaskName 'fixture-task' 3>$null }
        catch { $failed = $_.Exception.Message -match 'fixture launch failure' -and $_.Exception.Message -notmatch 'fixture cleanup failure' }
        if (-not $failed -or $script:waits -ne 1) { throw 'Cleanup failure masked the launch error or allowed a retry.' }
    }
    Write-Output 'PASS startup: cleanup failure preserves the launch error and prevents a retry.'

    # A real child process exercises IPC timeout, exit and pipe handling without
    # launching Qt, registering shortcuts or touching the session supervisor.
    Add-Type -OutputAssembly (Join-Path $root 'qs.exe') -OutputType ConsoleApplication -TypeDefinition @'
using System;
using System.IO;
using System.Threading;
public static class LifecycleIpcFixture {
    public static int Main(string[] args) {
        string command = args[args.Length - 1];
        string mode = File.ReadAllText("mode.txt");
        if (mode == "timeout") { Thread.Sleep(10000); return 0; }
        if (mode == "failure") {
            Console.Out.WriteLine("private-state-sentinel");
            Console.Error.WriteLine("private-error-sentinel");
            return 3;
        }
        int calls = Int32.Parse(File.ReadAllText("calls.txt"));
        File.WriteAllText("calls.txt", (calls + 1).ToString());
        if (command == "restart") { Console.WriteLine(""); return 0; }
        if (mode == "legacy") Console.WriteLine("{\"screens\":1,\"windows\":[{}]}");
        else {
            bool ready = mode != "not-ready" && (mode != "reload" || calls >= 2);
            string generation = mode == "reload" && calls == 0 ? "old" : "new";
            Console.WriteLine("{\"lifecycle\":{\"generation\":\"" + generation + "\",\"ready\":" + ready.ToString().ToLowerInvariant() + "}}");
        }
        return 0;
    }
}
'@
    function Set-Mode([string]$mode) {
        [IO.File]::WriteAllText((Join-Path $root 'mode.txt'), $mode)
        [IO.File]::WriteAllText((Join-Path $root 'calls.txt'), '0')
    }
    Set-Mode reload
    Wait-CaelestiaReady $root -PreviousGeneration old
    if ([int][IO.File]::ReadAllText((Join-Path $root 'calls.txt')) -ne 3) {
        throw 'Reload accepted an old generation or a new generation before readiness.'
    }
    Set-Mode legacy
    Wait-CaelestiaReady $root -LegacyReady
    foreach ($mode in @('legacy', 'not-ready')) {
        Set-Mode $mode
        $refused = $false
        try { Wait-CaelestiaReady $root -TimeoutSeconds 1 } catch { $refused = $_ -match 'did not become ready' }
        if (-not $refused) { throw "Readiness accepted $mode." }
    }
    Set-Mode not-ready
    $refused = $false
    try { Wait-CaelestiaReady $root -TimeoutSeconds 1 -LegacyReady } catch { $refused = $_ -match 'did not become ready' }
    if (-not $refused) { throw 'Legacy compatibility bypassed an explicit not-ready state.' }
    Set-Mode failure
    $refused = $false
    try { Invoke-CaelestiaIpc $root state }
    catch {
        $refused = $_ -match 'exit 3' -and $_ -notmatch 'private-'
    }
    if (-not $refused) { throw 'Failed IPC was accepted or leaked its output.' }
    Set-Mode timeout
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $refused = $false
    try { Invoke-CaelestiaIpc $root state 250 } catch { $refused = $_ -match 'timed out' }
    if (-not $refused -or $clock.Elapsed.TotalSeconds -gt 2) { throw 'IPC timeout was not bounded.' }
    Write-Output 'PASS IPC: generation change, readiness, legacy rollback, failure privacy and bounded timeout.'

    # Compile only. No supervisor or native desktop operations run here.
    Add-Type -Path (Join-Path $PSScriptRoot 'DesktopTakeover.cs') -ReferencedAssemblies System.Windows.Forms, System.Web.Extensions
    foreach ($case in @(@(0, 0), @(1, 0), @(2, 1), @(3, 2), @(10, 30))) {
        if ([Caelestia.Takeover.RestartPolicy]::DelaySeconds($case[0]) -ne $case[1]) { throw 'Unexpected crash backoff.' }
    }
    Write-Output 'PASS crash policy: immediate first recovery, bounded subsequent backoff.'
    # Exercise real filesystem rollback, with only launch/process discovery
    # replaced. These fixtures never own a session supervisor or desktop.
    & {
        function Get-CaelestiaProcesses { return @() }
        function Get-CaelestiaSupervisors { return @() }
        function Start-CaelestiaDetached([string]$Prefix, [switch]$LegacyReady) {
            if (-not $LegacyReady -or [IO.File]::ReadAllText((Join-Path $Prefix 'version.txt')) -ne 'old') {
                throw 'Rollback did not launch the complete previous payload.'
            }
        }
        $prefix = Join-Path $root 'rollback-app'
        $backup = Join-Path $root 'rollback-app.old'
        $profile = Join-Path $root 'rollback-profile'
        [IO.Directory]::CreateDirectory($prefix) | Out-Null
        [IO.Directory]::CreateDirectory($backup) | Out-Null
        [IO.File]::WriteAllText((Join-Path $prefix 'version.txt'), 'broken-new')
        [IO.File]::WriteAllText((Join-Path $prefix 'new-only.txt'), 'remove on rollback')
        [IO.File]::WriteAllText((Join-Path $backup 'version.txt'), 'old')
        @{ product = 'caelestia-windows'; prefix = $prefix; profile = $profile } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $backup 'install.json') -Encoding UTF8
        Restore-CaelestiaUpdate $prefix $profile $backup $true
        if (Test-Path -LiteralPath (Join-Path $prefix 'new-only.txt')) { throw 'Rollback retained a new-only file.' }
        $refused = $false
        try { Restore-CaelestiaUpdate $prefix (Join-Path $root 'foreign-profile') $backup $true }
        catch { $refused = $_ -match 'does not belong' }
        if (-not $refused) { throw 'Rollback accepted a foreign profile.' }
    }
    Write-Output 'PASS rollback: restores old bytes, removes new-only files, validates ownership before launch.'
    if ($Stage) {
        $destination = Join-Path $root 'shell'
        $clock.Restart()
        $null = & (Join-Path $PSScriptRoot 'Stage-ShellPrototype.ps1') -Destination $destination -ProfileRoot (Join-Path $root 'profile') -Prototype shell-live
        $elapsed = $clock.Elapsed.TotalSeconds
        $repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..'))
        $sources = Get-Content -LiteralPath (Join-Path $destination 'sources.json') -Raw | ConvertFrom-Json
        foreach ($entry in $sources) {
            if ($entry.sourceSha256 -ne (Get-FileHash -LiteralPath (Join-Path $repo $entry.source)).Hash -or
                $entry.stagedSha256 -ne (Get-FileHash -LiteralPath (Join-Path $destination $entry.staged)).Hash) {
                throw "Staged provenance mismatch: $($entry.staged)"
            }
        }
        Write-Output ('PASS staging: independently verified {0} source/destination hashes; stage took {1:N3}s.' -f $sources.Count, $elapsed)
    }
} finally {
    $safeRoot = Resolve-CaelestiaDirectory $root
    if ((Split-Path -Parent $safeRoot) -ne [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') -or
        (Split-Path -Leaf $safeRoot) -notlike 'caelestia-lifecycle-*') { throw 'Unsafe lifecycle test cleanup path.' }
    Assert-CaelestiaNoReparsePoints $safeRoot
    Remove-Item -LiteralPath $safeRoot -Recurse -Force
}
