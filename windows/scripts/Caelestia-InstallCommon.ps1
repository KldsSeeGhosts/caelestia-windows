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

# One stable spelling for a directory so that every spelling of the same
# directory (trailing separators, forward slashes, \\?\ prefix, 8.3 short
# names, letter case) names the same lock. The directory need not exist.
function Get-CaelestiaCanonicalPath([string]$Path) {
    if (-not $Path) { throw 'A nonempty path is required.' }
    if ($Path.StartsWith('\\?\UNC\', [StringComparison]::OrdinalIgnoreCase)) { $Path = '\\' + $Path.Substring(8) }
    elseif ($Path.StartsWith('\\?\', [StringComparison]::Ordinal) -or $Path.StartsWith('\\.\', [StringComparison]::Ordinal)) { $Path = $Path.Substring(4) }
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    if ($full.Length -gt $root.Length) { $full = $full.TrimEnd('\', '/') }
    if ($full.IndexOf('~') -ge 0 -and $full.Length -gt $root.Length) {
        # A directory pattern also matches 8.3 names and returns the long name.
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

# Diagnostics must not carry machine paths. Redact by shape, not by a list of
# known prefixes: any absolute Windows path (drive, UNC or \\?\) and any file
# URL becomes <path>/<file-url>, keeping only a short leaf extension.
function Protect-CaelestiaText([string]$Text) {
    if (-not $Text) { return '' }
    $clean = [regex]::Replace($Text, 'file:/{1,3}[^\s"''<>|]*', '<file-url>', 'IgnoreCase')
    $path = '(?:\\\\\?\\(?:UNC\\|[A-Za-z]:[\\/]+)?|(?<![\\\w])\\\\|(?<![A-Za-z0-9])[A-Za-z]:[\\/]+)' +
        '(?:[^\\/\r\n"''<>|*?:]+[\\/]+)*[^\\/\s"''<>|*?:]*'
    return [regex]::Replace($clean, $path, {
        param($match)
        $extension = [regex]::Match($match.Value, '\.[A-Za-z0-9]{1,8}$')
        return '<path>' + $extension.Value
    }, 'IgnoreCase')
}

# A venv is only usable while the interpreter it was created from still
# exists: its python.exe is a launcher that follows pyvenv.cfg's home.
function Test-CaelestiaSchemeBase([string]$GenerationRoot) {
    try {
        $venv = Join-Path $GenerationRoot 'venv'
        if (-not (Test-Path -LiteralPath (Join-Path $venv 'Scripts\python.exe') -PathType Leaf) -or
            -not (Test-Path -LiteralPath (Join-Path $GenerationRoot 'win_scheme.py') -PathType Leaf) -or
            -not (Test-Path -LiteralPath (Join-Path $GenerationRoot 'generation.json') -PathType Leaf)) { return $false }
        $config = Join-Path $venv 'pyvenv.cfg'
        if (-not (Test-Path -LiteralPath $config -PathType Leaf)) { return $false }
        foreach ($line in [IO.File]::ReadAllLines($config)) {
            if ($line -match '^\s*home\s*=\s*(.+?)\s*$') {
                return (Test-Path -LiteralPath (Join-Path $Matches[1] 'python.exe') -PathType Leaf)
            }
        }
        return $false
    } catch {
        return $false
    }
}

# Full health: the base interpreter exists and the venv's python really runs
# and imports the scheme packages. The timeout is a failure bound for a hung
# interpreter, never a wait for another process. Run it outside the readiness
# clock only.
function Test-CaelestiaSchemeHealth([string]$GenerationRoot, [int]$TimeoutSeconds = 15) {
    if (-not (Test-CaelestiaSchemeBase $GenerationRoot)) { return $false }
    $process = $null
    try {
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = Join-Path $GenerationRoot 'venv\Scripts\python.exe'
        $info.Arguments = '-I -c "import materialyoucolor, PIL, caelestia"'
        # Never run from inside the generation: a cwd there would block pruning.
        $info.WorkingDirectory = $env:SystemRoot
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $info.RedirectStandardOutput = $true
        $info.RedirectStandardError = $true
        $info.EnvironmentVariables['PYTHONDONTWRITEBYTECODE'] = '1'
        $process = [Diagnostics.Process]::Start($info)
        $null = $process.StandardOutput.ReadToEndAsync()
        $null = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            try { & taskkill.exe /PID $process.Id /T /F 2>&1 | Out-Null } catch { }
            try { $process.Kill() } catch { }
            return $false
        }
        return $process.ExitCode -eq 0
    } catch {
        return $false
    } finally {
        if ($process) { $process.Dispose() }
    }
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
# the identity freshly computed from this payload's inputs. It never creates a
# venv or installs packages, and it starts no process, because it can run
# inside the readiness clock: the repoint and the normal-start path verify
# health outside it (-Verify). Missing, failed or mismatched records start the
# fixed palette.
function Get-CaelestiaPreparedSchemeRuntime([string]$ProfileRoot, [string]$ExpectedRevision = '', [string]$RuntimePrefix = '', [switch]$Verify) {
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
        if ($Verify -and -not (Test-CaelestiaSchemeHealth $generationRoot)) { return $null }
        return $record
    } catch {
        return $null
    }
}

# The newest verified generation built from exactly this identity (and CLI
# revision), or $null. Unverified generations are never candidates. Call under
# the scheme lock and outside the readiness clock: it runs the venv's python.
function Get-CaelestiaVerifiedSchemeGeneration([string]$ProfileRoot, [string]$Revision, [string]$IdentityId = '') {
    $runtimesRoot = [IO.Path]::GetFullPath((Join-Path (Join-Path $ProfileRoot 'scheme') 'runtimes')).TrimEnd('\')
    if (-not (Test-Path -LiteralPath $runtimesRoot -PathType Container)) { return $null }
    $candidates = @()
    foreach ($directory in @(Get-ChildItem -LiteralPath $runtimesRoot -Directory -Force)) {
        if (-not (Test-CaelestiaSchemeGeneration $directory.Name)) { continue }
        try { $generation = Get-Content -LiteralPath (Join-Path $directory.FullName 'generation.json') -Raw | ConvertFrom-Json } catch { continue }
        if ([string]$generation.revision -ne $Revision -or [string]$generation.generation -ne $directory.Name) { continue }
        if ($IdentityId -and [string]$generation.identity -ne $IdentityId) { continue }
        $candidates += [pscustomobject]@{ Directory = $directory; Meta = $generation; Created = $directory.CreationTimeUtc; Name = $directory.Name }
    }
    foreach ($candidate in @($candidates | Sort-Object -Property @{ Expression = { $_.Created }; Descending = $true }, @{ Expression = { $_.Name }; Descending = $true })) {
        if (Test-CaelestiaSchemeHealth $candidate.Directory.FullName) { return $candidate }
    }
    return $null
}

function Write-CaelestiaSchemePointer([string]$ProfileRoot, [string]$Revision, $Candidate) {
    $schemeRoot = Join-Path $ProfileRoot 'scheme'
    $record = [ordered]@{
        available = $true
        revision = $Revision
        generation = $Candidate.Name
        python = Join-Path $Candidate.Directory.FullName 'venv\Scripts\python.exe'
        helper = Join-Path $Candidate.Directory.FullName 'win_scheme.py'
        provisionedAt = $(if ($Candidate.Meta.created) { [string]$Candidate.Meta.created } else { (Get-Date).ToString('o') })
    }
    $current = $null
    try { $current = Get-Content -LiteralPath (Join-Path $schemeRoot 'runtime.json') -Raw | ConvertFrom-Json } catch { }
    if (-not ($current -and $current.available -eq $true -and [string]$current.generation -eq $Candidate.Name)) {
        Write-CaelestiaJsonAtomic (Join-Path $schemeRoot 'runtime.json') $record
    }
    return [pscustomobject]$record
}

# Point runtime.json at an existing generation for the requested revision
# without provisioning. Activation calls this before the readiness clock; a
# busy lock or a missing generation returns null and the shell starts fixed.
# Only a verified generation is ever chosen, the newest one for the payload's
# identity, so a repoint can never move from a working generation to a broken
# one, and an older sibling cannot undo a repair.
function Set-CaelestiaSchemeRuntimeForRevision([string]$ProfileRoot, [string]$Revision, [string]$RuntimePrefix = '') {
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
            $candidate = Get-CaelestiaVerifiedSchemeGeneration $ProfileRoot $Revision $expectedIdentity
            if (-not $candidate) { return $null }
            return Write-CaelestiaSchemePointer $ProfileRoot $Revision $candidate
        } finally {
            Exit-CaelestiaSchemeLock $lock
        }
    } catch {
        return $null
    }
}

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
        [IO.Directory]::Move($safe, (Join-Path $trash ((Split-Path -Leaf $safe) + '.' + [guid]::NewGuid().ToString('N').Substring(0, 8))))
        return $true
    } catch {
        return $false
    }
}

# Everything in .trash was already renamed away from any reference. A partial
# delete (a scanner holding a file, say) simply stays for the next prune.
function Remove-CaelestiaSchemeTrash([string]$RuntimesRoot) {
    $trash = Join-Path $RuntimesRoot '.trash'
    if (-not (Test-Path -LiteralPath $trash -PathType Container)) { return }
    foreach ($entry in @(Get-ChildItem -LiteralPath $trash -Directory -Force -ErrorAction SilentlyContinue)) {
        try {
            Assert-CaelestiaNoReparsePoints $entry.FullName
            Remove-Item -LiteralPath $entry.FullName -Recurse -Force
        } catch { }
    }
    try { [IO.Directory]::Delete($trash, $false) } catch { }
}

# Remove scheme generations no installed version can reference. Only run with
# no shell or supervisor alive and under the provisioning lock; a generation
# that cannot be renamed away is in use and is left for the next prune.
function Remove-CaelestiaSchemeGenerations([string]$Prefix, [string]$ProfileRoot) {
    try {
        if (@(Get-CaelestiaProcesses $Prefix).Count -or @(Get-CaelestiaSupervisors $ProfileRoot).Count) { return }
        $lock = Enter-CaelestiaSchemeLock $ProfileRoot 0
        if (-not $lock) { return }
        try {
            $schemeRoot = Join-Path $ProfileRoot 'scheme'
            $runtimesRoot = [IO.Path]::GetFullPath((Join-Path $schemeRoot 'runtimes')).TrimEnd('\')
            if (-not (Test-Path -LiteralPath $runtimesRoot -PathType Container)) { return }
            # Extra guard beside the rename, which a running image does not
            # block: skip any generation a process executes from.
            $busy = @{}
            foreach ($process in @(Get-Process -ErrorAction SilentlyContinue)) {
                try {
                    $path = $process.Path
                    if ($path -and $path.StartsWith($runtimesRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
                        $busy[$path.Substring($runtimesRoot.Length + 1).Split('\')[0].ToLowerInvariant()] = $true
                    }
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
                $name = $directory.Name
                if ($name -eq '.trash') { continue }
                # Every builder holds this lock, so a staging directory seen
                # here belongs to an interrupted run.
                if ($name -like '.staging-*') { $null = Move-CaelestiaSchemeToTrash $directory.FullName $runtimesRoot; continue }
                if ($name -eq $published -or $busy.ContainsKey($name.ToLowerInvariant())) { continue }
                $generationRevision = ''
                try {
                    $generationRevision = [string](Get-Content -LiteralPath (Join-Path $directory.FullName 'generation.json') -Raw | ConvertFrom-Json).revision
                } catch { }
                if ($generationRevision -and $revisions.ContainsKey($generationRevision)) { continue }
                $null = Move-CaelestiaSchemeToTrash $directory.FullName $runtimesRoot
            }
            Remove-CaelestiaSchemeTrash $runtimesRoot
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
