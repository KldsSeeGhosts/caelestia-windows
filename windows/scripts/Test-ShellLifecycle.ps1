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
    # A locked .prev must leave the newest session's log appendable, not
    # truncate it just because rotation failed.
    [IO.File]::WriteAllText($stdoutPath, 'rotation-target')
    $lockedPrevious = [IO.File]::Open($stdoutPrevious, 'Open', 'ReadWrite', 'None')
    try { Move-CaelestiaLogToPrevious $stdoutPath } finally { $lockedPrevious.Dispose() }
    if ([IO.File]::ReadAllText($stdoutPath) -ne 'rotation-target' -or [IO.File]::ReadAllText($stdoutPrevious) -ne 'newer-session') {
        throw 'A locked previous log truncated the current log or damaged the previous log.'
    }
    Write-Output 'PASS logs: previous session retained, .prev replaced, locked file is non-fatal and keeps the newest log.'

    # Cleanup failure must not replace the original launch error or trigger a
    # retry against task/launcher state that could not be verified.
    & {
        function Start-ScheduledTask { [CmdletBinding()] param([string]$TaskName) }
        function Stop-ScheduledTask { [CmdletBinding()] param([string]$TaskName) throw 'fixture cleanup failure' }
        function Wait-CaelestiaReady {
            [CmdletBinding()] param([string]$Prefix, [int]$TimeoutSeconds, [switch]$LegacyReady, [string]$TaskName)
            if ($TimeoutSeconds -ne 75) { throw 'Scheduled startup lost its full launcher budget.' }
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
    & {
        $activation = [pscustomobject]@{ Starts = 0; Stops = 0; Unregisters = 0 }
        function Start-ScheduledTask { [CmdletBinding()] param([string]$TaskName) $activation.Starts++ }
        function Stop-ScheduledTask { [CmdletBinding()] param([string]$TaskName) $activation.Stops++ }
        function Unregister-ScheduledTask { [CmdletBinding()] param([string]$TaskName, [switch]$Confirm) $activation.Unregisters++ }
        function Wait-CaelestiaReady {
            [CmdletBinding()] param([string]$Prefix, [int]$TimeoutSeconds, [switch]$LegacyReady, [string]$TaskName)
            if ($TimeoutSeconds -ne 75) { throw 'Activation lost its outer launcher allowance.' }
            throw 'fixture readiness missing'
        }
        $detached = Join-Path $root 'activation-readiness'
        [IO.Directory]::CreateDirectory($detached) | Out-Null
        @'
param($Prefix, $Command)
if ($Command -ne 'Quit') { throw 'Activation cleanup did not request Quit.' }
Add-Content -LiteralPath (Join-Path $Prefix 'quit-calls') -Value 'quit'
'@ | Set-Content -LiteralPath (Join-Path $detached 'Start-Caelestia.ps1') -Encoding UTF8
        $refused = $false
        try { Start-CaelestiaDetached $detached -TaskName 'fixture-task' 3>$null }
        catch { $refused = $_.Exception.Message -eq 'fixture readiness missing' }
        if (-not $refused -or $activation.Starts -ne 2 -or $activation.Stops -ne 2 -or
            $activation.Unregisters -ne 1 -or @(Get-Content -LiteralPath (Join-Path $detached 'quit-calls')).Count -ne 2) {
            throw 'Transactional activation did not stop/quit each failed attempt and report failure for rollback.'
        }
    }
    Write-Output 'PASS activation: missing readiness still stops/quits both attempts and fails for transactional rollback.'

    # A real child process exercises IPC timeout, exit and pipe handling without
    # launching Qt, registering shortcuts or touching the session supervisor.
    Add-Type -OutputAssembly (Join-Path $root 'qs.exe') -OutputType ConsoleApplication -TypeDefinition @'
using System;
using System.IO;
using System.Threading;
public static class LifecycleIpcFixture {
    public static int Main(string[] args) {
        string command = args[args.Length - 1];
        if (command == "--live") { Thread.Sleep(60000); return 0; }
        string prefix = Path.GetDirectoryName(System.Diagnostics.Process.GetCurrentProcess().MainModule.FileName);
        string mode = File.ReadAllText(Path.Combine(prefix, "mode.txt"));
        if (mode == "timeout") { Thread.Sleep(10000); return 0; }
        if (mode == "failure") {
            Console.Out.WriteLine("private-state-sentinel");
            Console.Error.WriteLine("private-error-sentinel");
            return 3;
        }
        if (mode == "quit-failure") {
            File.WriteAllText(Path.Combine(prefix, "quit-called.txt"), "1");
            Console.Out.WriteLine("private-state-sentinel");
            Console.Error.WriteLine("private-error-sentinel");
            return 3;
        }
        int calls = Int32.Parse(File.ReadAllText(Path.Combine(prefix, "calls.txt")));
        File.WriteAllText(Path.Combine(prefix, "calls.txt"), (calls + 1).ToString());
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

    # The launcher's own Quit path must swallow a failed IPC without emitting
    # the output it captured before the exit-code check.
    $quitPrefix = Join-Path $root 'quit-prefix'
    [IO.Directory]::CreateDirectory((Join-Path $quitPrefix 'shell')) | Out-Null
    Copy-Item -LiteralPath (Join-Path $root 'qs.exe') -Destination (Join-Path $quitPrefix 'qs.exe')
    [IO.File]::WriteAllText((Join-Path $quitPrefix 'mode.txt'), 'quit-failure')
    @{
        product = 'caelestia-windows'; version = 1; prefix = $quitPrefix
        profile = (Join-Path $quitPrefix 'profile')
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $quitPrefix 'install.json') -Encoding UTF8
    $quitOutput = & (Join-Path $PSScriptRoot 'Start-Caelestia.ps1') -Prefix $quitPrefix -Command Quit 2>&1 | Out-String
    if (-not (Test-Path -LiteralPath (Join-Path $quitPrefix 'quit-called.txt'))) { throw 'The launcher Quit path did not reach IPC.' }
    if ($quitOutput -match 'private-') { throw 'The launcher Quit path leaked failed IPC output.' }
    Write-Output 'PASS quit: failed IPC output is not echoed by the launcher.'
    # Exercise plain Start and the actual logon/Start-menu wrapper, not just
    # their phase consumer. Every executable below is our console fake.
    $plainPrefix = Join-Path $root 'plain-start'
    [IO.Directory]::CreateDirectory((Join-Path $plainPrefix 'defaults')) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $plainPrefix 'shell')) | Out-Null
    foreach ($name in @('Start-Caelestia.ps1', 'Caelestia-Launcher.ps1', 'Caelestia-Versions.ps1')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $plainPrefix
    }
    $common = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Caelestia-InstallCommon.ps1'))
    $waitDefault = '[int]$TimeoutSeconds = 20, [string]$PreviousGeneration'
    if ([regex]::Matches($common, [regex]::Escape($waitDefault)).Count -ne 1) { throw 'Readiness wait fixture boundary changed.' }
    [IO.File]::WriteAllText((Join-Path $plainPrefix 'Caelestia-InstallCommon.ps1'),
        $common.Replace($waitDefault, '[int]$TimeoutSeconds = 1, [string]$PreviousGeneration'))
    Copy-Item -LiteralPath (Join-Path $root 'qs.exe') -Destination $plainPrefix
    [IO.File]::WriteAllText((Join-Path $plainPrefix 'mode.txt'), 'not-ready')
    [IO.File]::WriteAllText((Join-Path $plainPrefix 'calls.txt'), '0')
    [IO.File]::WriteAllText((Join-Path $plainPrefix 'Get-AccountPicture.ps1'), 'param($CacheRoot) ""')
    [IO.File]::WriteAllText((Join-Path $plainPrefix 'Install-SchemeRuntime.ps1'), 'param($ProfileRoot,$LockWaitSeconds) ''{"available":false}''')
    foreach ($name in @('shell.json', 'windows.json', 'keybinds.json')) {
        [IO.File]::WriteAllText((Join-Path $plainPrefix "defaults\$name"), '{}')
    }
    @{
        product = 'caelestia-windows'; version = 1; prefix = $plainPrefix
        profile = (Join-Path $plainPrefix 'profile')
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $plainPrefix 'install.json') -Encoding UTF8
    @'
param($StartInfo,$StateDirectory,$ConfigPath,$StdoutPath,$StderrPath)
if ((Get-Content -LiteralPath (Join-Path $PSScriptRoot 'helper-phase') -Raw).Trim() -eq 'waiting-ready') {
    throw 'Caelestia did not become ready. The live shell and supervisor were left running beside Explorer.'
}
[pscustomobject]@{ Watchdog = [Diagnostics.Process]::GetCurrentProcess(); StatusPath = 'fixture-running' }
'@ | Set-Content -LiteralPath (Join-Path $plainPrefix 'Start-DesktopShell.ps1') -Encoding UTF8
    $liveInfo = New-Object Diagnostics.ProcessStartInfo
    $liveInfo.FileName = Join-Path $plainPrefix 'qs.exe'
    $liveInfo.Arguments = '--live'
    $liveInfo.UseShellExecute = $false
    $liveInfo.CreateNoWindow = $true
    $live = [Diagnostics.Process]::Start($liveInfo)
    try {
        foreach ($phase in @('waiting-ready', 'running')) {
            [IO.File]::WriteAllText((Join-Path $plainPrefix 'helper-phase'), $phase)
            $failed = $false
            try { & (Join-Path $plainPrefix 'Start-Caelestia.ps1') -Prefix $plainPrefix -SkipSchemeRuntime | Out-Null }
            catch { $failed = $_.Exception.Message -match 'did not become ready' }
            if (-not $failed -or $live.HasExited) { throw 'Plain Start killed its unready shell or accepted strict IPC failure.' }
            $outcome = Join-Path $plainPrefix ('logon-' + $phase + '.json')
            & (Get-WindowsPowerShellPath) -NoProfile -File (Join-Path $plainPrefix 'Caelestia-Launcher.ps1') `
                -Action start -NoDialogs -OutcomeFile $outcome | Out-Null
            $code = $LASTEXITCODE
            $recorded = Get-Content -LiteralPath $outcome -Raw | ConvertFrom-Json
            if ($code -ne 1 -or $recorded.exitCode -ne 1 -or $recorded.message -notmatch 'did not become ready' -or $live.HasExited) {
                throw 'Logon launcher killed its unready shell or failed to report readiness failure.'
            }
        }
    } finally {
        if (-not $live.HasExited) { $live.Kill(); $null = $live.WaitForExit(2000) }
        $live.Dispose()
    }
    Write-Output 'PASS plain/logon Start: waiting-ready and strict IPC failure report errors and preserve the live child.'

    # Compile only. No supervisor or native desktop operations run here.
    Add-Type -Path (Join-Path $PSScriptRoot 'DesktopTakeover.cs') -ReferencedAssemblies System.Windows.Forms, System.Web.Extensions
    foreach ($case in @(@(0, 0), @(1, 0), @(2, 1), @(3, 2), @(10, 30))) {
        if ([Caelestia.Takeover.RestartPolicy]::DelaySeconds($case[0]) -ne $case[1]) { throw 'Unexpected crash backoff.' }
    }
    Write-Output 'PASS crash policy: immediate first recovery, bounded subsequent backoff.'
    foreach ($line in @('  INFO qml: CAELESTIA_SHELL_READY',
        '2026-11-11 12:00:00.000  INFO qml: CAELESTIA_SHELL_READY')) {
        $readiness = [Caelestia.Takeover.ShellReadiness]::new()
        $readiness.Observe($line)
        if (-not $readiness.Ready) { throw 'Native QML readiness record was rejected.' }
    }
    $readiness = [Caelestia.Takeover.ShellReadiness]::new()
    foreach ($line in @('private CAELESTIA_SHELL_READY', '  INFO qml: "CAELESTIA_SHELL_READY"',
        '  INFO qml: CAELESTIA_SHELL_READY private', '  WARN qml: CAELESTIA_SHELL_READY',
        '  INFO other: CAELESTIA_SHELL_READY', '  INFO qml: CAELESTIA_SHELL_NOT_READY')) {
        $readiness.Observe($line)
        if ($readiness.Ready) { throw 'User text or a non-readiness log record was accepted.' }
    }
    $oldChild = [Caelestia.Takeover.ShellReadiness]::new()
    $oldChild.Observe('  INFO qml: CAELESTIA_SHELL_READY')
    if ($readiness.Ready) { throw 'An old child made its replacement ready.' }
    $oldChild.Observe('  INFO qml: CAELESTIA_SHELL_NOT_READY')
    if (-not $oldChild.Ready) { throw 'A reload-style dip reset process readiness.' }
    Write-Output 'PASS readiness records: exact content-free QML info records, per-child latch, reload stability.'

    # Run the actual startup phase consumer against a disposable process
    # boundary. No watchdog, Qt process, desktop ownership or IPC is started.
    & {
        $startupScripts = Join-Path $root 'startup-consumer'
        [IO.Directory]::CreateDirectory($startupScripts) | Out-Null
        $startupSource = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Start-DesktopShell.ps1'))
        if (-not $startupSource.Contains('AddSeconds(75)')) { throw 'Launcher lost its 75 s startup allowance.' }
        [IO.File]::WriteAllText((Join-Path $startupScripts 'Start-DesktopShell.ps1'), $startupSource.Replace('AddSeconds(75)', 'AddSeconds(1)'))
        @'
function Get-WindowsPowerShellPath { 'fixture.exe' }
function Stop-CaelestiaSupervisor($Supervisor) { $consumer.Recovered = $true }
function Read-CaelestiaSupervisorStatus($Path) { [pscustomobject]@{ phase = 'recovered' } }
'@ | Set-Content -LiteralPath (Join-Path $startupScripts 'Caelestia-InstallCommon.ps1') -Encoding UTF8
        function Start-Process {
            param($FilePath, $ArgumentList, $WindowStyle, [switch]$PassThru, $WorkingDirectory, $RedirectStandardOutput, $RedirectStandardError)
            [IO.File]::WriteAllText((Join-Path $StateDirectory 'watchdog.json'), '{}')
            [pscustomobject]@{ Handle = 0; HasExited = $false; Id = 1 }
        }
        function Get-Content {
            param($LiteralPath, [switch]$Raw)
            $index = [Math]::Min($consumer.Calls, $consumer.Phases.Count - 1)
            $consumer.Calls++
            '{"phase":"' + $consumer.Phases[$index] + '","shellPid":' + $consumer.ShellPid + '}'
        }
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = 'fixture.exe'
        $info.WorkingDirectory = $root
        foreach ($outcome in @('running', 'waiting-ready', 'clean-exit', 'crash-give-up', 'restore-pending', 'timeout', 'timeout-live')) {
            $caseState = Join-Path $startupScripts $outcome
            $consumer = [pscustomobject]@{
                Phases = @('starting', 'restart-backoff', $(if ($outcome -like 'timeout*') { 'starting' } else { $outcome }))
                ShellPid = $(if ($outcome -in @('waiting-ready', 'timeout-live')) { 123 } else { 0 })
                Calls = 0; Recovered = $false
            }
            $succeeded = $false
            try {
                $null = & (Join-Path $startupScripts 'Start-DesktopShell.ps1') -StartInfo $info -StateDirectory $caseState
                $succeeded = $true
            } catch {
                if ($_.Exception.Message -notmatch 'Desktop watchdog (stopped during startup|did not reach)|Caelestia did not become ready') { throw }
            }
            if ($succeeded -ne ($outcome -eq 'running') -or $consumer.Calls -lt 3) {
                throw "Startup consumer accepted a non-ready phase or failed running: $outcome."
            }
            if ($consumer.Recovered -ne ($outcome -eq 'timeout')) { throw 'Launcher deadline bypassed bounded recovery.' }
        }
    }
    Write-Output 'PASS startup consumer: waiting-ready and live-start deadlines report failure without stopping the child; only stalled pre-child launch recovers.'
    & {
        $stale = [pscustomobject]@{ Stopped = $false }
        function Get-CaelestiaSupervisors {
            [pscustomobject]@{ Phase = 'waiting-ready'; Process = [pscustomobject]@{ HasExited = $false }; StatusPath = 'fixture-status' }
        }
        function Read-CaelestiaSupervisorStatus {
            [pscustomobject]@{ heartbeat = $true; utc = [DateTime]::UtcNow.AddSeconds(-6).ToString('o') }
        }
        function Stop-CaelestiaSupervisor { param($Supervisor) $stale.Stopped = $true }
        Repair-CaelestiaStaleSupervisors 'fixture-profile'
        if (-not $stale.Stopped) { throw 'waiting-ready did not use the normal five-second stale heartbeat allowance.' }
    }
    Write-Output 'PASS stale waiting owner: missing heartbeat uses five seconds, not the 75-second starting allowance.'
    # Exercise real filesystem rollback, with only launch/process discovery
    # replaced. These fixtures never own a session supervisor or desktop.
    & {
        function Get-CaelestiaProcesses { return @() }
        function Get-CaelestiaSupervisors { return @() }
        function Start-CaelestiaDetached([string]$Prefix, [switch]$LegacyReady) {
            $script:rollbackLaunches++
            if (-not $LegacyReady -or [IO.File]::ReadAllText((Join-Path $Prefix 'version.txt')) -ne 'old') {
                throw 'Rollback did not launch the complete previous payload.'
            }
        }
        $script:rollbackLaunches = 0
        $prefix = Join-Path $root 'rollback-app'
        $backup = Join-Path $root 'rollback-app.old'
        $profile = Join-Path $root 'rollback-profile'
        [IO.Directory]::CreateDirectory($prefix) | Out-Null
        [IO.Directory]::CreateDirectory($backup) | Out-Null
        [IO.File]::WriteAllText((Join-Path $prefix 'version.txt'), 'broken-new')
        [IO.File]::WriteAllText((Join-Path $prefix 'new-only.txt'), 'remove on rollback')
        [IO.File]::WriteAllText((Join-Path $backup 'version.txt'), 'old')
        [IO.Directory]::CreateDirectory((Join-Path $backup 'versions\v1')) | Out-Null
        [IO.File]::WriteAllText((Join-Path $backup 'versions\v1\install.json'), 'nested-payload')
        @{ product = 'caelestia-windows'; prefix = $prefix; profile = $profile; current = 'old-version' } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $backup 'install.json') -Encoding UTF8
        Restore-CaelestiaUpdate $prefix $profile $backup $true
        if (Test-Path -LiteralPath (Join-Path $prefix 'new-only.txt')) { throw 'Rollback retained a new-only file.' }
        if ([IO.File]::ReadAllText((Join-Path $prefix 'versions\v1\install.json')).Trim() -ne 'nested-payload') {
            throw 'Rollback excluded a nested version payload selector.'
        }
        # An aborted mirror (a file locked between the process re-check and
        # robocopy) must not leave install.json claiming the replacement. The
        # selector is committed atomically before the copy and never copied.
        @{ product = 'caelestia-windows'; version = 2; prefix = $prefix; profile = $profile
           current = 'replacement-version'; previous = 'old-version' } |
            ConvertTo-Json | Set-Content -LiteralPath (Join-Path $prefix 'install.json') -Encoding UTF8
        $originalMirror = ${function:Invoke-CaelestiaMirror}
        try {
            ${function:Invoke-CaelestiaMirror} = {
                param([string]$Source, [string]$Destination)
                [IO.File]::WriteAllText((Join-Path $Destination 'partial-from-mirror.txt'), 'partial')
                8
            }
            $script:rollbackLaunches = 0
            $aborted = $false
            try { Restore-CaelestiaUpdate $prefix $profile $backup $true }
            catch { $aborted = $_.Exception.Message -match 'robocopy exit 8' }
            if (-not $aborted) { throw 'An aborted rollback mirror was not reported.' }
        } finally {
            ${function:Invoke-CaelestiaMirror} = $originalMirror
        }
        $selector = Get-Content -LiteralPath (Join-Path $prefix 'install.json') -Raw | ConvertFrom-Json
        if ($selector.current -ne 'old-version') { throw 'An aborted rollback left the selector claiming the replacement.' }
        if (-not (Test-Path -LiteralPath (Join-Path $backup 'install.json'))) { throw 'An aborted rollback did not retain the backup.' }
        if ($script:rollbackLaunches -ne 0) { throw 'An aborted rollback launched a payload.' }
        $refused = $false
        try { Restore-CaelestiaUpdate $prefix (Join-Path $root 'foreign-profile') $backup $true }
        catch { $refused = $_ -match 'does not belong' }
        if (-not $refused) { throw 'Rollback accepted a foreign profile.' }
    }
    Write-Output 'PASS rollback: restores old bytes, removes new-only files, validates ownership, and an aborted mirror keeps the rollback selector.'
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
