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

# Scheme CLI revision pinned by a repository or installed payload.
function Get-CaelestiaSchemeRevision([string]$RuntimePrefix) {
    try {
        $lockPath = Join-Path $RuntimePrefix '..\sources.lock.json'
        if (Test-Path -LiteralPath (Join-Path $RuntimePrefix 'install.json')) {
            $installed = Join-Path $RuntimePrefix 'licenses\sources.lock.json'
            if (Test-Path -LiteralPath $installed -PathType Leaf) { $lockPath = $installed }
        }
        if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) { return '' }
        $lock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
        return [string]$lock.schemeCli.revision
    } catch {
        return ''
    }
}

# Generation directories are hash-derived names only. runtime.json is local
# data, so never feed an arbitrary path into a process start.
function Test-CaelestiaSchemeGeneration([string]$Generation) {
    return $Generation -match '^[a-f0-9]{16,64}(-[a-f0-9]{8})?$'
}

# One provisioning run per profile, across installer prepare, normal starts and
# repairs. The lock covers both the generation build and the atomic publish of
# runtime.json; starts take it without waiting and fall back to the fixed
# palette when another process is already provisioning.
function New-CaelestiaSchemeLock([string]$ProfileRoot) {
    $key = Get-CaelestiaInstallLockKey $ProfileRoot
    $mutex = $null
    try {
        $mutex = [Threading.Mutex]::new($false, 'Global\CaelestiaScheme-' + $key)
    } catch [System.UnauthorizedAccessException] {
        $mutex = [Threading.Mutex]::new($false, 'Local\CaelestiaScheme-' + $key)
    }
    return [pscustomobject]@{ Mutex = $mutex; Held = $false }
}

function Enter-CaelestiaSchemeLock([string]$ProfileRoot, [int]$WaitSeconds = 0) {
    $lock = New-CaelestiaSchemeLock $ProfileRoot
    try {
        try { $lock.Held = $lock.Mutex.WaitOne([Math]::Max(0, $WaitSeconds) * 1000) }
        catch [Threading.AbandonedMutexException] { $lock.Held = $true }
    } catch {
        $lock.Mutex.Dispose()
        throw
    }
    if (-not $lock.Held) {
        $lock.Mutex.Dispose()
        return $null
    }
    return $lock
}

function Exit-CaelestiaSchemeLock($Lock) {
    if (-not $Lock) { return }
    try {
        if ($Lock.Held) { $Lock.Mutex.ReleaseMutex() }
    } finally {
        $Lock.Held = $false
        $Lock.Mutex.Dispose()
    }
}

# Optional profile-local Python dependencies. The installer runs this while the
# previous shell still serves the desktop, so activation never waits for a venv,
# pip or the network. A failure is returned instead of thrown: the shell keeps
# its fixed palette and the installation remains valid. The wait is bounded and
# only used outside the readiness budget.
function Install-CaelestiaSchemeRuntime([string]$RuntimePrefix, [string]$ProfileRoot) {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $record = $null
    $message = ''
    try {
        $record = & (Join-Path $RuntimePrefix 'Install-SchemeRuntime.ps1') -ProfileRoot $ProfileRoot -LockWaitSeconds 900 |
            Select-Object -Last 1 | ConvertFrom-Json
    } catch {
        $message = $_.Exception.Message
    }
    $available = $null -ne $record -and $record.available -eq $true
    if ($available) {
        $message = 'ready'
    } elseif (-not $message) {
        $message = if ($record -and $record.message) { [string]$record.message } else { 'no provisioning result' }
    }
    return [pscustomobject]@{
        available = $available
        seconds = $clock.Elapsed.TotalSeconds
        message = $message
    }
}

# Activation reads only a completed, revision-matched generation. It never
# creates a venv or installs packages. Missing, failed or mismatched records
# start the fixed palette.
function Get-CaelestiaPreparedSchemeRuntime([string]$ProfileRoot, [string]$ExpectedRevision = '', [string]$RuntimePrefix = '') {
    try {
        $schemeRoot = [IO.Path]::GetFullPath((Join-Path $ProfileRoot 'scheme')).TrimEnd('\')
        $record = Get-Content -LiteralPath (Join-Path $schemeRoot 'runtime.json') -Raw | ConvertFrom-Json
        if ($record.available -ne $true) { return $null }
        if ($ExpectedRevision -and [string]$record.revision -ne $ExpectedRevision) { return $null }
        if (-not (Test-CaelestiaSchemeGeneration ([string]$record.generation))) { return $null }
        $runtimesRoot = [IO.Path]::GetFullPath((Join-Path $schemeRoot 'runtimes')).TrimEnd('\')
        $generationRoot = [IO.Path]::GetFullPath((Join-Path $runtimesRoot ([string]$record.generation))).TrimEnd('\')
        if (-not $generationRoot.StartsWith($runtimesRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { return $null }
        $generation = Get-Content -LiteralPath (Join-Path $generationRoot 'generation.json') -Raw | ConvertFrom-Json
        if ([string]$generation.revision -ne [string]$record.revision) { return $null }
        if ($RuntimePrefix) {
            $targetHelper = Join-Path $RuntimePrefix 'scheme\win_scheme.py'
            $targetRequirements = Join-Path $RuntimePrefix 'scheme\requirements.lock.txt'
            if (-not (Test-Path -LiteralPath $targetHelper -PathType Leaf) -or
                -not (Test-Path -LiteralPath $targetRequirements -PathType Leaf)) { return $null }
            $helperHash = (Get-FileHash -LiteralPath $targetHelper -Algorithm SHA256).Hash.ToLowerInvariant()
            $requirementsHash = (Get-FileHash -LiteralPath $targetRequirements -Algorithm SHA256).Hash.ToLowerInvariant()
            if ([string]$generation.helperSha256 -ne $helperHash -or
                [string]$generation.requirementsSha256 -ne $requirementsHash) { return $null }
        }
        foreach ($path in @([string]$record.python, [string]$record.helper)) {
            if (-not $path) { return $null }
            $full = [IO.Path]::GetFullPath($path)
            if (-not $full.StartsWith($generationRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { return $null }
            if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { return $null }
        }
        return $record
    } catch {
        return $null
    }
}

# Point runtime.json at an existing generation for the requested revision
# without provisioning. Activation calls this before the readiness clock; a
# busy lock or a missing generation returns null and the shell starts fixed.
function Set-CaelestiaSchemeRuntimeForRevision([string]$ProfileRoot, [string]$Revision, [string]$RuntimePrefix = '') {
    try {
        if (-not $Revision) { return $null }
        $expectedHelperHash = ''
        $expectedRequirementsHash = ''
        if ($RuntimePrefix) {
            $targetHelper = Join-Path $RuntimePrefix 'scheme\win_scheme.py'
            $targetRequirements = Join-Path $RuntimePrefix 'scheme\requirements.lock.txt'
            if (-not (Test-Path -LiteralPath $targetHelper -PathType Leaf) -or
                -not (Test-Path -LiteralPath $targetRequirements -PathType Leaf)) { return $null }
            $expectedHelperHash = (Get-FileHash -LiteralPath $targetHelper -Algorithm SHA256).Hash.ToLowerInvariant()
            $expectedRequirementsHash = (Get-FileHash -LiteralPath $targetRequirements -Algorithm SHA256).Hash.ToLowerInvariant()
        }
        $lock = Enter-CaelestiaSchemeLock $ProfileRoot 0
        if (-not $lock) { return $null }
        try {
            $schemeRoot = Join-Path $ProfileRoot 'scheme'
            $runtimesRoot = [IO.Path]::GetFullPath((Join-Path $schemeRoot 'runtimes')).TrimEnd('\')
            if (-not (Test-Path -LiteralPath $runtimesRoot -PathType Container)) { return $null }
            foreach ($directory in @(Get-ChildItem -LiteralPath $runtimesRoot -Directory -Force | Sort-Object Name)) {
                if ($directory.Name -like '.staging-*') { continue }
                $python = Join-Path $directory.FullName 'venv\Scripts\python.exe'
                $helper = Join-Path $directory.FullName 'win_scheme.py'
                $meta = Join-Path $directory.FullName 'generation.json'
                if (-not (Test-Path -LiteralPath $python -PathType Leaf) -or
                    -not (Test-Path -LiteralPath $helper -PathType Leaf) -or
                    -not (Test-Path -LiteralPath $meta -PathType Leaf)) { continue }
                try { $generation = Get-Content -LiteralPath $meta -Raw | ConvertFrom-Json } catch { continue }
                if ([string]$generation.revision -ne $Revision) { continue }
                if ($RuntimePrefix -and
                    ([string]$generation.helperSha256 -ne $expectedHelperHash -or
                     [string]$generation.requirementsSha256 -ne $expectedRequirementsHash)) { continue }
                $record = [ordered]@{
                    available = $true
                    revision = $Revision
                    generation = $directory.Name
                    python = $python
                    helper = $helper
                    provisionedAt = $(if ($generation.created) { [string]$generation.created } else { (Get-Date).ToString('o') })
                }
                Write-CaelestiaJsonAtomic (Join-Path $schemeRoot 'runtime.json') $record
                return [pscustomobject]$record
            }
            return $null
        } finally {
            Exit-CaelestiaSchemeLock $lock
        }
    } catch {
        return $null
    }
}

# Remove scheme generations no installed version can reference. Only run with
# no shell or supervisor alive and under the provisioning lock; deferring
# pruning to the next install is safer than deleting a generator in use.
function Remove-CaelestiaSchemeGenerations([string]$Prefix, [string]$ProfileRoot) {
    try {
        if (@(Get-CaelestiaProcesses $Prefix).Count -or @(Get-CaelestiaSupervisors $ProfileRoot).Count) { return }
        $lock = Enter-CaelestiaSchemeLock $ProfileRoot 0
        if (-not $lock) { return }
        try {
            $schemeRoot = Join-Path $ProfileRoot 'scheme'
            $runtimesRoot = [IO.Path]::GetFullPath((Join-Path $schemeRoot 'runtimes')).TrimEnd('\')
            if (-not (Test-Path -LiteralPath $runtimesRoot -PathType Container)) { return }
            # A helper can outlive its shell briefly. Never remove a generation its
            # interpreter is still running from.
            foreach ($process in @(Get-Process -Name python -ErrorAction SilentlyContinue)) {
                try {
                    if ($process.Path -and $process.Path.StartsWith($runtimesRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { return }
                } catch { }
            }
            $revisions = @{}
            $installed = @()
            try {
                $record = Read-CaelestiaInstall $Prefix
                if ($record.version -eq 2) {
                    foreach ($id in @($record.current, $record.previous)) {
                        if (-not $id) { continue }
                        try { $installed += Get-CaelestiaVersionPrefix $Prefix ([string]$id) } catch { }
                    }
                } else {
                    $installed = @($Prefix)
                }
            } catch { }
            foreach ($root in $installed) {
                try {
                    $revision = Get-CaelestiaSchemeRevision $root
                    if ($revision) { $revisions[$revision] = $true }
                } catch { }
            }
            $published = ''
            try {
                $published = [string](Get-Content -LiteralPath (Join-Path $schemeRoot 'runtime.json') -Raw | ConvertFrom-Json).generation
            } catch { }
            foreach ($directory in @(Get-ChildItem -LiteralPath $runtimesRoot -Directory -Force -ErrorAction SilentlyContinue)) {
                if ($directory.Name -eq $published) { continue }
                $generationRevision = ''
                try {
                    $generationRevision = [string](Get-Content -LiteralPath (Join-Path $directory.FullName 'generation.json') -Raw | ConvertFrom-Json).revision
                } catch { }
                if ($generationRevision -and $revisions.ContainsKey($generationRevision)) { continue }
                try {
                    $safe = Resolve-CaelestiaDirectory $directory.FullName
                    if ((Split-Path -Parent $safe) -ne $runtimesRoot) { continue }
                    Assert-CaelestiaNoReparsePoints $safe
                    Remove-Item -LiteralPath $safe -Recurse -Force
                } catch { }
            }
        } finally {
            Exit-CaelestiaSchemeLock $lock
        }
    } catch {
        # Cleanup must never fail an otherwise healthy install.
    }
}

# Keep activation diagnostics out of the shell's own stdout/stderr logs. Never
# include the profile or another user path in this file.
function Write-CaelestiaSchemeRuntimeLog([string]$ProfileRoot, [string]$Message) {
    try {
        $logs = Join-Path $ProfileRoot 'logs'
        New-Item -ItemType Directory -Force -Path $logs | Out-Null
        Add-Content -LiteralPath (Join-Path $logs 'scheme-runtime.log') `
            -Value ("{0} {1}" -f (Get-Date).ToString('o'), $Message) -Encoding UTF8
    } catch { }
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

# Readiness covers only the new shell starting. Optional provisioning must
# complete before the handoff (Install-CaelestiaSchemeRuntime), never here.
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
function New-CaelestiaLaunchTask([string]$Prefix, [switch]$PreparedSchemeRuntime, [switch]$DisableSchemeProvisioning) {
    $taskName = 'Caelestia-Start-' + [guid]::NewGuid().ToString('N')
    $launcher = Join-Path $Prefix 'Start-Caelestia.ps1'
    $launchArguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $launcher + '" -Prefix "' + $Prefix + '"'
    # Activation only consumes the scheme runtime prepared before the handoff.
    if ($PreparedSchemeRuntime) { $launchArguments += ' -PreparedSchemeRuntime' }
    elseif ($DisableSchemeProvisioning) { $launchArguments += ' -SkipSchemeRuntime' }
    $action = New-ScheduledTaskAction -Execute (Get-WindowsPowerShellPath) `
        -Argument $launchArguments `
        -WorkingDirectory $Prefix
    $principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -ErrorAction Stop | Out-Null
    return $taskName
}

function Start-CaelestiaDetached([string]$Prefix, [switch]$LegacyReady, [string]$TaskName = '', [switch]$PreparedSchemeRuntime, [switch]$DisableSchemeProvisioning) {
    if (-not $TaskName) {
        $TaskName = New-CaelestiaLaunchTask $Prefix -PreparedSchemeRuntime:$PreparedSchemeRuntime -DisableSchemeProvisioning:$DisableSchemeProvisioning
    }
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
    # This recovery path can start a pre-versioning launcher. Never let its
    # provisioner run inside the readiness clock; consume a prepared generation
    # when it supports one, otherwise disable provisioning for this start.
    $launcherText = ''
    try { $launcherText = [IO.File]::ReadAllText((Join-Path $Prefix 'Start-Caelestia.ps1')) } catch { }
    if ($launcherText -match '\[switch\]\$PreparedSchemeRuntime\b') {
        $restoreRuntime = Resolve-CaelestiaRuntimePrefix $Prefix
        $null = Set-CaelestiaSchemeRuntimeForRevision $ProfileRoot (Get-CaelestiaSchemeRevision $restoreRuntime) $restoreRuntime
        Start-CaelestiaDetached $Prefix -LegacyReady -PreparedSchemeRuntime
    } elseif ($launcherText -match '\[switch\]\$SkipSchemeRuntime\b') {
        Start-CaelestiaDetached $Prefix -LegacyReady -DisableSchemeProvisioning
    } else {
        Start-CaelestiaDetached $Prefix -LegacyReady
    }
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
