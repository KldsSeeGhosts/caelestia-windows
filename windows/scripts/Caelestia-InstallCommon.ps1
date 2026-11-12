# Shared by repository and installed scripts. No machine-wide changes.
$ErrorActionPreference = 'Stop'

# One long spelling for a path that is compared or matched. Windows can name
# the same directory with an 8.3 short name, forward slashes, a \\?\ prefix or
# a trailing separator. GetFullPath normalises the spelling and expands an
# existing 8.3 name on Windows PowerShell 5.1; Get-Item returns the long name
# even where GetFullPath leaves a short one. The path need not exist, so a
# prefix that is about to be created still resolves consistently.
function Get-CaelestiaLongPath([string]$Path) {
    if (-not $Path) { throw 'A nonempty path is required.' }
    if ($Path.StartsWith('\\?\UNC\', [StringComparison]::OrdinalIgnoreCase)) { $Path = '\\' + $Path.Substring(8) }
    elseif ($Path.StartsWith('\\?\', [StringComparison]::Ordinal) -or $Path.StartsWith('\\.\', [StringComparison]::Ordinal)) { $Path = $Path.Substring(4) }
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    if ($full.Length -gt $root.Length) { $full = $full.TrimEnd('\', '/') }
    # A volume root is already its own canonical spelling. Returning here keeps
    # root checks free of I/O, including a UNC share that does not answer.
    if ($full -eq $root) { return $full }
    try {
        $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
        if ($item.FullName) {
            $full = $item.FullName
            if ($full.Length -gt $root.Length) { $full = $full.TrimEnd('\', '/') }
        }
    } catch { }
    return $full
}

# Compare two path spellings as the same Windows location. Both sides go
# through the one normaliser above, so a short prefix, a long record path and a
# differently cased drive all name the same installation. Empty on both sides
# compares equal so optional record fields stay optional; empty on one side
# does not.
function Test-CaelestiaSamePath([string]$Left, [string]$Right) {
    if (-not $Left -or -not $Right) { return (-not $Left -and -not $Right) }
    try {
        return [string]::Equals((Get-CaelestiaLongPath $Left), (Get-CaelestiaLongPath $Right), [StringComparison]::OrdinalIgnoreCase)
    } catch {
        return $false
    }
}

function Resolve-CaelestiaDirectory([string]$Path) {
    if (-not $Path -or $Path.IndexOfAny([char[]]@('"', "`r", "`n")) -ge 0) {
        throw 'A nonempty Windows directory path is required.'
    }
    # A bare drive is drive-relative: GetFullPath resolves it against whatever
    # directory is current on that drive, which can be the volume root or any
    # user location. Refuse it before that process state is consulted.
    if ($Path -match '^[A-Za-z]:$') { throw "Unsafe directory: $Path" }
    $full = Get-CaelestiaLongPath $Path
    # Get-CaelestiaLongPath keeps the trailing separator of a volume root, so
    # compare both spellings without it. Without the trim, D:\ would pass the
    # guard and an uninstall with -Purge could remove the whole volume.
    $root = [IO.Path]::GetPathRoot($full)
    if ($root -and $full.TrimEnd('\', '/') -eq $root.TrimEnd('\', '/')) { throw "Unsafe directory: $full" }
    foreach ($protected in @($env:USERPROFILE, $env:WINDIR, $env:ProgramFiles, ${env:ProgramFiles(x86)}, $env:LOCALAPPDATA, $env:APPDATA, $env:TEMP)) {
        if (-not $protected) { continue }
        $protectedFull = Get-CaelestiaLongPath $protected
        if ($protectedFull -eq $full -or $protectedFull.StartsWith($full + '\', [StringComparison]::OrdinalIgnoreCase)) {
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
    $record = Get-Content -LiteralPath (Join-Path $Prefix 'install.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    # install.json records the prefix it was written for. A record written
    # through a long path must still be readable through a short one (and the
    # reverse), so both spellings are compared after normalisation.
    if (-not $Prefix -or -not $record.prefix -or $record.product -ne 'caelestia-windows' -or
        $record.version -notin @(1, 2) -or -not (Test-CaelestiaSamePath $record.prefix $Prefix)) {
        throw "Not a recognized Caelestia installation: $Prefix"
    }
    if ($record.version -eq 2) {
        Assert-CaelestiaVersionId ([string]$record.current)
        if ($record.previous) { Assert-CaelestiaVersionId ([string]$record.previous) }
    }
    return $record
}

function Get-CaelestiaProcesses([string]$Prefix) {
    $exe = Get-CaelestiaLongPath (Join-Path $Prefix 'qs.exe')
    $versions = Get-CaelestiaLongPath (Join-Path $Prefix 'versions')
    return @(Get-Process -Name qs -ErrorAction SilentlyContinue | Where-Object {
        try {
            if (-not $_.Path) { return $false }
            # Process.Path is normally long, but the prefix passed here may be
            # short. Normalise both before deciding ownership.
            $path = Get-CaelestiaLongPath $_.Path
            $path -eq $exe -or [IO.Path]::GetDirectoryName([IO.Path]::GetDirectoryName($path)) -eq $versions
        } catch {
            $false
        }
    })
}

# Capture hosts shipped inside version payloads, including the legacy name.
# Both the image path and version root prove ownership, so other-prefix hosts are
# never touched.
function Get-CaelestiaHostProcesses([string]$Prefix, [string]$VersionRoot = '') {
    $root = $(if ($VersionRoot) { $VersionRoot } else { Join-Path $Prefix 'versions' })
    $versions = (Get-CaelestiaLongPath $root) + '\'
    return @(Get-Process -Name caelestia-capture, glazier -ErrorAction SilentlyContinue | Where-Object {
        try {
            $_.Path -and (Get-CaelestiaLongPath $_.Path).StartsWith($versions, [StringComparison]::OrdinalIgnoreCase)
        } catch {
            $false
        }
    })
}

# Ask each payload host to exit through its own tray window (taskkill without
# /F posts WM_CLOSE, it does not kill), then wait before a payload swap,
# cleanup or uninstall. A VersionRoot limits the stop to one payload.
function Stop-CaelestiaHosts([string]$Prefix, [string]$VersionRoot = '', [int]$TimeoutSeconds = 10) {
    $hosts = @(Get-CaelestiaHostProcesses $Prefix $VersionRoot)
    if ($hosts.Count -eq 0) { return }
    foreach ($hostProcess in $hosts) {
        & taskkill.exe /PID $hostProcess.Id 2>&1 | Out-Null
    }
    foreach ($hostProcess in $hosts) {
        if (-not $hostProcess.WaitForExit($TimeoutSeconds * 1000)) {
            throw "A capture host is still running from the Caelestia install. Quit it and retry."
        }
    }
}

# Live desktop supervisors recorded under the profile. Starting and backoff
# can have no qs.exe; waiting-ready retains a live child. All own prefix files.
function Read-CaelestiaSupervisorStatus([string]$Path) {
    for ($attempt = 0; ; $attempt++) {
        try { return ([IO.File]::ReadAllText($Path) | ConvertFrom-Json) }
        catch {
            if ($attempt -ge 4 -or $_.Exception.InnerException -isnot [IO.IOException]) { throw }
            Start-Sleep -Milliseconds (25 * [Math]::Pow(2, $attempt))
        }
    }
}

function Get-CaelestiaSupervisors([string]$ProfileRoot) {
    $found = @()
    if (-not $ProfileRoot) { return $found }
    foreach ($file in @(Get-ChildItem -Path (Join-Path $ProfileRoot 'runtime\supervisor-*\watchdog.json') -ErrorAction SilentlyContinue)) {
        $status = $null
        try { $status = Read-CaelestiaSupervisorStatus $file.FullName } catch { continue }
        if (-not $status -or $status.phase -notin @('starting', 'waiting-ready', 'running', 'frozen', 'restart-backoff', 'restoring')) { continue }
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

# Forced recovery is stricter than discovery. Fail closed if command line,
# session, owner SID or process identity cannot be verified.
function Stop-CaelestiaSupervisor($Supervisor, [int]$RecoveryTimeoutMs = 60000) {
    $process = $Supervisor.Process
    if ($process.HasExited) { return }
    $spec = Join-Path (Split-Path -Parent $Supervisor.StatusPath) 'launch.json'
    $native = Get-CimInstance Win32_Process -Filter "ProcessId = $($process.Id)" -OperationTimeoutSec 5 -ErrorAction Stop
    if ($process.HasExited) { return }
    $owner = Invoke-CimMethod -InputObject $native -MethodName GetOwnerSid -OperationTimeoutSec 5 -ErrorAction Stop
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $argument = '(?i)(?:^|\s)-LaunchSpec\s+(?:"' + [regex]::Escape($spec) + '"|' + [regex]::Escape($spec) + '(?=\s|$))'
    if ($process.SessionId -ne [Diagnostics.Process]::GetCurrentProcess().SessionId -or
        $owner.ReturnValue -ne 0 -or $owner.Sid -ne $sid -or
        $native.CommandLine -notmatch $argument -or
        $native.CommandLine -notmatch '(?i)[\\/]Watch-DesktopShell\.ps1"' -or
        [Math]::Abs(($native.CreationDate.ToUniversalTime() - $process.StartTime.ToUniversalTime()).TotalMilliseconds) -gt 1) {
        throw 'Refusing forced recovery of an unverified desktop supervisor.'
    }
    if (-not ('Caelestia.Takeover.Supervisor' -as [type])) {
        Add-Type -Path (Join-Path $PSScriptRoot 'DesktopTakeover.cs') -ReferencedAssemblies System.Windows.Forms, System.Web.Extensions
    }
    try { [Caelestia.Takeover.Supervisor]::RecoverActive($RecoveryTimeoutMs) }
    catch {
        if ($_.Exception.InnerException -isnot [InvalidOperationException] -or
            $_.Exception.InnerException.Message -ne 'Supervisor has not stopped. Retry recovery after it exits.') { throw }
        if (-not $process.HasExited) {
            # Retain handles before killing the parent. Never kill by name or
            # trust shellPid alone, which can refer to a recycled PID.
            $status = Read-CaelestiaSupervisorStatus $Supervisor.StatusPath
            $launch = Get-Content -LiteralPath $spec -Raw | ConvertFrom-Json
            $child = $null
            if ($status.shellPid) {
                $candidate = Get-Process -Id $status.shellPid -ErrorAction SilentlyContinue
                if ($candidate) {
                    $childInfo = Get-CimInstance Win32_Process -Filter "ProcessId = $($candidate.Id)" -OperationTimeoutSec 5 -ErrorAction Stop
                    if ($childInfo.ParentProcessId -eq $process.Id -and
                        $candidate.SessionId -eq $process.SessionId -and
                        $candidate.StartTime -ge $process.StartTime -and
                        (Test-CaelestiaSamePath $candidate.Path $launch.Executable)) {
                        $null = $candidate.Handle
                        $childOwner = Invoke-CimMethod -InputObject $childInfo -MethodName GetOwnerSid -OperationTimeoutSec 5 -ErrorAction Stop
                        if ($childOwner.ReturnValue -eq 0 -and $childOwner.Sid -eq $sid) { $child = $candidate }
                    }
                }
            }
            $process.Kill()
            if (-not $process.WaitForExit(2000)) { throw 'Forced desktop supervisor stop timed out.' }
            if ($child -and -not $child.HasExited) {
                $child.Kill()
                if (-not $child.WaitForExit(2000)) { throw 'Forced owned shell stop timed out.' }
            }
        }
    }
    if (-not $process.WaitForExit(2000)) { throw 'Desktop supervisor exit timed out.' }
}

function Repair-CaelestiaStaleSupervisors([string]$ProfileRoot) {
    foreach ($supervisor in @(Get-CaelestiaSupervisors $ProfileRoot)) {
        # Starting includes 45 s banner recovery and up to 20 s for first frames,
        # within the launcher's 75 s allowance. Running and waiting-ready owners
        # publish a heartbeat every second. Allow several missed beats before
        # taking over. A supervisor from before heartbeats wrote utc once, so
        # its age proves nothing; leave it alone.
        $limit = if ($supervisor.Phase -in @('starting', 'restoring')) { 75 } else { 5 }
        $status = Read-CaelestiaSupervisorStatus $supervisor.StatusPath
        if (-not $status.utc -or -not $status.heartbeat) { continue }
        $deadline = [DateTimeOffset]::Parse($status.utc).UtcDateTime.AddSeconds($limit)
        $latest = $status
        while (-not $supervisor.Process.HasExited -and $latest.utc -eq $status.utc -and [DateTime]::UtcNow -lt $deadline) {
            Start-Sleep -Milliseconds 100
            $latest = Read-CaelestiaSupervisorStatus $supervisor.StatusPath
        }
        if ($supervisor.Process.HasExited) { continue }
        if ($latest.utc -eq $status.utc) { Stop-CaelestiaSupervisor $supervisor }
    }
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
                $status = Get-Content -LiteralPath $statusFile -Raw -Encoding UTF8 | ConvertFrom-Json
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
        $lock = Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8 | ConvertFrom-Json
        return [string]$lock.schemeCli.revision
    } catch {
        return ''
    }
}

# Total time one generation search may spend probing candidates, and the slice
# one candidate gets. Tests shrink these; nothing else should. Activation can
# run two searches before it stops the old shell: the target's generation and,
# when there is a previous version, the restore generation. Each search has its
# own budget, so the combined pre-quit work can take up to about 30 s.
$script:CaelestiaSchemeProbeBudgetSeconds = 15
$script:CaelestiaSchemeProbeSliceSeconds = 8
$script:CaelestiaSchemeRestoreJournalName = 'prune-restore.json'

# Generation directories are hash-derived names only. runtime.json is local
# data, so never feed an arbitrary path into a process start.
function Test-CaelestiaSchemeGeneration([string]$Generation) {
    return $Generation -match '^[a-f0-9]{16,64}(-[a-f0-9]{8})?$'
}

# One stable spelling for a directory so that every spelling of the same
# directory (trailing separators, forward slashes, \\?\ prefix, 8.3 short
# names, letter case) names the same lock. The directory need not exist.
function Get-CaelestiaCanonicalPath([string]$Path) {
    $full = Get-CaelestiaLongPath $Path
    $root = [IO.Path]::GetPathRoot($full)
    if ($full.IndexOf('~') -ge 0 -and $full.Length -gt $root.Length) {
        # A directory pattern also matches 8.3 names and returns the long name.
        # This covers an intermediate segment that Get-Item could not resolve
        # because the full directory does not exist yet.
        $current = $root
        foreach ($segment in $full.Substring($root.Length).TrimStart('\').Split('\')) {
            if ($segment.IndexOf('~') -ge 0) {
                try {
                    $match = @([IO.Directory]::GetFileSystemEntries($current, $segment))
                    if ($match.Count -eq 1) { $segment = [IO.Path]::GetFileName($match[0]) }
                } catch { }
            }
            $current = Join-Path $current $segment
        }
        $full = $current
    }
    return $full.ToLowerInvariant()
}

# Hash of every input that goes into a scheme runtime generation, in one place
# so the provisioner, the cache check, the repoint and activation all compare
# the same freshly computed identity: the pinned CLI revision, the lock file,
# the helper and the fcntl shim copied into the venv.
function Get-CaelestiaSchemeIdentity([string]$RuntimePrefix, [string]$Revision) {
    try {
        $directory = Join-Path $RuntimePrefix 'scheme'
        $hashes = @{}
        $material = [Text.StringBuilder]::new()
        $null = $material.Append($Revision)
        foreach ($name in @('requirements.lock.txt', 'win_scheme.py', 'fcntl.py')) {
            $path = Join-Path $directory $name
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
            $hashes[$name] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
            $null = $material.Append("`n$name=").Append($hashes[$name])
        }
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $id = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($material.ToString())))).Replace('-', '').ToLowerInvariant()
        } finally { $sha.Dispose() }
        return [pscustomobject]@{
            Id = $id
            Revision = $Revision
            RequirementsSha256 = $hashes['requirements.lock.txt']
            HelperSha256 = $hashes['win_scheme.py']
            ShimSha256 = $hashes['fcntl.py']
        }
    } catch {
        return $null
    }
}

# Diagnostics must not carry machine paths. Redaction is by shape, not by a list
# of known prefixes, and prefers over-redacting to leaking:
#   - inside a quoted string holding an absolute Windows path (drive, UNC,
#     \\?\ or a file URL) the whole quoted text is replaced;
#   - an unquoted absolute path is replaced through the end of the line, or up
#     to the next double quote, or a single quote, pipe, semicolon or comma that
#     is followed by whitespace, so file names with spaces cannot leak.
# Only a short leaf extension survives, as <path>.ext.
function Protect-CaelestiaText([string]$Text) {
    if (-not $Text) { return '' }
    $start = '(?:file:/{1,3}|\\\\\?\\(?:UNC\\|[A-Za-z]:[\\/]+)?|(?<![\\\w])\\{2,4}[^\\/\s"''<>|?*:]+[\\/]|(?<![A-Za-z0-9])[A-Za-z]:[\\/]+)'
    $extension = { param($value) $m = [regex]::Match($value, '\.[A-Za-z0-9]{1,8}$'); return $m.Value }
    $quoted = {
        param($match)
        if ($match.Groups[2].Value -notmatch $start) { return $match.Value }
        $q = $match.Groups[1].Value
        return $q + '<path>' + (& $extension $match.Groups[2].Value) + $q
    }.GetNewClosure()
    $clean = $Text
    # A single quote inside a word (Bob's) is an apostrophe, not a delimiter.
    foreach ($pattern in @('(")([^"\r\n]*)"', '(?<!\w)('')((?:[^''\r\n]|''(?=\w))*)''(?!\w)')) {
        $clean = [regex]::Replace($clean, $pattern, $quoted)
    }
    $unquoted = $start + '[^\r\n]*?(?=$|"|[''|;,](?:\s|$)|\r|\n)'
    return [regex]::Replace($clean, $unquoted, {
        param($match)
        if ($match.Value.StartsWith('file:', [StringComparison]::OrdinalIgnoreCase)) { return '<file-url>' }
        return '<path>' + (& $extension $match.Value)
    }.GetNewClosure(), 'IgnoreCase, Multiline')
}

# Run a program with a hard time limit and no window. A timeout kills the whole
# tree and returns $null; it bounds a hung interpreter and never waits for
# another process. Output is returned only for callers that need to parse it.
function Invoke-CaelestiaBounded([string]$File, [string]$Arguments, [int]$TimeoutSeconds, [string]$WorkingDirectory = '') {
    $process = $null
    try {
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = $File
        $info.Arguments = $Arguments
        # Never run from inside a generation: a cwd there would block pruning.
        $info.WorkingDirectory = $(if ($WorkingDirectory) { $WorkingDirectory } else { $env:SystemRoot })
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $info.EnvironmentVariables['PYTHONDONTWRITEBYTECODE'] = '1'
        $process = [Diagnostics.Process]::Start($info)
        $outTask = $process.StandardOutput.ReadToEndAsync()
        $null = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { & taskkill.exe /PID $process.Id /T /F 2>&1 | Out-Null } catch { }
            try { $process.Kill() } catch { }
            return $null
        }
        $process.WaitForExit()
        return [pscustomobject]@{ ExitCode = $process.ExitCode; Output = $outTask.GetAwaiter().GetResult() }
    } catch {
        return $null
    } finally {
        if ($process) { $process.Dispose() }
    }
}

# The system Python a bridge may need when no scheme runtime exists (Wallpaper
# Engine discovery uses only the standard library). Resolved ONLY while
# preparing, under a time limit; activation reads it from runtime.json and
# never starts Python itself.
function Resolve-CaelestiaSystemPython([int]$TimeoutSeconds = 15) {
    $launcher = Get-Command py.exe -ErrorAction SilentlyContinue
    if (-not $launcher) { return '' }
    # Discovery must never activate an App Execution Alias or an install
    # manager. Only the classic, already-installed launcher is supported by
    # the optional provisioner. A refusal is caught by Start/installer callers
    # and leaves the basic shell on its fixed palette.
    $item = Get-Item -LiteralPath $launcher.Source -Force -ErrorAction Stop
    if ($launcher.CommandType -ne 'Application' -or
        $launcher.Source -match '(?i)[\\/]WindowsApps[\\/]' -or
        ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
        $item.VersionInfo.FileDescription -ne 'Python Launcher' -or
        $env:PYLAUNCHER_ALLOW_INSTALL) {
        throw 'Optional scheme preparation requires an installed classic Python launcher with automatic installation disabled; no Python launcher was executed.'
    }
    $result = Invoke-CaelestiaBounded $launcher.Source '-3 -c "import sys; print(sys.executable)"' $TimeoutSeconds
    if (-not $result -or $result.ExitCode -ne 0) { return '' }
    $line = @($result.Output -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
    if ($line.Count -and [IO.Path]::IsPathRooted($line[0].Trim()) -and (Test-Path -LiteralPath $line[0].Trim() -PathType Leaf)) {
        return $line[0].Trim()
    }
    return ''
}

function Read-CaelestiaSchemeRuntimeRecord([string]$ProfileRoot) {
    try { return (Get-Content -LiteralPath (Join-Path (Join-Path $ProfileRoot 'scheme') 'runtime.json') -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

# File metadata only: no process is started. Empty when nothing was recorded.
function Get-CaelestiaSchemeInterpreter([string]$ProfileRoot) {
    $record = Read-CaelestiaSchemeRuntimeRecord $ProfileRoot
    if (-not $record) { return '' }
    $path = [string]$record.interpreter
    if ($path -and [IO.Path]::IsPathRooted($path) -and (Test-Path -LiteralPath $path -PathType Leaf)) { return $path }
    return ''
}

# runtime.json is written only through here, so the discovered interpreter is
# carried across every publish and revocation.
function Write-CaelestiaSchemeRecord([string]$ProfileRoot, $Record) {
    if (-not $Record.Contains('interpreter')) {
        $existing = Read-CaelestiaSchemeRuntimeRecord $ProfileRoot
        if ($existing -and [string]$existing.interpreter) { $Record['interpreter'] = [string]$existing.interpreter }
    }
    Write-CaelestiaJsonAtomic (Join-Path (Join-Path $ProfileRoot 'scheme') 'runtime.json') $Record
}

function Set-CaelestiaSchemeInterpreter([string]$ProfileRoot, [string]$Interpreter) {
    $record = [ordered]@{ available = $false; message = 'no verified scheme runtime yet' }
    $existing = Read-CaelestiaSchemeRuntimeRecord $ProfileRoot
    if ($existing) {
        $record = [ordered]@{}
        foreach ($property in $existing.PSObject.Properties) { $record[$property.Name] = $property.Value }
    }
    $record['interpreter'] = $Interpreter
    Write-CaelestiaSchemeRecord $ProfileRoot $record
}

# A venv is only usable while the interpreter it was created from still
# exists: its python.exe is a launcher that follows pyvenv.cfg's home.
function Get-CaelestiaSchemeBaseInterpreter([string]$GenerationRoot) {
    $config = Join-Path (Join-Path $GenerationRoot 'venv') 'pyvenv.cfg'
    if (-not (Test-Path -LiteralPath $config -PathType Leaf)) { return $null }
    foreach ($line in [IO.File]::ReadAllLines($config)) {
        if ($line -match '^\s*home\s*=\s*(.+?)\s*$') {
            $base = Join-Path $Matches[1] 'python.exe'
            if (Test-Path -LiteralPath $base -PathType Leaf) { return (Get-Item -LiteralPath $base -Force) }
            return $null
        }
    }
    return $null
}

function Test-CaelestiaSchemeBase([string]$GenerationRoot) {
    try {
        if (-not (Test-Path -LiteralPath (Join-Path $GenerationRoot 'venv\Scripts\python.exe') -PathType Leaf) -or
            -not (Test-Path -LiteralPath (Join-Path $GenerationRoot 'win_scheme.py') -PathType Leaf) -or
            -not (Test-Path -LiteralPath (Join-Path $GenerationRoot 'generation.json') -PathType Leaf)) { return $false }
        return $null -ne (Get-CaelestiaSchemeBaseInterpreter $GenerationRoot)
    } catch {
        return $false
    }
}

# Receipt of a passed health probe: what the probe depended on, as cheap file
# metadata. Activation re-reads these and starts no process.
function Get-CaelestiaSchemeFingerprint([string]$GenerationRoot) {
    try {
        $base = Get-CaelestiaSchemeBaseInterpreter $GenerationRoot
        if (-not $base) { return $null }
        return [ordered]@{
            generation = (Split-Path -Leaf $GenerationRoot)
            baseInterpreter = $base.FullName
            baseSize = [string]$base.Length
            baseWriteUtc = [string]$base.LastWriteTimeUtc.Ticks
            # python3.dll and python3XX.dll next to the base executable are what
            # it actually loads; replacing one must invalidate the receipt.
            runtimeDlls = (@(Get-ChildItem -LiteralPath $base.DirectoryName -File -Force |
                Where-Object { $_.Name -match '^python3\d*\.dll$' } | Sort-Object Name |
                ForEach-Object { '{0}|{1}|{2}' -f $_.Name.ToLowerInvariant(), $_.Length, $_.LastWriteTimeUtc.Ticks }) -join ';')
            pyvenvSha256 = (Get-FileHash -LiteralPath (Join-Path (Join-Path $GenerationRoot 'venv') 'pyvenv.cfg') -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    } catch {
        return $null
    }
}

function Test-CaelestiaSchemeReceipt([string]$GenerationRoot, $Receipt) {
    if (-not $Receipt) { return $false }
    $fresh = Get-CaelestiaSchemeFingerprint $GenerationRoot
    if (-not $fresh) { return $false }
    foreach ($key in $fresh.Keys) {
        if ([string]$Receipt.$key -ne [string]$fresh[$key]) { return $false }
    }
    return $true
}

# Full health: the base interpreter exists and the venv's python really runs
# and imports the scheme packages. The timeout is a failure bound for a hung
# interpreter, never a wait for another process. Run it outside the readiness
# clock only.
function Test-CaelestiaSchemeHealth([string]$GenerationRoot, [int]$TimeoutSeconds = 15) {
    if (-not (Test-CaelestiaSchemeBase $GenerationRoot)) { return $false }
    $result = Invoke-CaelestiaBounded (Join-Path $GenerationRoot 'venv\Scripts\python.exe') '-I -c "import materialyoucolor, PIL, caelestia"' $TimeoutSeconds
    return $null -ne $result -and $result.ExitCode -eq 0
}

# One provisioning run per profile, across installer prepare, normal starts and
# repairs. The lock covers both the generation build and the atomic publish of
# runtime.json; starts take it without waiting and fall back to the fixed
# palette when another process is already provisioning.
function New-CaelestiaSchemeLock([string]$ProfileRoot) {
    $key = Get-CaelestiaInstallLockKey (Get-CaelestiaCanonicalPath $ProfileRoot)
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
        $message = Protect-CaelestiaText $_.Exception.Message
    }
    $available = $null -ne $record -and $record.available -eq $true
    if ($available) {
        $message = 'ready'
    } elseif (-not $message) {
        $message = if ($record -and $record.message) { Protect-CaelestiaText ([string]$record.message) } else { 'no provisioning result' }
    }
    return [pscustomobject]@{
        available = $available
        seconds = $clock.Elapsed.TotalSeconds
        message = $message
    }
}

# Activation reads only a completed generation whose recorded identity matches
# the identity freshly computed from this payload's inputs, and whose
# verification receipt still matches the files it was issued for. It never
# creates a venv or installs packages and it starts no process, because it runs
# inside the readiness clock: health is checked by repoint and by a normal
# start (-Verify), outside it. A missing, failed, rejected or mismatched record
# starts the fixed palette.
function Get-CaelestiaPreparedSchemeRuntime([string]$ProfileRoot, [string]$ExpectedRevision = '', [string]$RuntimePrefix = '', [switch]$Verify) {
    try {
        $schemeRoot = [IO.Path]::GetFullPath((Join-Path $ProfileRoot 'scheme')).TrimEnd('\')
        $record = Get-Content -LiteralPath (Join-Path $schemeRoot 'runtime.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($record.available -ne $true) { return $null }
        if ($ExpectedRevision -and [string]$record.revision -ne $ExpectedRevision) { return $null }
        if (-not (Test-CaelestiaSchemeGeneration ([string]$record.generation))) { return $null }
        $runtimesRoot = [IO.Path]::GetFullPath((Join-Path $schemeRoot 'runtimes')).TrimEnd('\')
        $generationRoot = [IO.Path]::GetFullPath((Join-Path $runtimesRoot ([string]$record.generation))).TrimEnd('\')
        if (-not $generationRoot.StartsWith($runtimesRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { return $null }
        $generation = Get-Content -LiteralPath (Join-Path $generationRoot 'generation.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        if ([string]$generation.revision -ne [string]$record.revision -or
            [string]$generation.generation -ne [string]$record.generation) { return $null }
        if ($RuntimePrefix) {
            $identity = Get-CaelestiaSchemeIdentity $RuntimePrefix ([string]$record.revision)
            if (-not $identity -or [string]$generation.identity -ne $identity.Id) { return $null }
        }
        foreach ($path in @([string]$record.python, [string]$record.helper)) {
            if (-not $path) { return $null }
            $full = [IO.Path]::GetFullPath($path)
            if (-not $full.StartsWith($generationRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { return $null }
            if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { return $null }
        }
        if (-not (Test-CaelestiaSchemeBase $generationRoot)) { return $null }
        if (-not (Test-CaelestiaSchemeReceipt $generationRoot $record.verification)) { return $null }
        if ($Verify -and -not (Test-CaelestiaSchemeHealth $generationRoot)) {
            Revoke-CaelestiaSchemeGeneration $ProfileRoot ([string]$record.generation) 'the health check failed'
            return $null
        }
        return $record
    } catch {
        return $null
    }
}

# Replace the published record with an "unavailable" one when its generation
# fails a check, so a rejected generation can never be activated. Call with the
# lock held (-Locked), or without it to take the lock without waiting.
function Revoke-CaelestiaSchemeGeneration([string]$ProfileRoot, [string]$Generation, [string]$Reason, [switch]$Locked) {
    try {
        $lock = $null
        if (-not $Locked) {
            $lock = Enter-CaelestiaSchemeLock $ProfileRoot 0
            if (-not $lock) { return }
        }
        try {
            $current = Read-CaelestiaSchemeRuntimeRecord $ProfileRoot
            if ($current -and $current.available -eq $true -and [string]$current.generation -eq $Generation) {
                Write-CaelestiaSchemeRecord $ProfileRoot ([ordered]@{
                    available = $false
                    revision = [string]$current.revision
                    generation = $Generation
                    message = $Reason
                    rejectedAt = (Get-Date).ToString('o')
                })
            }
        } finally {
            if ($lock) { Exit-CaelestiaSchemeLock $lock }
        }
    } catch { }
}

# The newest verified generation built from exactly this identity (and CLI
# revision), or $null. Unverified generations are never candidates, and a
# candidate that fails its check is revoked if it is the published one. Call
# under the scheme lock and outside the readiness clock: it runs the venv's
# python.
function Get-CaelestiaVerifiedSchemeGeneration([string]$ProfileRoot, [string]$Revision, [string]$IdentityId = '', [int]$BudgetSeconds = $script:CaelestiaSchemeProbeBudgetSeconds, [int]$CandidateSeconds = $script:CaelestiaSchemeProbeSliceSeconds) {
    $runtimesRoot = [IO.Path]::GetFullPath((Join-Path (Join-Path $ProfileRoot 'scheme') 'runtimes')).TrimEnd('\')
    if (-not (Test-Path -LiteralPath $runtimesRoot -PathType Container)) { return $null }
    $candidates = @()
    foreach ($directory in @(Get-ChildItem -LiteralPath $runtimesRoot -Directory -Force)) {
        if (-not (Test-CaelestiaSchemeGeneration $directory.Name)) { continue }
        try { $generation = Get-Content -LiteralPath (Join-Path $directory.FullName 'generation.json') -Raw -Encoding UTF8 | ConvertFrom-Json } catch { continue }
        if ([string]$generation.revision -ne $Revision -or [string]$generation.generation -ne $directory.Name) { continue }
        if ($IdentityId -and [string]$generation.identity -ne $IdentityId) { continue }
        $candidates += [pscustomobject]@{ Directory = $directory; Meta = $generation; Created = $directory.CreationTimeUtc; Name = $directory.Name }
    }
    # One budget covers every candidate (newest first), and each probe gets only
    # a slice of it, so a hung generation cannot starve a healthy fallback and
    # several hung ones cannot add up to a long outage. Candidates left
    # unprobed when the budget ends are neither used nor revoked.
    $clock = [Diagnostics.Stopwatch]::StartNew()
    foreach ($candidate in @($candidates | Sort-Object -Property @{ Expression = { $_.Created }; Descending = $true }, @{ Expression = { $_.Name }; Descending = $true })) {
        $remaining = $BudgetSeconds - $clock.Elapsed.TotalSeconds
        if ($remaining -lt 1) { break }
        $limit = [int][Math]::Ceiling([Math]::Min($CandidateSeconds, $remaining))
        if (Test-CaelestiaSchemeHealth $candidate.Directory.FullName $limit) { return $candidate }
        Revoke-CaelestiaSchemeGeneration $ProfileRoot $candidate.Name 'the health check failed' -Locked
    }
    return $null
}

# Publish a generation that has just passed its health probe, with the receipt
# activation will check. Rewrites runtime.json only when something changed.
# Call under the scheme lock.
function Publish-CaelestiaSchemeRuntime([string]$ProfileRoot, [string]$Revision, [string]$GenerationRoot) {
    $receipt = Get-CaelestiaSchemeFingerprint $GenerationRoot
    if (-not $receipt) { return $null }
    $created = ''
    try { $created = [string](Get-Content -LiteralPath (Join-Path $GenerationRoot 'generation.json') -Raw -Encoding UTF8 | ConvertFrom-Json).created } catch { }
    $record = [ordered]@{
        available = $true
        revision = $Revision
        generation = $receipt.generation
        python = Join-Path $GenerationRoot 'venv\Scripts\python.exe'
        helper = Join-Path $GenerationRoot 'win_scheme.py'
        provisionedAt = $(if ($created) { $created } else { (Get-Date).ToString('o') })
        verification = $receipt
    }
    $current = Read-CaelestiaSchemeRuntimeRecord $ProfileRoot
    $same = $current -and $current.available -eq $true -and [string]$current.generation -eq $receipt.generation -and
        [string]$current.revision -eq $Revision -and (Test-CaelestiaSchemeReceipt $GenerationRoot $current.verification)
    if (-not $same) { Write-CaelestiaSchemeRecord $ProfileRoot $record }
    return [pscustomobject]$record
}

# Record the final "no usable generation" outcome for a revision. An existing
# unavailable record is kept as it is: it may already carry the rejected
# generation and the reason, which is better diagnostics than replacing it.
# This starts no process.
function Set-CaelestiaSchemeUnavailableRecord([string]$ProfileRoot, [string]$Revision) {
    $current = Read-CaelestiaSchemeRuntimeRecord $ProfileRoot
    if ($current -and $current.available -eq $false -and [string]$current.revision -eq $Revision) { return }
    Write-CaelestiaSchemeRecord $ProfileRoot ([ordered]@{
        available = $false
        revision = $Revision
        message = 'no verified scheme runtime for this version; using the fixed palette'
        decidedAt = (Get-Date).ToString('o')
    })
}

# Point runtime.json at an existing generation for the requested revision
# without provisioning and without starting a process. Every caller runs after
# the shell has been stopped, so this setter is deliberately incapable of
# probing: a decision made earlier while the old shell still served the desktop
# is passed in -Verified. Without one, the published record is kept only if its
# receipt still matches (file metadata alone); otherwise the shell starts on its
# fixed palette. Selection before the stop is Select-CaelestiaSchemeGeneration.
function Set-CaelestiaSchemeRuntimeForRevision([string]$ProfileRoot, [string]$Revision, [string]$RuntimePrefix = '', $Verified = $null) {
    try {
        if (-not $Revision) { return $null }
        $expectedIdentity = ''
        if ($RuntimePrefix) {
            $identity = Get-CaelestiaSchemeIdentity $RuntimePrefix $Revision
            if (-not $identity) { return $null }
            $expectedIdentity = $identity.Id
        }
        $lock = Enter-CaelestiaSchemeLock $ProfileRoot 0
        if (-not $lock) { return $null }
        try {
            # A selection made earlier, while the old shell still served the
            # desktop, is final. Its generation is published without another
            # probe as long as its receipt still matches. If it found nothing
            # usable, or the receipt changed since, the record is replaced with
            # an "unavailable" one and the shell starts on its fixed palette:
            # nothing is probed after the shell has stopped.
            if ($Verified) {
                if ($Verified.Root -and $Verified.Revision -eq $Revision -and $Verified.IdentityId -eq $expectedIdentity -and
                    (Test-CaelestiaSchemeReceipt $Verified.Root $Verified.Receipt)) {
                    return Publish-CaelestiaSchemeRuntime $ProfileRoot $Revision $Verified.Root
                }
                Set-CaelestiaSchemeUnavailableRecord $ProfileRoot $Revision
                return $null
            }
            $accepted = Get-CaelestiaPreparedSchemeRuntime $ProfileRoot $Revision $RuntimePrefix
            if ($accepted) { return $accepted }
            Set-CaelestiaSchemeUnavailableRecord $ProfileRoot $Revision
            return $null
        } finally {
            Exit-CaelestiaSchemeLock $lock
        }
    } catch {
        return $null
    }
}

# Pick and verify the generation for a revision without publishing it. Callers
# run this before stopping the running shell, so the (bounded) probes cost no
# outage, and then hand the result to Set-CaelestiaSchemeRuntimeForRevision.
function Select-CaelestiaSchemeGeneration([string]$ProfileRoot, [string]$Revision, [string]$RuntimePrefix = '', [int]$BudgetSeconds = $script:CaelestiaSchemeProbeBudgetSeconds, [int]$CandidateSeconds = $script:CaelestiaSchemeProbeSliceSeconds) {
    try {
        if (-not $Revision) { return $null }
        $expectedIdentity = ''
        if ($RuntimePrefix) {
            $identity = Get-CaelestiaSchemeIdentity $RuntimePrefix $Revision
            if (-not $identity) { return $null }
            $expectedIdentity = $identity.Id
        }
        # Root stays $null when nothing usable was found (or the lock was busy
        # or a step failed): the decision is still final, see
        # Set-CaelestiaSchemeRuntimeForRevision -Verified.
        $decision = [pscustomobject]@{ Revision = $Revision; IdentityId = $expectedIdentity; Root = $null; Receipt = $null }
        try {
            $lock = Enter-CaelestiaSchemeLock $ProfileRoot 0
            if (-not $lock) { return $decision }
            try {
                $candidate = Get-CaelestiaVerifiedSchemeGeneration $ProfileRoot $Revision $expectedIdentity $BudgetSeconds $CandidateSeconds
                if ($candidate) {
                    $decision.Root = $candidate.Directory.FullName
                    $decision.Receipt = Get-CaelestiaSchemeFingerprint $decision.Root
                }
            } finally {
                Exit-CaelestiaSchemeLock $lock
            }
        } catch { }
        return $decision
    } catch {
        return $null
    }
}

# The decision for the version a failed activation would fall back to, taken
# before the running shell is stopped so recovery never has to probe. It is the
# target's own decision when both use the same inputs.
function Select-CaelestiaRestoreScheme([string]$ProfileRoot, [string]$RestorePrefix, $TargetDecision) {
    try {
        $revision = Get-CaelestiaSchemeRevision $RestorePrefix
        if (-not $revision) { return $null }
        $identity = Get-CaelestiaSchemeIdentity $RestorePrefix $revision
        if (-not $identity) { return $null }
        if ($TargetDecision -and $TargetDecision.Revision -eq $revision -and $TargetDecision.IdentityId -eq $identity.Id) { return $TargetDecision }
        return Select-CaelestiaSchemeGeneration $ProfileRoot $revision $RestorePrefix
    } catch {
        return $null
    }
}

# Paths of every image a process has mapped: its executable and loaded modules.
# Throws when they cannot be read. A function of its own so tests can inject
# failures.
function Get-CaelestiaProcessImagePaths($Process) {
    $paths = @($Process.Path)
    foreach ($module in $Process.Modules) { $paths += $module.FileName }
    return @($paths | Where-Object { $_ })
}

# Open every executable image under a directory for write, sharing only read
# and delete. The OS refuses write access to a mapped image, so success proves
# no process maps one; while the handles stay open no new mapping or launch of
# those files can succeed either. The read-only attribute also denies that
# write open, but it does not mean the image is in use, so it is cleared only
# for the attempt and put straight back. Returns the open streams (the caller
# disposes them), or $null when any image is in use or unreadable (all closed
# again).
function Open-CaelestiaSchemeImageHandles([string]$Directory) {
    $streams = [Collections.Generic.List[IO.FileStream]]::new()
    try {
        # GetFiles, not EnumerateFiles: a lazy enumerator abandoned by an
        # exception keeps a directory handle open and would block the rename.
        foreach ($file in [IO.Directory]::GetFiles($Directory, '*', [IO.SearchOption]::AllDirectories)) {
            if ($file -notmatch '\.(exe|dll|pyd|sys|node)$') { continue }
            $attributes = [IO.File]::GetAttributes($file)
            $readOnly = ($attributes -band [IO.FileAttributes]::ReadOnly) -ne 0
            if ($readOnly) {
                [IO.File]::SetAttributes($file, [IO.FileAttributes]([int]$attributes -band (-bnot [int][IO.FileAttributes]::ReadOnly)))
            }
            try {
                $streams.Add([IO.File]::Open($file, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::Read -bor [IO.FileShare]::Delete))
            } finally {
                if ($readOnly) {
                    [IO.File]::SetAttributes($file, [IO.FileAttributes]([int][IO.File]::GetAttributes($file) -bor [int][IO.FileAttributes]::ReadOnly))
                }
            }
        }
        return , $streams
    } catch {
        foreach ($stream in $streams) { $stream.Dispose() }
        return $null
    }
}

# True when no executable image under the directory is mapped by any process.
# Any failure counts as "in use".
function Test-CaelestiaSchemeImagesFree([string]$Directory) {
    $streams = Open-CaelestiaSchemeImageHandles $Directory
    if ($null -eq $streams) { return $false }
    foreach ($stream in $streams) { $stream.Dispose() }
    return $true
}

# Test seam: runs after a generation passed the image check and before it is
# renamed into .trash ('checked'), and again right after the rename ('moved').
# A no-op in production.
function Invoke-CaelestiaSchemePruneHook([string]$Stage, [string]$Directory) { }

# Exclusive ownership of a retired generation (or interrupted staging
# directory) is taken by renaming the whole directory into runtimes\.trash on
# the same volume. The rename fails while any process still has a handle or
# working directory inside, so a runtime in use is kept whole and retried at the
# next prune; nothing is deleted before the rename succeeds.
function Move-CaelestiaSchemeToTrash([string]$Directory, [string]$RuntimesRoot) {
    try {
        $safe = Resolve-CaelestiaDirectory $Directory
        if ((Split-Path -Parent $safe) -ne $RuntimesRoot) { return $false }
        Assert-CaelestiaNoReparsePoints $safe
        $trash = Join-Path $RuntimesRoot '.trash'
        New-Item -ItemType Directory -Force -Path $trash | Out-Null
        $target = Join-Path $trash ((Split-Path -Leaf $safe) + '.' + [guid]::NewGuid().ToString('N').Substring(0, 8))
        [IO.Directory]::Move($safe, $target)
        return $target
    } catch {
        return $null
    }
}

# Everything in .trash was already renamed away from any reference. A mapped
# image or a partial delete (a scanner holding a file, say) simply stays for the
# next prune; an entry is deleted only while none of its images is in use.
# Entries named in -Keep are in the restore journal: they must not be deleted
# before the next prune gets its one restore attempt.
function Remove-CaelestiaSchemeTrash([string]$RuntimesRoot, [string[]]$Keep = @()) {
    $trash = Join-Path $RuntimesRoot '.trash'
    if (-not (Test-Path -LiteralPath $trash -PathType Container)) { return }
    foreach ($entry in @(Get-ChildItem -LiteralPath $trash -Directory -Force -ErrorAction SilentlyContinue)) {
        if ($Keep -contains $entry.Name) { continue }
        try {
            Assert-CaelestiaNoReparsePoints $entry.FullName
            # Hold the images open while deleting, so nothing can start using
            # one between the check and the delete; directories go afterwards.
            $streams = Open-CaelestiaSchemeImageHandles $entry.FullName
            if ($null -eq $streams) { continue }
            try {
                Remove-Item -LiteralPath $entry.FullName -Recurse -Force -ErrorAction SilentlyContinue
            } finally {
                foreach ($stream in $streams) { $stream.Dispose() }
            }
            if (Test-Path -LiteralPath $entry.FullName) { Remove-Item -LiteralPath $entry.FullName -Recurse -Force }
        } catch { }
    }
    try { [IO.Directory]::Delete($trash, $false) } catch { }
}

# A generation moved into .trash after the image check is normally renamed back
# when the check fails again at the new location. That move-back can fail while
# an outside process still holds a file inside, and a retry loop could only spin
# until that process lets go. This small journal persists the restore intent
# across prune runs: the next prune restores it once, before any deletion, so a
# generation that was really in use gets its path back instead of being deleted
# as ordinary trash. Only hash-derived generation and trash leaf names are
# stored, so the journal never contains a profile or user path.
function Read-CaelestiaSchemeRestoreJournal([string]$SchemeRoot) {
    $path = Join-Path $SchemeRoot $script:CaelestiaSchemeRestoreJournalName
    # Missing is an empty journal. Unreadable or invalid is not: the caller
    # must not treat it as "nothing to restore" and delete the trash.
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        return [pscustomobject]@{ Entries = @(); Readable = $true }
    }
    try {
        $entries = @()
        foreach ($entry in @(Get-Content -LiteralPath $path -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json)) {
            $generation = [string]$entry.generation
            $trash = [string]$entry.trash
            if (-not (Test-CaelestiaSchemeGeneration $generation)) { continue }
            if ($trash -notmatch ('^' + [regex]::Escape($generation) + '\.[a-f0-9]{8}$')) { continue }
            $entries += [pscustomobject]@{ Generation = $generation; Trash = $trash }
        }
        return [pscustomobject]@{ Entries = $entries; Readable = $true }
    } catch {
        return [pscustomobject]@{ Entries = @(); Readable = $false }
    }
}

function Write-CaelestiaSchemeRestoreJournal([string]$SchemeRoot, $Entries) {
    try {
        $path = Join-Path $SchemeRoot $script:CaelestiaSchemeRestoreJournalName
        $records = @($Entries | Where-Object { $_ } | ForEach-Object {
            [ordered]@{ generation = [string]$_.Generation; trash = [string]$_.Trash }
        })
        if (-not $records.Count) {
            if (Test-Path -LiteralPath $path -PathType Leaf) { Remove-Item -LiteralPath $path -Force }
            return $true
        }
        New-Item -ItemType Directory -Force -Path $SchemeRoot | Out-Null
        Write-CaelestiaJsonAtomic $path $records
        return $true
    } catch {
        return $false
    }
}

# One restore attempt per prune. A held file makes the rename fail again; the
# entry stays in the journal for the following prune, never in a retry loop.
function Restore-CaelestiaSchemeTrashJournal([string]$SchemeRoot, [string]$RuntimesRoot) {
    $read = Read-CaelestiaSchemeRestoreJournal $SchemeRoot
    if (-not $read.Readable) {
        return [pscustomobject]@{ Restored = @(); Pending = @(); Saved = $false; Readable = $false }
    }
    $pending = @()
    $restored = @()
    $trashRoot = Join-Path $RuntimesRoot '.trash'
    foreach ($entry in @($read.Entries)) {
        $source = Join-Path $trashRoot $entry.Trash
        $target = Join-Path $RuntimesRoot $entry.Generation
        if (-not (Test-Path -LiteralPath $source -PathType Container)) { continue }
        # A destination that exists means it was already restored (or is
        # occupied): the path is not missing, so the trash entry can be retired
        # normally instead of being moved over it.
        if (Test-Path -LiteralPath $target) { continue }
        try {
            [IO.Directory]::Move($source, $target)
            $restored += $entry.Generation
        } catch {
            $pending += $entry
        }
    }
    $saved = Write-CaelestiaSchemeRestoreJournal $SchemeRoot $pending
    return [pscustomobject]@{ Restored = @($restored); Pending = @($pending); Saved = $saved; Readable = $true }
}

# Remove scheme generations no installed version can reference. Only run with
# no shell or supervisor alive and under the provisioning lock. A generation is
# removed only with proof nobody uses it: every image in it opens for write
# (the OS refuses while a process maps one, whatever process inspection can
# read), the rename into .trash succeeds (no working directory
# or open file inside), and no readable process runs an image from it. A
# generation that fails any test is kept whole and retried at the next prune.
function Remove-CaelestiaSchemeGenerations([string]$Prefix, [string]$ProfileRoot) {
    try {
        if (@(Get-CaelestiaProcesses $Prefix).Count -or @(Get-CaelestiaSupervisors $ProfileRoot).Count) { return }
        $lock = Enter-CaelestiaSchemeLock $ProfileRoot 0
        if (-not $lock) { return }
        try {
            $schemeRoot = Join-Path $ProfileRoot 'scheme'
            $runtimesRoot = [IO.Path]::GetFullPath((Join-Path $schemeRoot 'runtimes')).TrimEnd('\')
            if (-not (Test-Path -LiteralPath $runtimesRoot -PathType Container)) { return }
            $recovery = Restore-CaelestiaSchemeTrashJournal $schemeRoot $runtimesRoot
            if (-not $recovery.Readable) {
                # The journal may still list a generation sitting in .trash.
                # Deleting or retiring trash without that list can destroy the
                # only copy of a path we had promised to put back.
                Write-CaelestiaSchemeRuntimeLog -ProfileRoot $ProfileRoot -Event 'scheme-prune' `
                    -Fields ([ordered]@{ recovery = 'unread' })
                return
            }
            $restored = @($recovery.Restored)
            $journal = @($recovery.Pending)
            $journalSaved = [bool]$recovery.Saved
            # Processes whose images cannot be read (protected or elevated ones
            # are common) cannot be ruled out here, which is why the image probe
            # above is the authority; only a count is logged.
            $busy = @{}
            $unreadable = 0
            foreach ($process in @(Get-Process -ErrorAction SilentlyContinue)) {
                try {
                    foreach ($path in @(Get-CaelestiaProcessImagePaths $process)) {
                        if ($path.StartsWith($runtimesRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
                            $busy[$path.Substring($runtimesRoot.Length + 1).Split('\')[0].ToLowerInvariant()] = $true
                        }
                    }
                } catch { $unreadable++ }
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
                $published = [string](Get-Content -LiteralPath (Join-Path $schemeRoot 'runtime.json') -Raw -Encoding UTF8 | ConvertFrom-Json).generation
            } catch { }
            $kept = 0
            $stranded = 0
            foreach ($directory in @(Get-ChildItem -LiteralPath $runtimesRoot -Directory -Force -ErrorAction SilentlyContinue)) {
                $name = $directory.Name
                if ($name -eq '.trash') { continue }
                # A generation restored by the journal this run is left alone
                # until the next prune, so recovery cannot immediately retire
                # the path it just made available again.
                if ($restored -contains $name) { continue }
                # Every builder holds this lock, so a staging directory seen
                # here belongs to an interrupted run.
                if ($name -like '.staging-*') { $null = Move-CaelestiaSchemeToTrash $directory.FullName $runtimesRoot; continue }
                if ($name -eq $published) { continue }
                $generationRevision = ''
                try {
                    $generationRevision = [string](Get-Content -LiteralPath (Join-Path $directory.FullName 'generation.json') -Raw -Encoding UTF8 | ConvertFrom-Json).revision
                } catch { }
                if ($generationRevision -and $revisions.ContainsKey($generationRevision)) { continue }
                if ($busy.ContainsKey($name.ToLowerInvariant()) -or -not (Test-CaelestiaSchemeImagesFree $directory.FullName)) { $kept++; continue }
                Invoke-CaelestiaSchemePruneHook 'checked' $directory.FullName
                # A directory cannot be renamed while any handle is open inside
                # it, so the image handles cannot span the rename. Re-check at
                # the new location instead: an image mapped in the window
                # between check and rename shows up now, and the generation is
                # put straight back, so its consumer's path is restored.
                $moved = Move-CaelestiaSchemeToTrash $directory.FullName $runtimesRoot
                if (-not $moved) { $kept++; continue }
                Invoke-CaelestiaSchemePruneHook 'moved' $moved
                if (-not (Test-CaelestiaSchemeImagesFree $moved)) {
                    $kept++
                    try {
                        [IO.Directory]::Move($moved, $directory.FullName)
                    } catch {
                        # The held file blocks the move back. Record the intent
                        # now; the next prune restores it once, before deleting.
                        $stranded++
                        $journal += [pscustomobject]@{ Generation = $name; Trash = (Split-Path -Leaf $moved) }
                    }
                }
            }
            if ($stranded) { $journalSaved = Write-CaelestiaSchemeRestoreJournal $schemeRoot $journal }
            # Never delete a trash entry whose restore is still pending.
            Remove-CaelestiaSchemeTrash $runtimesRoot -Keep @($journal | ForEach-Object { $_.Trash })
            if ($restored.Count) {
                Write-CaelestiaSchemeRuntimeLog -ProfileRoot $ProfileRoot -Event 'scheme-prune' -Fields ([ordered]@{ restored = $restored.Count })
            }
            if ($stranded) {
                Write-CaelestiaSchemeRuntimeLog -ProfileRoot $ProfileRoot -Event 'scheme-prune' `
                    -Fields ([ordered]@{ stranded = $stranded; restorePending = $journal.Count; recovery = $(if ($journalSaved) { 'journal' } else { 'unavailable' }) })
            } elseif ($journal.Count) {
                Write-CaelestiaSchemeRuntimeLog -ProfileRoot $ProfileRoot -Event 'scheme-prune' `
                    -Fields ([ordered]@{ restorePending = $journal.Count; recovery = $(if ($journalSaved) { 'journal' } else { 'unavailable' }) })
            }
            if ($kept -or $unreadable) {
                Write-CaelestiaSchemeRuntimeLog -ProfileRoot $ProfileRoot -Event 'scheme-prune' `
                    -Fields ([ordered]@{ kept = $kept; unreadable = $unreadable })
            }
        } finally {
            Exit-CaelestiaSchemeLock $lock
        }
    } catch {
        # Cleanup must never fail an otherwise healthy install.
    }
}

# Keep activation diagnostics out of the shell's own stdout/stderr logs. Never
# include the profile or another user path in this file. Structured key=value
# fields come first: redacting an unquoted path in free text consumes the rest
# of the line, so a count, step or exit code must never follow one. Field values
# are single tokens (counts, flags, step names), never paths or file contents;
# free text is redacted and must never carry user file contents.
function Write-CaelestiaSchemeRuntimeLog([string]$ProfileRoot, [string]$Event, $Fields = @{}, [string]$Message = '') {
    try {
        $parts = [Collections.Generic.List[string]]::new()
        $parts.Add('event=' + $Event)
        if ($Fields) {
            foreach ($key in @($Fields.Keys | Sort-Object)) {
                $value = ([string]$Fields[$key]) -replace '\s+', '_'
                $parts.Add(('{0}={1}' -f $key, $value))
            }
        }
        $line = $parts -join ' '
        if ($Message) { $line += ' : ' + (Protect-CaelestiaText $Message) }
        $logs = Join-Path $ProfileRoot 'logs'
        New-Item -ItemType Directory -Force -Path $logs | Out-Null
        Add-Content -LiteralPath (Join-Path $logs 'scheme-runtime.log') `
            -Value ("{0} {1}" -f (Get-Date).ToString('o'), $line) -Encoding UTF8
    } catch { }
}

# IPC never provisions Python, loads the account picture or starts a watchdog.
function Invoke-CaelestiaIpc([string]$Prefix, [string]$Command, [int]$TimeoutMs = 10000) {
    $Prefix = Resolve-CaelestiaRuntimePrefix $Prefix -Running
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = Join-Path $Prefix 'qs.exe'
    $info.WorkingDirectory = $env:USERPROFILE
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
        -WorkingDirectory $env:USERPROFILE
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
                # Scheduled activation includes the launcher's banner replay
                # and first-frame gate, not only the child's 20 s render budget.
                Wait-CaelestiaReady $Prefix -TimeoutSeconds 75 -LegacyReady:$LegacyReady -TaskName $taskName
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

# Remove staging directories an interrupted earlier run left beside the prefix.
# A directory is owned when it carries this product's staging marker, install
# record or executable, or when it is still empty: the marker is the first file
# written, so a crash in that window can only leave an empty directory. Anything
# else is never deleted. A live PID means another installation is still working.
function Remove-CaelestiaStagingDirectories([string]$Prefix) {
    $parent = Split-Path -Parent $Prefix
    $leaf = Split-Path -Leaf $Prefix
    if (-not $parent -or -not (Test-Path -LiteralPath $parent -PathType Container)) { return }
    foreach ($leftover in @(Get-ChildItem -LiteralPath $parent -Directory -Force -Filter "$leaf.staging-*")) {
        $leftoverPath = Resolve-CaelestiaDirectory $leftover.FullName
        $leftoverPid = ($leftover.Name -replace '^.*\.staging-', '') -as [int]
        # A leftover with our own PID cannot be a live other installation: PIDs
        # are unique, so it is stale from an earlier process that reused ours.
        if ($leftoverPid -and $leftoverPid -ne $PID -and (Get-Process -Id $leftoverPid -ErrorAction SilentlyContinue)) {
            throw "Another installation is in progress: $leftoverPath"
        }
        if ($null -ne (Get-ChildItem -LiteralPath $leftoverPath -Force | Select-Object -First 1)) {
            $owned = (Test-Path -LiteralPath (Join-Path $leftoverPath '.caelestia-staging.json') -PathType Leaf) -or
                (Test-Path -LiteralPath (Join-Path $leftoverPath 'install.json') -PathType Leaf) -or
                (Test-Path -LiteralPath (Join-Path $leftoverPath 'qs.exe') -PathType Leaf)
            if (-not $owned) { throw "Refusing to remove unowned staging directory: $leftoverPath" }
        }
        Assert-CaelestiaNoReparsePoints $leftoverPath
        Remove-Item -LiteralPath $leftoverPath -Recurse -Force
    }
}

# Copy one tree over another for recovery. Only the root selector is excluded:
# Restore-CaelestiaUpdate writes it atomically before the copy, so an aborted
# mirror cannot leave it claiming the replacement and the copy cannot leave it
# half-written. Nested version payloads keep their own install.json. Returns
# robocopy's exit code; a test seam because a file locked between the process
# re-check and the copy is a race.
function Invoke-CaelestiaMirror([string]$Source, [string]$Destination) {
    # Only the root selector is excluded; version payloads inside the tree keep
    # their own install.json.
    & robocopy.exe $Source $Destination /MIR /XJ /R:2 /W:1 /NFL /NDL /NJH /NJS /NP /XF (Join-Path $Source 'install.json') | Out-Null
    return $LASTEXITCODE
}

function Restore-CaelestiaUpdate([string]$Prefix, [string]$ProfileRoot, [string]$Backup, [bool]$ReplacementActive) {
    # Recovery must also work after a failed/partial mirror, where the new
    # launch script may not exist. Use the untouched backup's launcher to quit.
    $record = Get-Content -LiteralPath (Join-Path $Backup 'install.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($record.product -ne 'caelestia-windows' -or -not (Test-CaelestiaSamePath $record.prefix $Prefix) -or
        -not (Test-CaelestiaSamePath $record.profile $ProfileRoot)) {
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
        Stop-CaelestiaHosts $Prefix
        Assert-CaelestiaNoReparsePoints $Prefix
        Assert-CaelestiaNoReparsePoints $Backup
        # Once the rollback has begun, the selector must name its target, never
        # the replacement. Point it at the backup atomically before the copy and
        # keep the mirror away from it, so a file locked between the process
        # re-check and the copy aborts with install.json already on the target.
        Write-CaelestiaJsonAtomic (Join-Path $Prefix 'install.json') $record
        $copyExit = Invoke-CaelestiaMirror $Backup $Prefix
        $global:LASTEXITCODE = 0
        if ($copyExit -ge 8) { throw "Rollback failed (robocopy exit $copyExit); the rollback selector was written and the backup retained." }
    }
    # This recovery path can start a pre-versioning launcher. Never let its
    # provisioner run inside the readiness clock; consume a prepared generation
    # when it supports one, otherwise disable provisioning for this start.
    $launcherText = ''
    try { $launcherText = [IO.File]::ReadAllText((Join-Path $Prefix 'Start-Caelestia.ps1')) } catch { }
    if ($launcherText -match '\[switch\]\$PreparedSchemeRuntime\b') {
        $restoreRuntime = Resolve-CaelestiaRuntimePrefix $Prefix
        # The shell is stopped here: receipt-only, never a probe.
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
    try { $owner = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
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

# Test-only confinement. A packaging test that must exercise real integration
# writes sets CAELESTIA_TEST_INTEGRATION_ROOT; every Start-menu, desktop and
# HKCU entry then lives under that disposable directory and a test registry
# root derived from it. Production runs leave the variable unset.
function Get-CaelestiaIntegrationTestRoots {
    $root = $env:CAELESTIA_TEST_INTEGRATION_ROOT
    if (-not $root) { return $null }
    $key = 'HKCU:\Software\CaelestiaWindowsTests\' + (Get-CaelestiaInstallLockKey $root).Substring(0, 16)
    return @{ Programs = Join-Path $root 'Programs'; Desktop = Join-Path $root 'Desktop'; Registry = $key }
}

# Every per-user entry this product registers is named from one prefix-derived
# suffix, so non-default prefixes never collide. Default is the unqualified name;
# any other prefix gets 12 hex characters of the lowercased prefix hash.
function Get-CaelestiaIntegration([string]$Prefix) {
    $testRoots = Get-CaelestiaIntegrationTestRoots
    $programs = if ($testRoots) { $testRoots.Programs } else { [Environment]::GetFolderPath('Programs') }
    $desktop = if ($testRoots) { $testRoots.Desktop } else { [Environment]::GetFolderPath('Desktop') }
    # One canonical spelling feeds both the default comparison and the hash, so
    # a prefix named short at install time and long at uninstall time derives
    # the same entries.
    $default = Get-CaelestiaLongPath (Join-Path $env:LOCALAPPDATA 'Programs\caelestia-windows')
    $canonicalPrefix = Get-CaelestiaLongPath $Prefix
    $suffix = ''
    if (-not [string]::Equals($canonicalPrefix, $default, [StringComparison]::OrdinalIgnoreCase)) {
        $hash = [Security.Cryptography.SHA256]::Create()
        try { $suffix = '-' + ([BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonicalPrefix.ToLowerInvariant())))).Replace('-', '').Substring(0, 12) }
        finally { $hash.Dispose() }
    }
    return @{
        RunName = "CaelestiaWindows$suffix"
        # Registry key name for Settings > Apps > Installed apps.
        UninstallKey = "CaelestiaWindows$suffix"
        Shortcut = Join-Path $programs "Caelestia Windows$suffix.lnk"
        SwitchBackShortcut = Join-Path $programs "Caelestia - Switch back to Windows$suffix.lnk"
        DesktopShortcut = Join-Path $desktop "Caelestia Windows$suffix.lnk"
        # Installed launcher script. Get-CaelestiaLaunchCommand is the only
        # generator of the conhost/powershell command that runs it.
        Launcher = Join-Path $Prefix 'Caelestia-Launcher.ps1'
    }
}

function Get-CaelestiaUninstallKeyRoot {
    $testRoots = Get-CaelestiaIntegrationTestRoots
    if ($testRoots) { return $testRoots.Registry + '\Uninstall' }
    return 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall'
}

function Get-CaelestiaUninstallKeyPath([string]$Prefix) {
    $integration = Get-CaelestiaIntegration $Prefix
    if (-not $integration.UninstallKey) { throw 'The installation has no Apps & features key name.' }
    return (Join-Path (Get-CaelestiaUninstallKeyRoot) $integration.UninstallKey)
}

# One command shape for every user-visible entry: the Start-menu launch and
# switch-back shortcuts, the optional desktop shortcut, the HKCU Run value and
# the Apps & features UninstallString. conhost.exe --headless gives Windows
# PowerShell a console without a window, so the entries never flash a console
# and never need VBScript or another Windows Script Host engine. The launcher
# derives its own prefix, so the command does not repeat the path and stays
# under Windows' 260-character limit for a Run value. A future signed launcher
# EXE (#20) replaces this helper and Caelestia-Launcher.ps1, nothing else.
function New-CaelestiaLaunchCommand([string]$Conhost, [string]$PowerShell, [string]$Launcher, [string]$Action) {
    # --headless must be followed directly by the child command. The action and
    # the quoted launcher path are data; no cmd.exe or script host parses them.
    # Both executables are fully qualified so neither a PATH entry nor a
    # user-writable current directory can substitute one.
    $arguments = '--headless "' + $PowerShell + '" -NoProfile -ExecutionPolicy Bypass -File "' +
        $Launcher + '" -Action ' + $Action
    return [pscustomobject]@{
        Target = $Conhost
        Arguments = $arguments
        CommandLine = '"' + $Conhost + '" ' + $arguments
        Launcher = $Launcher
    }
}

# Windows' documented limit for a Run value is 260 characters. Only the launcher
# path can be shortened: the 8.3 name is the same file, and it is kept only when
# it resolves back to that file. An empty result means no safe shortening.
function Get-CaelestiaShortPath([string]$Path) {
    # The generated Run value keeps the short spelling as-is. Only the proof
    # that it names the same file goes through the long-path normaliser.
    $full = Get-CaelestiaLongPath $Path
    $short = ''
    $fileSystem = $null
    try {
        $fileSystem = New-Object -ComObject Scripting.FileSystemObject
        $short = [string]$fileSystem.GetFile($full).ShortPath
    } catch {
        return ''
    } finally {
        if ($fileSystem) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($fileSystem) }
    }
    if (-not $short -or $short.Length -ge $full.Length) { return '' }
    try {
        $resolved = Get-CaelestiaLongPath ((Get-Item -LiteralPath $short -Force -ErrorAction Stop).FullName)
    } catch {
        return ''
    }
    if (-not [string]::Equals($resolved, $full, [StringComparison]::OrdinalIgnoreCase)) { return '' }
    return $short
}

function Get-CaelestiaLaunchCommand([string]$Prefix, [string]$Action, [int]$MaxLength = 0) {
    if ($Action -notin @('start', 'switch-back', 'uninstall', 'uninstall-quiet')) {
        throw "Unknown Caelestia launch action: $Action"
    }
    $conhost = Join-Path $env:SystemRoot 'System32\conhost.exe'
    $powershell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $launcher = Join-Path $Prefix 'Caelestia-Launcher.ps1'
    $command = New-CaelestiaLaunchCommand $conhost $powershell $launcher $Action
    if (-not $MaxLength -or $command.CommandLine.Length -le $MaxLength) { return $command }
    $short = Get-CaelestiaShortPath $launcher
    if ($short) {
        $shortCommand = New-CaelestiaLaunchCommand $conhost $powershell $short $Action
        if ($shortCommand.CommandLine.Length -le $MaxLength) { return $shortCommand }
    }
    throw ("The Caelestia launch command for $Prefix is longer than the Windows limit of $MaxLength characters. " +
        'Choose a shorter installation folder, then retry. Nothing was registered or changed.')
}

# App version from the installed payload, never from the root router: a rollback
# must show the version it selected. Legacy records may only carry releaseId.
function Get-CaelestiaInstalledVersion([string]$RuntimePrefix) {
    $record = Read-CaelestiaInstall $RuntimePrefix
    $version = [string]$record.appVersion
    if ($version) { return $version }
    $versionFile = Join-Path $RuntimePrefix 'version.json'
    if (Test-Path -LiteralPath $versionFile -PathType Leaf) {
        try { $version = [string](Get-Content -LiteralPath $versionFile -Raw -Encoding UTF8 | ConvertFrom-Json).version } catch { }
        if ($version) { return $version }
    }
    return [string]$record.releaseId
}

# EstimatedSize is a DWORD of KiB in Apps & features. An unreadable entry is
# skipped; the install directory size is informational, never a gate.
function Get-CaelestiaIntegrationSizeKb([string]$Prefix) {
    [long]$bytes = 0
    try {
        foreach ($file in [IO.Directory]::EnumerateFiles($Prefix, '*', [IO.SearchOption]::AllDirectories)) {
            try { $bytes += (New-Object IO.FileInfo $file).Length } catch { }
        }
    } catch { }
    $kb = [Math]::Ceiling($bytes / 1KB)
    if ($kb -lt 1) { $kb = 1 }
    return [uint32][Math]::Min($kb, [uint32]::MaxValue)
}

function Get-CaelestiaAppsFeaturesValueNames {
    return @('DisplayName', 'DisplayVersion', 'Publisher', 'InstallLocation', 'UninstallString',
        'QuietUninstallString', 'NoModify', 'NoRepair', 'EstimatedSize', 'DisplayIcon')
}

function Get-CaelestiaAppsFeaturesValues([string]$Prefix, [string]$RuntimePrefix) {
    $values = [ordered]@{
        DisplayName = 'Caelestia for Windows'
        Publisher = 'KldsSeeGhosts'
        InstallLocation = $Prefix
        UninstallString = (Get-CaelestiaLaunchCommand $Prefix 'uninstall').CommandLine
        QuietUninstallString = (Get-CaelestiaLaunchCommand $Prefix 'uninstall-quiet').CommandLine
        NoModify = 1
        NoRepair = 1
        EstimatedSize = Get-CaelestiaIntegrationSizeKb $Prefix
    }
    $version = Get-CaelestiaInstalledVersion $RuntimePrefix
    if ($version) { $values.Insert(1, 'DisplayVersion', $version) }
    $icon = Join-Path $RuntimePrefix 'qs.exe'
    if (Test-Path -LiteralPath $icon -PathType Leaf) { $values['DisplayIcon'] = $icon + ',0' }
    return $values
}

# Snapshot only the values this product owns, so an existing entry written by an
# interrupted earlier install is restored exactly and stranger values survive.
function Get-CaelestiaRegistrySnapshot([string]$KeyPath, [string[]]$Names) {
    $snapshot = @{ Exists = (Test-Path -LiteralPath $KeyPath); Values = @{} }
    if (-not $snapshot.Exists) { return $snapshot }
    $item = Get-Item -LiteralPath $KeyPath
    foreach ($name in $Names) {
        $kind = $null
        try { $kind = $item.GetValueKind($name) } catch { }
        if ($null -eq $kind) { continue }
        $snapshot.Values[$name] = @{
            Kind = $kind
            Value = $item.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        }
    }
    return $snapshot
}

function Restore-CaelestiaRegistrySnapshot([string]$KeyPath, $Snapshot, [string[]]$Names) {
    if (-not $Snapshot.Exists) {
        if (Test-Path -LiteralPath $KeyPath) { Remove-Item -LiteralPath $KeyPath -Recurse -Force -ErrorAction SilentlyContinue }
        return
    }
    # A removed Apps & features key must be recreated before its owned values
    # are restored; New-ItemProperty cannot create intermediate keys.
    if (-not (Test-Path -LiteralPath $KeyPath)) { New-CaelestiaRegistryKey $KeyPath }
    foreach ($name in $Names) {
        if ($Snapshot.Values.ContainsKey($name)) {
            $entry = $Snapshot.Values[$name]
            New-ItemProperty -LiteralPath $KeyPath -Name $name -PropertyType $entry.Kind -Value $entry.Value -Force | Out-Null
        } else {
            Remove-ItemProperty -LiteralPath $KeyPath -Name $name -ErrorAction SilentlyContinue
        }
    }
}

# New-Item on the registry provider does not create missing intermediate keys.
function New-CaelestiaRegistryKey([string]$KeyPath) {
    if (Test-Path -LiteralPath $KeyPath) { return }
    $parent = Split-Path -Parent $KeyPath
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-CaelestiaRegistryKey $parent }
    New-Item -Path $KeyPath | Out-Null
}

# The Apps & features values live under the prefix-derived Uninstall key. This
# writer restores the previous values if any write fails, so an update can never
# leave a version string from a selection that was rolled back.
function Write-CaelestiaAppsFeaturesEntry([string]$Prefix, [string]$RuntimePrefix) {
    $keyPath = Get-CaelestiaUninstallKeyPath $Prefix
    $names = @(Get-CaelestiaAppsFeaturesValueNames)
    $values = Get-CaelestiaAppsFeaturesValues $Prefix $RuntimePrefix
    $snapshot = Get-CaelestiaRegistrySnapshot $keyPath $names
    try {
        New-CaelestiaRegistryKey $keyPath
        foreach ($name in $values.Keys) {
            $kind = $(if ($name -in @('NoModify', 'NoRepair', 'EstimatedSize')) { 'DWord' } else { 'String' })
            New-ItemProperty -LiteralPath $keyPath -Name $name -PropertyType $kind -Value $values[$name] -Force | Out-Null
        }
        # A value this product once wrote but no longer sets must not linger.
        foreach ($name in $names) {
            if (-not $values.Contains($name)) { Remove-ItemProperty -LiteralPath $keyPath -Name $name -ErrorAction SilentlyContinue }
        }
    } catch {
        try { Restore-CaelestiaRegistrySnapshot $keyPath $snapshot $names } catch { }
        throw
    }
}

function Copy-CaelestiaIntegrationBackup([string]$Path) {
    $backup = $Path + '.integration-' + [guid]::NewGuid().ToString('N')
    try { [IO.File]::Copy($Path, $backup) }
    catch {
        try { if ([IO.File]::Exists($backup)) { [IO.File]::Delete($backup) } } catch { }
        throw "Could not snapshot the existing shortcut; integration was aborted: $($_.Exception.Message)"
    }
    return $backup
}

# Snapshot every owned per-user entry before uninstall moves the prefix aside.
# A cleanup failure restores this snapshot together with the prefix, so the
# Settings uninstall command never names a directory that no longer exists and
# a retry can run. Only entries this prefix owns are captured.
function Get-CaelestiaUserIntegrationSnapshot([string]$Prefix, $Integration = $null) {
    if (-not $Integration) { $Integration = Get-CaelestiaIntegration $Prefix }
    $files = @()
    try {
        foreach ($path in @($Integration.Shortcut, $Integration.SwitchBackShortcut, $Integration.DesktopShortcut)) {
            if (-not $path) { continue }
            $entry = @{ Path = $path; Existed = [IO.File]::Exists($path); Backup = '' }
            if ($entry.Existed) { $entry.Backup = Copy-CaelestiaIntegrationBackup $path }
            $files += $entry
        }
        $run = $null
        if ($Integration.RunName) {
            $runKey = Get-CaelestiaAutostartKey
            $existing = Get-ItemProperty -LiteralPath $runKey -Name $Integration.RunName -ErrorAction SilentlyContinue
            $run = @{ Key = $runKey; Name = $Integration.RunName; Existed = ($null -ne $existing); Value = '' }
            if ($run.Existed) { $run.Value = [string]$existing.($Integration.RunName) }
        }
        $key = $null
        if ($Integration.UninstallKey) {
            $keyPath = Get-CaelestiaUninstallKeyPath $Prefix
            $names = @(Get-CaelestiaAppsFeaturesValueNames)
            $key = @{ Path = $keyPath; Names = $names; Snapshot = (Get-CaelestiaRegistrySnapshot $keyPath $names) }
        }
        return @{ Files = $files; Run = $run; Key = $key }
    } catch {
        # Snapshot creation aborts the uninstall before the tombstone rename, so
        # remove the backups this attempt already made. A leftover .integration-*
        # copy would otherwise survive a failed uninstall.
        foreach ($file in $files) {
            if ($file.Backup) { try { [IO.File]::Delete($file.Backup) } catch { } }
        }
        throw
    }
}

# Restore exactly the snapshot above. The caller restores the prefix first, so
# the returned failure list describes entries a user can still repair. Backups
# are deleted only after they are copied back; a failed restore keeps them.
function Restore-CaelestiaUserIntegrationSnapshot($Snapshot) {
    $failures = @()
    foreach ($file in @($Snapshot.Files)) {
        try {
            if (-not [IO.File]::Exists($file.Path)) {
                if ($file.Backup -and [IO.File]::Exists($file.Backup)) {
                    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $file.Path) | Out-Null
                    [IO.File]::Copy($file.Backup, $file.Path, $false)
                }
            } elseif ($file.Existed -and $file.Backup -and [IO.File]::Exists($file.Backup) -and
                (Get-FileHash -LiteralPath $file.Path).Hash -ne (Get-FileHash -LiteralPath $file.Backup).Hash) {
                # A still-locked original may refuse the overwrite. Leave it in
                # place and report the one entry that could not be verified.
                [IO.File]::Copy($file.Backup, $file.Path, $true)
            } elseif (-not $file.Existed) {
                [IO.File]::Delete($file.Path)
            }
            if ($file.Backup -and [IO.File]::Exists($file.Backup)) { [IO.File]::Delete($file.Backup) }
        } catch { $failures += "shortcut $($file.Path): $($_.Exception.Message)" }
    }
    if ($Snapshot.Run) {
        try {
            if ($Snapshot.Run.Existed) {
                New-CaelestiaRegistryKey $Snapshot.Run.Key
                New-ItemProperty -LiteralPath $Snapshot.Run.Key -Name $Snapshot.Run.Name -PropertyType String `
                    -Value $Snapshot.Run.Value -Force | Out-Null
            } else {
                Remove-ItemProperty -LiteralPath $Snapshot.Run.Key -Name $Snapshot.Run.Name -ErrorAction SilentlyContinue
            }
        } catch { $failures += "autostart value $($Snapshot.Run.Name): $($_.Exception.Message)" }
    }
    if ($Snapshot.Key) {
        try { Restore-CaelestiaRegistrySnapshot $Snapshot.Key.Path $Snapshot.Key.Snapshot $Snapshot.Key.Names }
        catch { $failures += "Apps & features entry $($Snapshot.Key.Path): $($_.Exception.Message)" }
    }
    return $failures
}

function Remove-CaelestiaUserIntegrationSnapshot($Snapshot) {
    foreach ($file in @($Snapshot.Files)) {
        if ($file.Backup) { try { [IO.File]::Delete($file.Backup) } catch { } }
    }
}

# Write every user-visible integration entry as one transaction: the Start-menu
# launch entry, the Start-menu switch-back entry, the optional desktop entry,
# the optional HKCU Run value and the Apps & features key. Everything is
# snapshotted before the first write and restored on failure. -RefreshOnly is
# used by rollback: it updates only entries that already exist, so a
# -NoIntegration install can never be given entries later.
function Set-CaelestiaUserIntegration {
    param(
        [string]$Prefix,
        [string]$RuntimePrefix,
        $Integration = $null,
        [switch]$Autostart,
        [switch]$DesktopShortcut,
        [switch]$RefreshOnly
    )
    if (-not $Integration) { $Integration = Get-CaelestiaIntegration $Prefix }
    $icon = $RuntimePrefix.TrimEnd('\') + '\qs.exe,0'
    $launch = Get-CaelestiaLaunchCommand $Prefix 'start'
    $switchBack = Get-CaelestiaLaunchCommand $Prefix 'switch-back'
    $shortcuts = [Collections.Generic.List[object]]::new()
    foreach ($pair in @(
        @($Integration.Shortcut, $launch),
        @($Integration.SwitchBackShortcut, $switchBack)
    )) {
        if (-not $pair[0]) { continue }
        if ($RefreshOnly -and -not [IO.File]::Exists($pair[0])) { continue }
        $shortcuts.Add(@{ Path = $pair[0]; Target = $pair[1].Target; Arguments = $pair[1].Arguments })
    }
    if ($Integration.DesktopShortcut -and ($DesktopShortcut -or [IO.File]::Exists($Integration.DesktopShortcut))) {
        $shortcuts.Add(@{ Path = $Integration.DesktopShortcut; Target = $launch.Target; Arguments = $launch.Arguments })
    }
    $runKey = Get-CaelestiaAutostartKey
    $runExisted = $false
    $runValue = ''
    # Refresh an existing owned Run value on every activation, not only when
    # -Autostart is passed: an upgrade must replace the old command that
    # flashed a console. This never creates the value for a user who never
    # enabled autostart.
    if ($Integration.RunName) {
        $existing = Get-ItemProperty -LiteralPath $runKey -Name $Integration.RunName -ErrorAction SilentlyContinue
        if ($null -ne $existing) {
            $runExisted = $true
            $runValue = [string]$existing.($Integration.RunName)
        }
    }
    $writeRun = $Autostart -or $runExisted
    # Build the Run command before the first write. It refuses a prefix whose
    # command would exceed Windows' 260-character limit for a Run value, and a
    # refusal here must leave every existing entry untouched.
    $runCommand = ''
    if ($writeRun) { $runCommand = Get-CaelestiaAutostartValue $Prefix }
    $keyNames = @(Get-CaelestiaAppsFeaturesValueNames)
    $keyPath = ''
    $keySnapshot = $null
    if ($Integration.UninstallKey) {
        $keyPath = Get-CaelestiaUninstallKeyPath $Prefix
        if (-not $RefreshOnly -or (Test-Path -LiteralPath $keyPath)) { $keySnapshot = Get-CaelestiaRegistrySnapshot $keyPath $keyNames }
    }
    $fileSnapshots = @()
    try {
        foreach ($shortcut in $shortcuts) {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $shortcut.Path) | Out-Null
            $fileSnapshot = @{ Path = $shortcut.Path; Backup = ''; Existed = [IO.File]::Exists($shortcut.Path) }
            if ($fileSnapshot.Existed) { $fileSnapshot.Backup = Copy-CaelestiaIntegrationBackup $shortcut.Path }
            $fileSnapshots += $fileSnapshot
        }
    } catch {
        # A snapshot failure aborts before any writes; remove the backups this
        # attempt already made so the next run cannot misread them as originals.
        foreach ($fileSnapshot in $fileSnapshots) {
            if ($fileSnapshot.Backup) { try { [IO.File]::Delete($fileSnapshot.Backup) } catch { } }
        }
        throw
    }
    $runWriteAttempted = $false
    try {
        foreach ($shortcut in $shortcuts) {
            New-CaelestiaShortcut $shortcut.Path $shortcut.Target $shortcut.Arguments $Prefix $icon
        }
        if ($writeRun) {
            # Never New-Item -Force an existing registry key: it recreates the
            # key empty and deletes every other application's startup entry.
            New-CaelestiaRegistryKey $runKey
            $runWriteAttempted = $true
            New-ItemProperty -Path $runKey -Name $Integration.RunName -PropertyType String `
                -Value $runCommand -Force | Out-Null
        }
        if ($keySnapshot) { Write-CaelestiaAppsFeaturesEntry $Prefix $RuntimePrefix }
    } catch {
        foreach ($fileSnapshot in $fileSnapshots) {
            try {
                if ($fileSnapshot.Backup -and [IO.File]::Exists($fileSnapshot.Backup)) {
                    [IO.File]::Copy($fileSnapshot.Backup, $fileSnapshot.Path, $true)
                    [IO.File]::Delete($fileSnapshot.Backup)
                } elseif (-not $fileSnapshot.Existed -and [IO.File]::Exists($fileSnapshot.Path)) {
                    [IO.File]::Delete($fileSnapshot.Path)
                }
            } catch { }
        }
        try {
            if ($runWriteAttempted) {
                if ($runExisted) { New-ItemProperty -Path $runKey -Name $Integration.RunName -PropertyType String -Value $runValue -Force | Out-Null }
                else { Remove-ItemProperty -LiteralPath $runKey -Name $Integration.RunName -ErrorAction SilentlyContinue }
            }
        } catch { }
        if ($keySnapshot) { try { Restore-CaelestiaRegistrySnapshot $keyPath $keySnapshot $keyNames } catch { } }
        throw
    }
    # A backup that cannot be deleted is not an integration failure: never roll
    # back a completed install over a cleanup problem.
    foreach ($fileSnapshot in $fileSnapshots) {
        if ($fileSnapshot.Backup) { try { [IO.File]::Delete($fileSnapshot.Backup) } catch { } }
    }
}

# Rollback updates existing entries only. It must never recreate an entry that a
# previous -NoIntegration install deliberately did not register.
function Update-CaelestiaIntegrationRecords([string]$Prefix, [string]$RuntimePrefix) {
    $integration = Get-CaelestiaIntegration $Prefix
    if (-not $integration.UninstallKey) { return }
    $keyPath = Get-CaelestiaUninstallKeyPath $Prefix
    $existing = @(Test-Path -LiteralPath $keyPath)
    foreach ($path in @($integration.Shortcut, $integration.SwitchBackShortcut, $integration.DesktopShortcut)) {
        if ($path) { $existing += [bool][IO.File]::Exists($path) }
    }
    if (-not ($existing -contains $true)) { return }
    Set-CaelestiaUserIntegration $Prefix $RuntimePrefix -Integration $integration -RefreshOnly
}

# Uninstall removes exactly the entries this prefix derived, after the prefix has
# been renamed aside. No process, profile or stranger entry is touched. The
# caller resolves the integration before its destructive steps and passes it in,
# so the names it removes are the ones it checked.
function Remove-CaelestiaUserIntegration([string]$Prefix, $Integration = $null) {
    if (-not $Integration) { $Integration = Get-CaelestiaIntegration $Prefix }
    $runKey = Get-CaelestiaAutostartKey
    if ($Integration.RunName -and
        (Get-ItemProperty -LiteralPath $runKey -Name $Integration.RunName -ErrorAction SilentlyContinue)) {
        Remove-ItemProperty -LiteralPath $runKey -Name $Integration.RunName
    }
    foreach ($path in @($Integration.Shortcut, $Integration.SwitchBackShortcut, $Integration.DesktopShortcut)) {
        if ($path -and (Test-Path -LiteralPath $path)) { Remove-Item -LiteralPath $path -Force }
    }
    if (-not $Integration.UninstallKey) { return }
    $keyPath = Get-CaelestiaUninstallKeyPath $Prefix
    if (Test-Path -LiteralPath $keyPath) { Remove-Item -LiteralPath $keyPath -Recurse -Force }
}

# Native dialog for the two interactive decisions (turn off autostart, delete
# settings). Non-interactive callers get the documented default, never a hang.
function Read-CaelestiaConfirmation([string]$Title, [string]$Text, [switch]$DefaultYes) {
    if (-not [Environment]::UserInteractive) { return [bool]$DefaultYes }
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $default = $(if ($DefaultYes) {
            [System.Windows.Forms.MessageBoxDefaultButton]::Button1
        } else {
            [System.Windows.Forms.MessageBoxDefaultButton]::Button2
        })
        return [System.Windows.Forms.MessageBox]::Show($Text, $Title,
            [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Question,
            $default) -eq [System.Windows.Forms.DialogResult]::Yes
    } catch {
        return [bool]$DefaultYes
    }
}

function Show-CaelestiaError([string]$Title, [string]$Text) {
    if (-not [Environment]::UserInteractive) { return }
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        [System.Windows.Forms.MessageBox]::Show($Text, $Title,
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
    } catch { }
}

# The highwater rule (Caelestia-Update.ps1 Get-CaelestiaUpdateStatePath) is that
# rollback and profile purge must not erase revocation/freshness highwater, so
# uninstall keeps it too and the dialog says so instead of silently deleting it.
function Get-CaelestiaPurgePromptText([string]$ProfileRoot) {
    return @"
Caelestia for Windows is installed per user.

Yes: also delete this installation's settings, configuration, logs and other profile data in:
$ProfileRoot

No (default): keep them so a reinstall can reuse them.

Shared Quickshell crash diagnostics in %LOCALAPPDATA%\quickshell\cache\crashes
are kept either way. They may belong to other configurations. Remove them manually
if no longer needed; dumps contain process memory and cannot be redacted.

Either way, Windows update trust data in %LOCALAPPDATA%\caelestia-update-trust is kept.
It records the newest signed update metadata this PC has accepted, so reinstalling
Caelestia cannot roll update security back to older metadata.
"@
}

function Get-CaelestiaAutostartPromptText {
    return @"
Caelestia is closing and Windows is taking the desktop back.

Turn off Caelestia at sign-in too?

Yes (default): Caelestia will not start automatically next time.
No: keep starting Caelestia automatically at sign-in.
"@
}

# Prefix-derived key shared by the new Global lock and the legacy Local name.
# The canonical long spelling is hashed so a short and a long spelling of the
# same prefix take the same lock.
function Get-CaelestiaInstallLockKey([string]$Prefix) {
    $canonical = Get-CaelestiaLongPath $Prefix
    $hash = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($hash.ComputeHash([Text.Encoding]::UTF8.GetBytes($canonical.ToLowerInvariant()))).Replace('-', '') }
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

# Both installers enter the prefix lock before this preflight. Keep ownership,
# interrupted-install recovery and profile adoption identical for built and
# downloaded payloads. This function does not stop the running shell.
function Initialize-CaelestiaInstall([string]$Prefix, [string]$ProfileRoot, [switch]$Restart, [switch]$Force) {
    $backup = "$Prefix.old"
    if (Test-Path -LiteralPath $backup) {
        $backup = Resolve-CaelestiaDirectory $backup
        $backupInstall = Join-Path $backup 'install.json'
        if (-not (Test-Path -LiteralPath $backupInstall -PathType Leaf)) {
            throw "Refusing to touch unowned backup directory without install.json: $backup"
        }
        $backupRecord = Get-Content -LiteralPath $backupInstall -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($backupRecord.product -ne 'caelestia-windows' -or -not (Test-CaelestiaSamePath $backupRecord.prefix $Prefix)) {
            throw "Refusing to touch backup directory belonging to another installation: $backup"
        }
        if (-not (Test-Path -LiteralPath $Prefix)) { [IO.Directory]::Move($backup, $Prefix) }
        else { Assert-CaelestiaNoReparsePoints $backup; Remove-Item -LiteralPath $backup -Recurse -Force }
    }
    Remove-CaelestiaStagingDirectories $Prefix
    $old = $null
    if ((Test-Path -LiteralPath $Prefix) -and (Get-ChildItem -LiteralPath $Prefix -Force | Select-Object -First 1)) {
        if (Test-Path -LiteralPath (Join-Path $Prefix 'install.json')) {
            $old = Read-CaelestiaInstall $Prefix
            if ($old.installRoot -and -not (Test-CaelestiaSamePath $old.installRoot $Prefix)) {
                throw 'Do not install into an immutable version directory. Use its stable installRoot.'
            }
            if (-not (Test-CaelestiaSamePath $old.profile $ProfileRoot)) { throw 'An update must retain the installed ProfileRoot.' }
        } elseif (-not $Force -or -not ((Test-Path -LiteralPath (Join-Path $Prefix 'qs.exe')) -or (Test-Path -LiteralPath (Join-Path $Prefix 'Start-Caelestia.ps1')))) {
            throw "$Prefix is not a recognized Caelestia installation. A partial install of Caelestia can be replaced with -Force."
        }
    }
    if (-not $Restart) {
        if (Get-CaelestiaProcesses $Prefix) { throw 'Use -Restart to prepare a live update, or quit this Caelestia installation before updating it.' }
        if (@(Get-CaelestiaSupervisors $ProfileRoot).Count) { throw 'A Caelestia desktop supervisor is still running for this profile. Use -Restart for a live update.' }
    }
    $profileExclusive = $true
    if (-not (Test-CaelestiaProfileEmpty $ProfileRoot)) {
        $owner = Read-CaelestiaProfileOwner $ProfileRoot
        if ($owner) {
            if (-not (Test-CaelestiaSamePath $owner.prefix $Prefix)) {
                if (-not $Force) { throw "ProfileRoot $ProfileRoot belongs to another Caelestia installation ($($owner.prefix)). Choose a separate profile, or pass -Force to share it." }
                $profileExclusive = $false
            } else { $profileExclusive = [bool]$owner.exclusive }
        } elseif ($old -or $Force) {
            $profileExclusive = $false
        } else {
            throw "ProfileRoot $ProfileRoot is not empty and has no Caelestia ownership marker. Use an empty directory, or pass -Force (the profile is then never removed by Uninstall -Purge)."
        }
    }
    return [pscustomobject]@{
        Old = $old
        ProfileExclusive = $profileExclusive
        InstallId = $(if ($old -and $old.installId) { [string]$old.installId } else { [guid]::NewGuid().ToString('N') })
    }
}

. (Join-Path $PSScriptRoot 'Caelestia-Versions.ps1')
