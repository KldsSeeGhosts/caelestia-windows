# Shared by repository and installed scripts. No machine-wide changes.
$ErrorActionPreference = 'Stop'

function Resolve-CaelestiaDirectory([string]$Path) {
    if (-not $Path -or $Path.IndexOfAny([char[]]@('"', "`r", "`n")) -ge 0) {
        throw 'A nonempty Windows directory path is required.'
    }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($full -eq [IO.Path]::GetPathRoot($full).TrimEnd('\')) { throw "Unsafe directory: $full" }
    foreach ($protected in @($env:USERPROFILE, $env:WINDIR, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA, $env:APPDATA, $env:TEMP)) {
        if ($protected -and ($protected -eq $full -or $protected.StartsWith($full + '\', [StringComparison]::OrdinalIgnoreCase))) {
            throw "Directory contains a protected Windows/user location: $full"
        }
    }
    # Refuse junction/symlink traversal before copying or recursive removal.
    $ancestor = $full
    while ($ancestor) {
        if (Test-Path -LiteralPath $ancestor) {
            $item = Get-Item -LiteralPath $ancestor -Force
            if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
                throw "Directory must not traverse a file or reparse point: $ancestor"
            }
        }
        $ancestor = Split-Path -Parent $ancestor
    }
    return $full
}

function Read-CaelestiaInstall([string]$Prefix) {
    $record = Get-Content -LiteralPath (Join-Path $Prefix 'install.json') -Raw | ConvertFrom-Json
    if ($record.product -ne 'caelestia-windows' -or $record.version -notin @(1, 2) -or $record.prefix -ne $Prefix) {
        throw "Not a recognized Caelestia installation: $Prefix"
    }
    if ($record.version -eq 2) {
        Assert-CaelestiaVersionId ([string]$record.current)
        if ($record.previous) { Assert-CaelestiaVersionId ([string]$record.previous) }
    }
    return $record
}

function Get-CaelestiaProcesses([string]$Prefix) {
    $exe = Join-Path $Prefix 'qs.exe'
    $versions = Join-Path $Prefix 'versions'
    return @(Get-Process -Name qs -ErrorAction SilentlyContinue | Where-Object {
        $_.Path -eq $exe -or ($_.Path -and
            [IO.Path]::GetDirectoryName([IO.Path]::GetDirectoryName($_.Path)) -eq $versions)
    })
}

# Live desktop supervisors recorded under the profile. A supervisor in
# starting or restart-backoff has no qs.exe, but still owns the prefix files.
function Get-CaelestiaSupervisors([string]$ProfileRoot) {
    $found = @()
    if (-not $ProfileRoot) { return $found }
    foreach ($file in @(Get-ChildItem -Path (Join-Path $ProfileRoot 'runtime\supervisor-*\watchdog.json') -ErrorAction SilentlyContinue)) {
        $status = $null
        try { $status = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json } catch { continue }
        if (-not $status -or $status.phase -notin @('starting', 'running', 'restart-backoff')) { continue }
        $id = if ($status.watchdogPid) { $status.watchdogPid } else { $status.pid }
        if (-not $id) { continue }
        $process = Get-Process -Id $id -ErrorAction SilentlyContinue
        if (-not $process) { continue }
        try {
            if ($process.HasExited) { continue }
            if ($process.ProcessName -and $process.ProcessName -notmatch '^(powershell|pwsh)$') { continue }
            if ($status.utc) {
                $startedUtc = $process.StartTime.ToUniversalTime()
                if ($startedUtc -gt [DateTimeOffset]::Parse([string]$status.utc).UtcDateTime.AddSeconds(5)) { continue }
            }
        } catch {
            # If the process still exists and is a PowerShell host (or cannot be
            # inspected due to permissions), treat the supervisor as live rather
            # than silently allowing install/uninstall to race it.
            if ($process.HasExited) { continue }
            if ($process.ProcessName -and $process.ProcessName -notmatch '^(powershell|pwsh)$') { continue }
        }
        $found += [pscustomobject]@{ StatusPath = $file.FullName; Phase = [string]$status.phase; Process = $process }
    }
    return $found
}

# Keep the previous session's log for crash diagnosis. Moving the file can fail
# while a live shell still holds it or when .prev is locked; on failure keep the
# current log intact and let the new session append to it, because truncating it
# would lose the newest diagnostics. Never fail startup because of a log.
function Move-CaelestiaLogToPrevious([string]$Path) {
    $rotated = $false
    try {
        if ([IO.File]::Exists($Path)) {
            $previous = Join-Path ([IO.Path]::GetDirectoryName($Path)) ([IO.Path]::GetFileNameWithoutExtension($Path) + '.prev' + [IO.Path]::GetExtension($Path))
            # Replace overwrites .prev in one step; the old .prev survives if
            # the current log is locked.
            if ([IO.File]::Exists($previous)) { [IO.File]::Replace($Path, $previous, [System.Management.Automation.Language.NullString]::Value) }
            else { [IO.File]::Move($Path, $previous) }
        }
        $rotated = $true
    } catch { }
    if ($rotated) { try { [IO.File]::WriteAllText($Path, '') } catch { } }
}

# Newest desktop-before.json left behind by a hard-killed supervisor that never
# reached a terminal phase.
function Get-CaelestiaUnrestoredSnapshot([string]$ProfileRoot) {
    if (-not $ProfileRoot) { return $null }
    $terminal = @('clean-exit', 'recovered', 'crash-give-up', 'watchdog-error')
    $candidates = @()
    foreach ($snap in @(Get-ChildItem -Path (Join-Path $ProfileRoot 'runtime\supervisor-*\desktop-before.json') -ErrorAction SilentlyContinue)) {
        $statusFile = Join-Path $snap.DirectoryName 'watchdog.json'
        if (Test-Path -LiteralPath $statusFile -PathType Leaf) {
            try {
                $status = Get-Content -LiteralPath $statusFile -Raw | ConvertFrom-Json
                if ($status.phase -in $terminal) { continue }
            } catch { }
        }
        $candidates += $snap
    }
    return ($candidates | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1)
}

# Windows PowerShell 5.1 hosts the supervisor; $PSHOME is wrong under pwsh 7.
function Get-WindowsPowerShellPath {
    $path = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $path -PathType Leaf) { return $path }
    return Join-Path $PSHOME 'powershell.exe'
}

# IPC never provisions Python, loads the account picture or starts a watchdog.
function Invoke-CaelestiaIpc([string]$Prefix, [string]$Command, [int]$TimeoutMs = 10000) {
    $Prefix = Resolve-CaelestiaRuntimePrefix $Prefix -Running
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = Join-Path $Prefix 'qs.exe'
    $info.WorkingDirectory = $Prefix
    $info.Arguments = 'ipc --path "' + (Join-Path $Prefix 'shell\shell.qml') + '" call shell ' + $Command
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $process = [Diagnostics.Process]::Start($info)
    try {
        $outTask = $process.StandardOutput.ReadToEndAsync()
        $errTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutMs)) { $process.Kill(); throw 'Shell IPC timed out.' }
        $output = $outTask.GetAwaiter().GetResult()
        # Consume diagnostics, but do not echo shell state or user data on failure.
        $null = $errTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw "Shell IPC $Command failed (exit $($process.ExitCode))." }
        return $output
    } finally { $process.Dispose() }
}

function Wait-CaelestiaReady([string]$Prefix, [int]$TimeoutSeconds = 20, [string]$PreviousGeneration = '', [switch]$LegacyReady, [string]$TaskName = '') {
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    do {
        try {
            $remaining = [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds
            if ($remaining -le 0) { break }
            $state = Invoke-CaelestiaIpc $Prefix state ([Math]::Min(1000, $remaining)) | ConvertFrom-Json
            if (($state.lifecycle.ready -eq $true -or ($LegacyReady -and -not $state.PSObject.Properties['lifecycle'] -and
                    $state.screens -gt 0 -and $state.windows.Count -eq $state.screens)) -and
                (-not $PreviousGeneration -or $state.lifecycle.generation -ne $PreviousGeneration)) { return }
        } catch { }
        if ($TaskName -and $clock.Elapsed.TotalSeconds -ge 1) {
            # A constructor/launcher failure must not consume the entire
            # readiness timeout before a safe retry or rollback.
            $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
            if ($task.State -eq 'Ready') {
                $result = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction Stop
                if ($result.LastRunTime.Year -gt 2000) { throw 'Scheduled Caelestia launch exited before readiness.' }
            }
        }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Caelestia did not become ready within $TimeoutSeconds seconds. See the profile logs and runtime\supervisor-*\watchdog*.log."
}

# Task Scheduler owns the process tree, not the invoking agent/terminal's job.
# On-demand only, interactive and non-elevated, with no autostart registration.
function New-CaelestiaLaunchTask([string]$Prefix) {
    $taskName = 'Caelestia-Start-' + [guid]::NewGuid().ToString('N')
    $launcher = Join-Path $Prefix 'Start-Caelestia.ps1'
    $action = New-ScheduledTaskAction -Execute (Get-WindowsPowerShellPath) `
        -Argument ('-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $launcher + '" -Prefix "' + $Prefix + '"') `
        -WorkingDirectory $Prefix
    $principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -ErrorAction Stop | Out-Null
    return $taskName
}

function Start-CaelestiaDetached([string]$Prefix, [switch]$LegacyReady, [string]$TaskName = '') {
    if (-not $TaskName) { $TaskName = New-CaelestiaLaunchTask $Prefix }
    $launcher = Join-Path $Prefix 'Start-Caelestia.ps1'
    try {
        for ($attempt = 0; $attempt -lt 2; $attempt++) {
            try {
                Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
                Wait-CaelestiaReady $Prefix -LegacyReady:$LegacyReady -TaskName $taskName
                return
            } catch {
                $launchError = $_
                try {
                    # Do not allow a slow launcher to start later over a retry or
                    # rollback. Restore owned state before attempting another run.
                    Stop-ScheduledTask -TaskName $taskName -ErrorAction Stop
                    & $launcher -Prefix $Prefix -Command Quit | Out-Null
                } catch {
                    # Cleanup must not replace the startup error, and if the
                    # launcher/task state cannot be verified, never retry over it.
                    Write-Warning "Caelestia cleanup after a failed launch did not complete: $($_.Exception.Message)"
                    throw $launchError
                }
                if ($attempt -eq 1) { throw $launchError }
                Write-Warning 'Caelestia startup failed; retrying once after cleanup.'
            }
        }
    } finally {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    }
}

function Restore-CaelestiaUpdate([string]$Prefix, [string]$ProfileRoot, [string]$Backup, [bool]$ReplacementActive) {
    # Recovery must also work after a failed/partial mirror, where the new
    # launch script may not exist. Use the untouched backup's launcher to quit.
    $record = Get-Content -LiteralPath (Join-Path $Backup 'install.json') -Raw | ConvertFrom-Json
    if ($record.product -ne 'caelestia-windows' -or $record.prefix -ne $Prefix -or $record.profile -ne $ProfileRoot) {
        throw 'Rollback does not belong to this installation.'
    }
    $running = (Get-CaelestiaProcesses $Prefix) -or @(Get-CaelestiaSupervisors $ProfileRoot).Count
    if (-not $ReplacementActive -and $running) {
        # Quit itself failed before any files changed. Do not launch a second
        # supervisor over the old one if it is still serving the desktop.
        Wait-CaelestiaReady $Prefix -LegacyReady
        return
    }
    if ($ReplacementActive) {
        if ($running) { & (Join-Path $Backup 'Start-Caelestia.ps1') -Prefix $Prefix -Command Quit | Out-Null }
        if ((Get-CaelestiaProcesses $Prefix) -or @(Get-CaelestiaSupervisors $ProfileRoot).Count) {
            throw 'Replacement is still running; rollback files were retained.'
        }
        Assert-CaelestiaNoReparsePoints $Prefix
        Assert-CaelestiaNoReparsePoints $Backup
        & robocopy.exe $Backup $Prefix /MIR /XJ /R:2 /W:1 /NFL /NDL /NJH /NJS /NP | Out-Null
        if ($LASTEXITCODE -ge 8) { throw "Rollback failed (robocopy exit $LASTEXITCODE)." }
        $global:LASTEXITCODE = 0
    }
    Start-CaelestiaDetached $Prefix -LegacyReady
}

# Walk without following links; a junction inside a tree being deleted would
# otherwise send Remove-Item -Recurse into its target.
function Assert-CaelestiaNoReparsePoints([string]$Root) {
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($Root)
    while ($pending.Count) {
        foreach ($item in Get-ChildItem -LiteralPath $pending.Pop() -Force) {
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "Refusing to remove a tree containing a reparse point: $($item.FullName)"
            }
            if ($item.PSIsContainer) { $pending.Push($item.FullName) }
        }
    }
}

# Profile ownership marker. Purge may only delete a profile this prefix created.
$script:CaelestiaProfileEntries = @('config', 'state', 'cache', 'data', 'runtime', 'logs', 'scheme', 'profile-owner.json')
function Read-CaelestiaProfileOwner([string]$ProfileRoot) {
    $path = Join-Path $ProfileRoot 'profile-owner.json'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try { $owner = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json } catch { return $null }
    if ($owner.schema -ne 'caelestia-windows-profile' -or $owner.version -ne 1 -or -not $owner.prefix) { return $null }
    return $owner
}
function Test-CaelestiaProfileEmpty([string]$ProfileRoot) {
    return -not (Test-Path -LiteralPath $ProfileRoot) -or -not (Get-ChildItem -LiteralPath $ProfileRoot -Force | Select-Object -First 1)
}
# True when every top-level entry is one this product creates.
function Test-CaelestiaProfileShape([string]$ProfileRoot) {
    foreach ($entry in Get-ChildItem -LiteralPath $ProfileRoot -Force) {
        if ($entry.Name -notin $script:CaelestiaProfileEntries) { return $false }
    }
    return $true
}
function Write-CaelestiaProfileOwner([string]$ProfileRoot, [string]$Prefix, [string]$InstallId, [bool]$Exclusive) {
    New-Item -ItemType Directory -Force -Path $ProfileRoot | Out-Null
    [ordered]@{
        schema = 'caelestia-windows-profile'; version = 1; prefix = $Prefix
        installId = $InstallId; exclusive = $Exclusive
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $ProfileRoot 'profile-owner.json') -Encoding UTF8
}

function Get-CaelestiaIntegration([string]$Prefix) {
    $default = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'Programs\caelestia-windows')).TrimEnd('\')
    $suffix = ''
    if ($Prefix -ne $default) {
        $hash = [Security.Cryptography.SHA256]::Create()
        try { $suffix = '-' + ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($Prefix.ToLowerInvariant())))).Replace('-', '').Substring(0, 12) }
        finally { $hash.Dispose() }
    }
    return @{
        RunName = "CaelestiaWindows$suffix"
        Shortcut = Join-Path ([Environment]::GetFolderPath('Programs')) "Caelestia Windows$suffix.lnk"
    }
}

# Prefix-derived key shared by the new Global lock and the legacy Local name.
function Get-CaelestiaInstallLockKey([string]$Prefix) {
    $hash = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($Prefix.ToLowerInvariant()))).Replace('-', '') }
    finally { $hash.Dispose() }
}

# One install or rollback per prefix, across every logon session: a console
# and an RDP session of the same user must not race. The prefix-derived name
# keeps unrelated installs apart. Opening a Global mutex created by another
# user can be denied; report that clearly instead of an access exception.
function New-CaelestiaInstallLock([string]$Prefix) {
    $key = Get-CaelestiaInstallLockKey $Prefix
    $globalMutex = $null
    try {
        $globalMutex = [Threading.Mutex]::new($false, 'Global\CaelestiaInstall-' + $key)
        $localMutex = [Threading.Mutex]::new($false, 'Local\CaelestiaInstall-' + $key)
    } catch [System.UnauthorizedAccessException] {
        if ($globalMutex) { $globalMutex.Dispose() }
        throw "The Caelestia installation lock for $Prefix belongs to another user. Wait for that operation to finish or choose a different prefix."
    } catch {
        if ($globalMutex) { $globalMutex.Dispose() }
        throw
    }
    return [pscustomobject]@{
        Global = $globalMutex; GlobalHeld = $false
        Local = $localMutex; LocalHeld = $false
    }
}

# Migration window: an older installed copy holds only the legacy Local name.
# Take both, always Global first and then Local, so installation, activation,
# selector writes and rollback serialize with that copy. Release in reverse.
# The Local lock can be dropped once no installed version uses it. Returns
# $null when either name is owned elsewhere; the caller reports its usual
# "already in progress" error.
function Enter-CaelestiaInstallLock([string]$Prefix) {
    $lock = New-CaelestiaInstallLock $Prefix
    try {
        try { $lock.GlobalHeld = $lock.Global.WaitOne(0) } catch [Threading.AbandonedMutexException] { $lock.GlobalHeld = $true }
        if ($lock.GlobalHeld) {
            try { $lock.LocalHeld = $lock.Local.WaitOne(0) } catch [Threading.AbandonedMutexException] { $lock.LocalHeld = $true }
        }
    } catch {
        Exit-CaelestiaInstallLock $lock
        throw
    }
    if (-not $lock.GlobalHeld -or -not $lock.LocalHeld) {
        Exit-CaelestiaInstallLock $lock
        return $null
    }
    return $lock
}

function Exit-CaelestiaInstallLock($Lock) {
    if (-not $Lock) { return }
    try {
        if ($Lock.LocalHeld) { $Lock.Local.ReleaseMutex() }
    } finally {
        $Lock.LocalHeld = $false
        try {
            if ($Lock.GlobalHeld) { $Lock.Global.ReleaseMutex() }
        } finally {
            $Lock.GlobalHeld = $false
            $Lock.Local.Dispose()
            $Lock.Global.Dispose()
        }
    }
}

. (Join-Path $PSScriptRoot 'Caelestia-Versions.ps1')
