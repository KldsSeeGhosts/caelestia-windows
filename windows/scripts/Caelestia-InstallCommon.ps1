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

# A watchdog timestamp is written as an 'o'-format UTC string. ConvertFrom-Json
# already returns a DateTime for it under PowerShell 7; 5.1 keeps the string.
# Passing a DateTime through [string] and Parse would reinterpret UTC ticks as
# local time, so take the object as-is.
function ConvertTo-CaelestiaStatusUtc($Value) {
    if ($Value -is [DateTime]) { return [DateTimeOffset]::new($Value) }
    if ($Value -is [DateTimeOffset]) { return $Value }
    return [DateTimeOffset]::Parse([string]$Value)
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
                if ($startedUtc -gt (ConvertTo-CaelestiaStatusUtc $status.utc).UtcDateTime.AddSeconds(5)) { continue }
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
    Import-CaelestiaDesktopTakeover -ScriptRoot $PSScriptRoot
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
        $deadline = (ConvertTo-CaelestiaStatusUtc $status.utc).UtcDateTime.AddSeconds($limit)
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

# Windows PowerShell 5.1 is the inbox compatibility host, kept only for the
# NotifyTest WinRT toast (PS 7 has no built-in WinRT projection), the
# clean-machine Install.cmd bootstrap fallback, and launching a rolled-back
# legacy payload whose DesktopTakeover.cs still uses
# System.Web.Script.Serialization. Everything else runs on PowerShell 7.
function Get-WindowsPowerShellPath {
    $path = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $path -PathType Leaf) { return $path }
    return Join-Path $PSHOME 'powershell.exe'
}

# PowerShell 7 x64 is the runtime host for every Caelestia script. Discovery
# never consults PATH: a user-writable shim could substitute another binary.
# Sources are, in order, the current Core host, the machine-wide MSI
# registration, the standard MSI path, App Paths, and the verified Microsoft
# Store package's stable alias.
function Get-CaelestiaPowerShellMinimumVersion {
    # Test and deployment fixtures can raise the floor through the environment;
    # a malformed or lower value is ignored so the product floor never drops.
    $override = $env:CAELESTIA_MIN_POWERSHELL_VERSION
    if ($override -match '\A7\.[0-9]+\.[0-9]+(?:\.[0-9]+)?\z') {
        $parsed = $null
        if ([version]::TryParse($override, [ref]$parsed) -and $parsed -ge [version]'7.4.0') {
            return $parsed
        }
    }
    return [version]'7.4.0'
}

function Get-CaelestiaPowerShellDownloadUrl {
    return 'https://github.com/PowerShell/PowerShell/releases/download/v7.6.10/PowerShell-7.6.10-win-x64.msi'
}

function Get-CaelestiaStorePowerShellAlias {
    # Resolve the OS LocalAppData, not $env:LOCALAPPDATA. Tests and worker
    # fixtures redirect that variable to an isolated cache, but the Microsoft
    # Store always registers its stable execution alias under the real user
    # profile.
    $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if (-not $localAppData) { $localAppData = $env:LOCALAPPDATA }
    return Join-Path $localAppData 'Microsoft\WindowsApps\Microsoft.PowerShell_8wekyb3d8bbwe\pwsh.exe'
}

# A reparse point on the file or on any of its parent directories up to and
# including Boundary means the path is not the trusted image it names.
function Test-CaelestiaNoReparse([string]$Path, [string]$Boundary) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if (-not $item -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $false }
    $stop = Get-CaelestiaLongPath $Boundary
    $ancestor = $Path
    while ($true) {
        $ancestor = Split-Path -Parent $ancestor
        if (-not $ancestor) { return $true }
        $node = Get-Item -LiteralPath $ancestor -Force -ErrorAction SilentlyContinue
        if ($node -and ($node.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $false }
        if ([string]::Equals((Get-CaelestiaLongPath $ancestor), $stop, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
}

# The Machine field at the PE header offset. 0x8664 is x64; WOW64 shims and
# ARM64 builds are never a substitute for the x64 host.
function Test-CaelestiaX64Executable([string]$Path) {
    try {
        $stream = [IO.File]::Open($Path, 'Open', 'Read', 'ReadWrite')
        try {
            $reader = [IO.BinaryReader]::new($stream)
            if ($stream.Length -lt 0x40) { return $false }
            if ($reader.ReadUInt16() -ne 0x5A4D) { return $false }
            $stream.Seek(0x3C, [IO.SeekOrigin]::Begin) | Out-Null
            $offset = $reader.ReadInt32()
            if ($offset -lt 0x40 -or ($offset + 6) -gt $stream.Length) { return $false }
            $stream.Seek($offset, [IO.SeekOrigin]::Begin) | Out-Null
            if ($reader.ReadUInt32() -ne 0x00004550) { return $false }
            $stream.Seek($offset + 4, [IO.SeekOrigin]::Begin) | Out-Null
            return $reader.ReadUInt16() -eq 0x8664
        } finally { $stream.Dispose() }
    } catch { return $false }
}

# A directory (not a file) must exist and carry no reparse point itself or on
# any ancestor up to and including Boundary. Unlike Test-CaelestiaNoReparse the
# subject itself is a directory, so the leaf check is skipped for files whose
# reparse bit is legitimate (a Store AppExecLink alias).
function Test-CaelestiaNoReparseDirectoryChain([string]$Directory, [string]$Boundary) {
    $stop = Get-CaelestiaLongPath $Boundary
    $node = Get-Item -LiteralPath $Directory -Force -ErrorAction SilentlyContinue
    if (-not $node -or ($node.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $false }
    $ancestor = $Directory
    while ($true) {
        $ancestor = Split-Path -Parent $ancestor
        if (-not $ancestor) { return $true }
        $item = Get-Item -LiteralPath $ancestor -Force -ErrorAction SilentlyContinue
        if ($item -and ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) { return $false }
        if ([string]::Equals((Get-CaelestiaLongPath $ancestor), $stop, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
}

# A PowerShell file-version/product-version string can carry a prerelease or
# build-metadata suffix ("7.7.0-preview.1", "7.6.10.0", "7.7.0+sha..."). Strip
# the suffix before comparing a [version]; a prerelease tag does not change the
# numeric floor the manifest names.
function ConvertTo-CaelestiaVersionOrNull([string]$Text) {
    if (-not $Text) { return $null }
    $clean = ($Text.Trim() -split '[-+]')[0]
    $parsed = $null
    if ([version]::TryParse($clean, [ref]$parsed)) { return $parsed }
    return $null
}

# The OS LocalAppData, not $env:LOCALAPPDATA. Test fixtures and worker
# environments redirect that variable to an isolated cache, but supported
# per-user installs and the Store alias always live under the real profile.
function Get-CaelestiaOsLocalAppData {
    $localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
    if (-not $localAppData) { $localAppData = $env:LOCALAPPDATA }
    return $localAppData
}

# A Store execution alias is an AppExecLink reparse point (tag 0x8000001B).
# Existence and a clean directory chain do not prove it points at the verified
# package: a user-writable link could redirect the launch elsewhere. Read the
# reparse buffer through CreateFileW/OPEN_REPARSE_POINT + FSCTL_GET_REPARSE_POINT
# and compare the recorded package family and target against the verified
# package. The inline P/Invoke is compiled once per session and only on hosts
# that need it.
function Read-CaelestiaAppExecLink([string]$Path) {
    if (-not ('CaelestiaReparse.AppExecLink' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;
namespace CaelestiaReparse {
    public static class AppExecLink {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern IntPtr CreateFile(string path, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool DeviceIoControl(IntPtr handle, uint code, byte[] input, uint inputLength, byte[] output, uint outputLength, out uint returned, IntPtr overlapped);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool CloseHandle(IntPtr handle);
        public static string[] Read(string path) {
            IntPtr handle = CreateFile(path, 0, 7, IntPtr.Zero, 3, 0x00200000 | 0x00000080, IntPtr.Zero);
            if (handle == new IntPtr(-1)) { return null; }
            byte[] buffer = new byte[16384];
            uint returned;
            bool ok = DeviceIoControl(handle, 0x000900A8, null, 0, buffer, (uint)buffer.Length, out returned, IntPtr.Zero);
            CloseHandle(handle);
            if (!ok || returned < 12 || BitConverter.ToUInt32(buffer, 0) != 0x8000001B) { return null; }
            int count = (int)BitConverter.ToUInt32(buffer, 8);
            var strings = new List<string>();
            int offset = 12;
            for (int index = 0; index < count && offset < (int)returned - 1; index++) {
                int end = offset;
                while (end + 1 < (int)returned && (buffer[end] != 0 || buffer[end + 1] != 0)) { end += 2; }
                if (end + 1 >= (int)returned) { return null; }
                strings.Add(Encoding.Unicode.GetString(buffer, offset, end - offset));
                offset = end + 2;
            }
            return strings.ToArray();
        }
    }
}
'@ -ErrorAction Stop
    }
    return [CaelestiaReparse.AppExecLink]::Read($Path)
}

# The verified Store package must own the alias the launcher persists. The
# first recorded string names the package family (and its entry point), the
# third names the executable the alias activates.
function Test-CaelestiaStorePowerShellAlias($Package) {
    $alias = Get-CaelestiaStorePowerShellAlias
    $osLocal = Get-CaelestiaOsLocalAppData
    if (-not (Test-Path -LiteralPath $alias -PathType Leaf)) { return $false }
    $aliasParent = Split-Path -Parent $alias
    if ((Split-Path -Leaf $aliasParent) -cne 'Microsoft.PowerShell_8wekyb3d8bbwe') { return $false }
    if (-not (Test-CaelestiaNoReparseDirectoryChain $aliasParent $osLocal)) { return $false }
    try {
        $fields = Read-CaelestiaAppExecLink $alias
        if (-not $fields -or $fields.Count -lt 3) { return $false }
        # The link's recorded package id and entry point must name the verified
        # package exactly; a looser match would accept an alias another package
        # family owns.
        if ($fields[0] -cne 'Microsoft.PowerShell_8wekyb3d8bbwe') { return $false }
        if ($fields[1] -cne 'Microsoft.PowerShell_8wekyb3d8bbwe!App') { return $false }
        $target = Get-CaelestiaLongPath (Join-Path ([string]$Package.InstallLocation) 'pwsh.exe')
        if (-not [string]::Equals((Get-CaelestiaLongPath $fields[2]), $target, [StringComparison]::OrdinalIgnoreCase)) { return $false }
        return $true
    } catch {
        return $false
    }
}

function Find-CaelestiaPowerShell7([version]$MinimumVersion = (Get-CaelestiaPowerShellMinimumVersion)) {
    # Shared file probe: the candidate must exist, carry no reparse point up to
    # a trusted root, be a PE x64 image and meet the minimum. ProductVersion can
    # carry a "+sha" build suffix and FileVersion a four-part form; both parse
    # cleanly through ConvertTo-CaelestiaVersionOrNull.
    $probeFile = {
        param([string]$Candidate, [string]$Boundary)
        if (-not (Test-Path -LiteralPath $Candidate -PathType Leaf)) { return $null }
        if (-not (Test-CaelestiaNoReparse $Candidate $Boundary)) { return $null }
        if (-not (Test-CaelestiaX64Executable $Candidate)) { return $null }
        $info = [Diagnostics.FileVersionInfo]::GetVersionInfo($Candidate)
        $version = ConvertTo-CaelestiaVersionOrNull $info.ProductVersion
        if (-not $version) { $version = ConvertTo-CaelestiaVersionOrNull $info.FileVersion }
        if (-not $version -or $version -lt $MinimumVersion) { return $null }
        return $version
    }
    # Shared Store verification: the exact PowerShell package family, x64
    # architecture, a package version meeting the floor, a verified package
    # pwsh.exe, and an execution alias this package verifiably owns. Returns the
    # package version on success so the caller can report it.
    $verifyStorePackage = {
        param()
        $pkg = Get-AppxPackage -Name 'Microsoft.PowerShell' -ErrorAction Stop |
            Where-Object { $_.PackageFamilyName -ceq 'Microsoft.PowerShell_8wekyb3d8bbwe' -and
                $_.Architecture -eq 'X64' } | Select-Object -First 1
        if (-not $pkg) { return $null }
        $pkgVersion = ConvertTo-CaelestiaVersionOrNull ([string]$pkg.Version)
        if (-not $pkgVersion -or $pkgVersion -lt $MinimumVersion) { return $null }
        $location = [string]$pkg.InstallLocation
        $packageExe = if ($location) { Join-Path $location 'pwsh.exe' } else { '' }
        $windowsAppsRoot = Split-Path -Parent $location
        if (-not $packageExe -or -not $windowsAppsRoot -or -not (& $probeFile $packageExe $windowsAppsRoot)) {
            return $null
        }
        if (-not (Test-CaelestiaStorePowerShellAlias $pkg)) { return $null }
        return $pkgVersion
    }
    # 1) The current host is already a suitable PowerShell 7. Prefer it so a
    #    running install keeps its own exact binary rather than discovering a
    #    different one. A Store host must be persisted through its stable
    #    alias; the versioned package folder dies on the next auto-update.
    if ($PSVersionTable.PSEdition -eq 'Core' -and [Environment]::Is64BitProcess -and
        $PSVersionTable.PSVersion -ge $MinimumVersion) {
        try {
            $self = [IO.Path]::GetFullPath([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName).TrimEnd('\')
            $programFilesRoot = [IO.Path]::GetFullPath($env:ProgramFiles).TrimEnd('\')
            $osLocal = [IO.Path]::GetFullPath((Get-CaelestiaOsLocalAppData)).TrimEnd('\')
            $programsRoot = [IO.Path]::GetFullPath((Join-Path $osLocal 'Programs')).TrimEnd('\')
            if ($self -match 'WindowsApps\\Microsoft\.PowerShell_.*_x64__8wekyb3d8bbwe\\pwsh\.exe$') {
                # Reuse the current host only when the owning package survives
                # the same full verification the discovery path applies.
                $selfPackageVersion = & $verifyStorePackage
                if ($selfPackageVersion) {
                    return [pscustomobject]@{
                        Path = (Get-CaelestiaStorePowerShellAlias)
                        Version = [version]"$($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor).$($PSVersionTable.PSVersion.Patch)"
                        Kind = 'msix'
                    }
                }
            } elseif ($self.StartsWith($programFilesRoot + '\', [StringComparison]::OrdinalIgnoreCase) -and
                (& $probeFile $self $programFilesRoot)) {
                return [pscustomobject]@{ Path = $self; Version = [version]$PSVersionTable.PSVersion; Kind = 'msi' }
            } else {
                if ($self.StartsWith($programsRoot + '\', [StringComparison]::OrdinalIgnoreCase) -and
                    (& $probeFile $self $osLocal)) {
                    return [pscustomobject]@{ Path = $self; Version = [version]$PSVersionTable.PSVersion; Kind = 'msi' }
                }
            }
        } catch { }
    }
    # 2) Registered MSI installs. Read the native hive so a WOW64 caller still
    #    sees the 64-bit registration.
    $baseKey = $null
    try {
        $baseKey = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
            [Microsoft.Win32.RegistryHive]::LocalMachine, [Microsoft.Win32.RegistryView]::Registry64)
        $installed = $baseKey.OpenSubKey('SOFTWARE\Microsoft\PowerShellCore\InstalledVersions')
        if ($installed) {
            try {
                $candidates = @()
                foreach ($name in $installed.GetSubKeyNames()) {
                    $sub = $installed.OpenSubKey($name)
                    if (-not $sub) { continue }
                    try {
                        $location = [string]$sub.GetValue('InstallLocation')
                        $semantic = [string]$sub.GetValue('SemanticVersion')
                        $version = $null
                        $version = ConvertTo-CaelestiaVersionOrNull $semantic
                        if (-not $location -or -not $version -or $version -lt $MinimumVersion) { continue }
                        $normalizedLocation = [IO.Path]::GetFullPath($location).TrimEnd('\')
                        $candidate = [IO.Path]::GetFullPath((Join-Path $normalizedLocation 'pwsh.exe')).TrimEnd('\')
                        # The registered location itself is not a trust
                        # boundary: the image must sit under Program Files or
                        # the per-user Programs root, be reparse-free up to
                        # that trusted root, be a PE x64 image, and carry a
                        # real version that still meets the floor.
                        $programFilesRoot = [IO.Path]::GetFullPath($env:ProgramFiles).TrimEnd('\')
                        $osLocal = [IO.Path]::GetFullPath((Get-CaelestiaOsLocalAppData)).TrimEnd('\')
                        $programsRoot = [IO.Path]::GetFullPath((Join-Path $osLocal 'Programs')).TrimEnd('\')
                        $trusted = $null
                        $boundary = $null
                        if ($normalizedLocation.Equals($programFilesRoot, [StringComparison]::OrdinalIgnoreCase) -or
                            $normalizedLocation.StartsWith($programFilesRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
                            $trusted = $programFilesRoot
                            $boundary = $programFilesRoot
                        } else {
                            if ($normalizedLocation.Equals($programsRoot, [StringComparison]::OrdinalIgnoreCase) -or
                                $normalizedLocation.StartsWith($programsRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
                                $trusted = $programsRoot
                                $boundary = $osLocal
                            }
                        }
                        if (-not $trusted) { continue }
                        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf) -or
                            -not (Test-CaelestiaNoReparse $candidate $boundary) -or
                            -not (Test-CaelestiaX64Executable $candidate)) { continue }
                        $info = [Diagnostics.FileVersionInfo]::GetVersionInfo($candidate)
                        $fileVersion = ConvertTo-CaelestiaVersionOrNull $info.ProductVersion
                        if (-not $fileVersion) { $fileVersion = ConvertTo-CaelestiaVersionOrNull $info.FileVersion }
                        if (-not $fileVersion -or $fileVersion -lt $MinimumVersion) { continue }
                        $stable = if ($semantic -match '-') { 0 } else { 1 }
                        $candidates += [pscustomobject]@{ Path = $candidate; Version = $fileVersion; Kind = 'msi'; Stable = $stable }
                    } finally { $sub.Dispose() }
                }
                $best = @($candidates | Sort-Object { $_.Stable }, { $_.Version } -Descending | Select-Object -First 1)
                if ($best.Count) { return $best[0] }
            } finally { $installed.Dispose() }
        }
    } catch { }
    finally { if ($baseKey) { $baseKey.Dispose() } }
    # 3) The standard MSI destination.
    $standard = Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'
    $standardVersion = & $probeFile $standard $env:ProgramFiles
    if ($standardVersion) {
        return [pscustomobject]@{ Path = $standard; Version = $standardVersion; Kind = 'msi' }
    }
    # 3b) The supported per-user install under the OS LocalAppData.
    $perUser = Join-Path (Get-CaelestiaOsLocalAppData) 'Programs\PowerShell\7\pwsh.exe'
    $perUserVersion = & $probeFile $perUser (Get-CaelestiaOsLocalAppData)
    if ($perUserVersion) {
        return [pscustomobject]@{ Path = $perUser; Version = $perUserVersion; Kind = 'msi' }
    }
    # 4) App Paths, only when it names a trusted Program Files image.
    try {
        $appPaths = Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\pwsh.exe' -ErrorAction Stop
        $appPath = [string]$appPaths.'(default)'
        if (-not $appPath) { $appPath = [string]$appPaths.Path }
        if ($appPath) {
            $appPath = $appPath.Trim('"')
            if ([IO.Path]::GetFileName($appPath) -ne 'pwsh.exe') { $appPath = Join-Path $appPath 'pwsh.exe' }
            $appPath = [IO.Path]::GetFullPath($appPath).TrimEnd('\')
            $programFilesRoot = [IO.Path]::GetFullPath($env:ProgramFiles).TrimEnd('\')
            if ($appPath.StartsWith($programFilesRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
                $appVersion = & $probeFile $appPath $programFilesRoot
                if ($appVersion) {
                    return [pscustomobject]@{ Path = $appPath; Version = $appVersion; Kind = 'msi' }
                }
            }
        }
    } catch { }
    # 5) The Microsoft Store package. Only its stable LOCALAPPDATA execution
    #    alias is persisted; the versioned package folder is replaced by
    #    automatic updates.
    try {
        $storeVersion = & $verifyStorePackage
        if ($storeVersion) {
            return [pscustomobject]@{ Path = (Get-CaelestiaStorePowerShellAlias); Version = [version]$storeVersion; Kind = 'msix' }
        }
    } catch { }
    return $null
}

function Get-CaelestiaPowerShellPath([version]$MinimumVersion = (Get-CaelestiaPowerShellMinimumVersion)) {
    $found = Find-CaelestiaPowerShell7 $MinimumVersion
    if ($found) { return [string]$found.Path }
    throw ('Caelestia requires 64-bit PowerShell ' + $MinimumVersion.ToString() +
        ' or newer, which is not installed. Install it with Install.cmd -InstallPrerequisites, ' +
        'the official MSI (' + (Get-CaelestiaPowerShellDownloadUrl) + '), ' +
        '`winget install --id Microsoft.PowerShell --source winget`, or the Microsoft Store, then retry.')
}

# Rollback compatibility: a retained payload whose supervisor source still
# uses System.Web.Script.Serialization cannot compile on .NET Core, so it must
# keep running on inbox Windows PowerShell 5.1. Anything else gets PowerShell 7.
# A payload can also record a higher PowerShell floor than the product default
# (install.json powerShellMinimumVersion, written by the release installer):
# the resolved host must satisfy the higher of the two.
function Get-CaelestiaPayloadMinimumPowerShellVersion([string]$RuntimePrefix) {
    $minimum = Get-CaelestiaPowerShellMinimumVersion
    $manifest = Join-Path $RuntimePrefix 'install.json'
    if (Test-Path -LiteralPath $manifest -PathType Leaf) {
        try {
            $record = Get-Content -LiteralPath $manifest -Raw -Encoding UTF8 | ConvertFrom-Json
            $declared = ConvertTo-CaelestiaVersionOrNull ([string]$record.powerShellMinimumVersion)
            if ($declared -and $declared -gt $minimum) { $minimum = $declared }
        } catch { }
    }
    return $minimum
}

function Get-CaelestiaPayloadPowerShellPath([string]$RuntimePrefix) {
    $source = Join-Path $RuntimePrefix 'DesktopTakeover.cs'
    if (Test-Path -LiteralPath $source -PathType Leaf) {
        try {
            if ([IO.File]::ReadAllText($source).Contains('System.Web.Script.Serialization')) {
                return Get-WindowsPowerShellPath
            }
        } catch { }
    }
    return Get-CaelestiaPowerShellPath (Get-CaelestiaPayloadMinimumPowerShellVersion $RuntimePrefix)
}

# True only when this running process IS the verified target executable (so an
# older Core process never runs a payload that resolved a newer pwsh.exe).
function Test-CaelestiaCurrentHostMatchesTarget([string]$TargetHost) {
    $targetEdition = if ((Split-Path -Leaf $TargetHost) -ieq 'powershell.exe') { 'Desktop' } else { 'Core' }
    if ($targetEdition -cne [string]$PSVersionTable.PSEdition) { return $false }
    try {
        $self = Get-CaelestiaLongPath ([Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
        $resolvedTarget = Get-CaelestiaLongPath $TargetHost
        if ([string]::Equals($self, $resolvedTarget, [StringComparison]::OrdinalIgnoreCase)) { return $true }
        # A Store execution alias launches the versioned WindowsApps image.
        $aliasParent = Split-Path -Parent $resolvedTarget
        if ((Split-Path -Leaf $aliasParent) -ceq 'Microsoft.PowerShell_8wekyb3d8bbwe') {
            $fields = Read-CaelestiaAppExecLink $resolvedTarget
            if ($fields -and $fields.Count -ge 3) {
                $aliasTarget = Get-CaelestiaLongPath $fields[2]
                if ([string]::Equals($self, $aliasTarget, [StringComparison]::OrdinalIgnoreCase)) { return $true }
            }
        }
    } catch { }
    return $false
}

# Invoke a payload's Start-Caelestia.ps1 on the host it targets, preserving the
# exact bound-parameter set the caller built. Payload commands always run
# out-of-process through a small encoded bootstrap that rebuilds the hashtable
# and splats it. PowerShell cannot unload DesktopTakeover assemblies, so even a
# same-edition incoming payload must never share a process with the outgoing
# version's assembly during an update. The bootstrap also preserves values the
# -File dispatcher would corrupt: a bound switch set to $false, an empty string,
# embedded quotes and a trailing backslash. The child's exit code is recorded on
# $global:CaelestiaLastPayloadExitCode before a nonzero exit throws, so a caller
# that needs the exact code can exit with it instead of 1.
function Invoke-CaelestiaPayloadCommand([string]$RuntimePrefix, [hashtable]$Arguments) {
    # Reset before discovery so a discovery failure never reuses a stale code.
    $global:CaelestiaLastPayloadExitCode = 0
    $payloadScript = Join-Path $RuntimePrefix 'Start-Caelestia.ps1'
    $targetHost = Get-CaelestiaPayloadPowerShellPath $RuntimePrefix
    $targetEdition = if ((Split-Path -Leaf $targetHost) -ieq 'powershell.exe') { 'Desktop' } else { 'Core' }
    $argsCopy = @{}
    foreach ($key in @($Arguments.Keys)) { $argsCopy[$key] = $Arguments[$key] }
    # The payload always runs against its own directory: a Start needs qs.exe
    # and the shell files beside it, and the stable install root is never a
    # valid -Prefix for a versioned payload's own record.
    $argsCopy['Prefix'] = $RuntimePrefix
    # Serialize the bound set as typed entries. SwitchParameter serializes as a
    # bool that binds positionally, so kind carries it separately and the
    # bootstrap rebuilds a real SwitchParameter with IsPresent from the value.
    # Every string travels base64-encoded UTF-8: PowerShell 7.5+ ConvertFrom-Json
    # coerces ISO-looking strings into [DateTime], which would reach the child as
    # a culture-formatted date instead of the exact caller value.
    $entries = [Collections.Generic.List[hashtable]]::new()
    foreach ($key in @($argsCopy.Keys)) {
        $value = $argsCopy[$key]
        $entry = @{ name = [string]$key; kind = 'string-b64';
            value = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$value)) }
        if ($value -is [System.Management.Automation.SwitchParameter]) {
            $entry.kind = 'switch'
            $entry.value = [bool]$value.IsPresent
        } elseif ($value -is [bool]) {
            $entry.kind = 'bool'
            $entry.value = [bool]$value
        } elseif ($value -is [int] -or $value -is [long] -or $value -is [byte] -or $value -is [int16]) {
            $entry.kind = 'int'
            $entry.value = [long]$value
        }
        $entries.Add($entry)
    }
    $json = ConvertTo-Json -InputObject @($entries) -Compress -Depth 4
    $argsB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
    $scriptB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($payloadScript))
    # 5.1+7 compatible bootstrap: no classes, no ::new on types that lack it
    # under 5.1 rules, no ternary. SwitchParameter construction uses the full
    # type name so -Switch:$false stays bound with IsPresent=$false and the
    # payload's $PSBoundParameters.ContainsKey check still observes it.
    $bootstrap = @'
$ErrorActionPreference = 'Stop'
$json = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__ARGSB64__'))
$script = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__SCRIPTB64__'))
$entries = $json | ConvertFrom-Json
if ($null -ne $entries -and -not ($entries -is [Array])) { $entries = @($entries) }
$params = @{}
foreach ($e in $entries) {
    if ($e.kind -eq 'switch') {
        $params[$e.name] = New-Object System.Management.Automation.SwitchParameter([bool]$e.value)
    } elseif ($e.kind -eq 'bool') {
        $params[$e.name] = [bool]$e.value
    } elseif ($e.kind -eq 'int') {
        $params[$e.name] = [int]$e.value
    } else {
        $params[$e.name] = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String([string]$e.value))
    }
}
& $script @params
$code = $global:LASTEXITCODE
if ($null -ne $code -and $code -ne 0) { exit $code }
'@
    $bootstrap = $bootstrap.Replace('__ARGSB64__', $argsB64).Replace('__SCRIPTB64__', $scriptB64)
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrap))
    $global:LASTEXITCODE = 0
    & $targetHost -NoProfile -NonInteractive -ExecutionPolicy Bypass -OutputFormat Text -EncodedCommand $encoded
    $childExit = $global:LASTEXITCODE
    if ($null -eq $childExit) { $childExit = 0 }
    $global:CaelestiaLastPayloadExitCode = $childExit
    if ($childExit -ne 0) {
        throw "Caelestia payload command failed on $targetEdition host (exit $childExit)."
    }
}

# Assemblies needed to compile DesktopTakeover.cs. Passing
# -ReferencedAssemblies on .NET Core replaces the default reference list, so
# the full BCL facade plus WinForms set is spelled out. 5.1 only needs
# WinForms (and, for a legacy payload, System.Web.Extensions).
function Get-CaelestiaDesktopTakeoverReferences {
    if ($PSVersionTable.PSEdition -ne 'Core') { return @('System.Windows.Forms') }
    # Internal WinForms assemblies differ across .NET versions.
    # System.Private.Windows.Core exists on .NET 9+ but not on the .NET 8
    # runtime that hosts PowerShell 7.4; System.Windows.Forms.Primitives exists
    # on both. Include each internal assembly only when the current runtime's
    # own directories actually ship it, so the same source compiles on both
    # families. Probing the runtime directory (where [object].Assembly lives)
    # and the WinForms directory covers runtimes that split them.
    $optional = [Collections.Generic.List[string]]::new()
    $probeDirs = [Collections.Generic.List[string]]::new()
    try { $probeDirs.Add([IO.Path]::GetDirectoryName([object].Assembly.Location)) } catch { }
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $probeDirs.Add([IO.Path]::GetDirectoryName([System.Windows.Forms.Form].Assembly.Location))
    } catch { }
    foreach ($name in @('System.Windows.Forms.Primitives', 'System.Private.Windows.Core')) {
        $present = $false
        foreach ($dir in $probeDirs) {
            if ($dir -and (Test-Path -LiteralPath (Join-Path $dir ($name + '.dll')) -PathType Leaf)) { $present = $true; break }
        }
        if ($present) { $optional.Add($name) }
    }
    return @(
        'System.Windows.Forms'
    ) + $optional + @(
        'System.Drawing.Primitives', 'System.Drawing.Common',
        'System.Threading', 'System.Threading.Thread',
        'System.Diagnostics.Process',
        'System.Collections', 'System.Collections.Specialized',
        'System.ComponentModel.Primitives',
        'System.Linq', 'System.ObjectModel',
        'System.Runtime', 'System.Runtime.Extensions', 'System.Runtime.InteropServices',
        'System.Text.RegularExpressions',
        'Microsoft.Win32.Registry', 'Microsoft.Win32.Primitives',
        'System.Security.Principal', 'System.Security.Principal.Windows', 'System.Security.Claims',
        'netstandard'
    )
}

# Load the supervisor type once, preferring the compiled payload DLL and
# falling back to source when the DLL is missing or targets the other CLR. A
# legacy .NET Framework DLL fails to load on Core and a Core build fails on
# Desktop; either way the source compiles cleanly for the current runtime.
# PowerShell cannot unload a type once it is loaded. A silent type-present
# no-op is therefore unsafe during version activation: prove that the loaded
# image came from this payload's input bytes, or refuse the mismatched payload
# clearly instead of running new scripts against an old supervisor protocol.
function Import-CaelestiaDesktopTakeover([string]$ScriptRoot = $PSScriptRoot, [switch]$SourceOnly) {
    $dll = Join-Path $ScriptRoot 'DesktopTakeover.dll'
    $source = Join-Path $ScriptRoot 'DesktopTakeover.cs'
    $useDll = $false
    if (-not $SourceOnly -and (Test-Path -LiteralPath $dll -PathType Leaf) -and (Test-CaelestiaDesktopTakeoverBuildMetadata $ScriptRoot)) {
        try { $useDll = Test-CaelestiaDesktopTakeoverAssembly $dll } catch { $useDll = $false }
    }
    $inputPath = $(if ($useDll) { $dll } else { $source })
    if (-not (Test-Path -LiteralPath $inputPath -PathType Leaf)) { throw "Desktop takeover input is missing: $inputPath" }
    $inputHash = (Get-FileHash -LiteralPath $inputPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $inputKind = $(if ($useDll) { 'assembly' } else { 'source' })
    $type = 'Caelestia.Takeover.Supervisor' -as [type]
    if ($type) {
        $record = $global:CaelestiaDesktopTakeoverInput
        if ($record -and $record.Kind -eq $inputKind -and $record.Sha256 -eq $inputHash) { return }
        $loadedPath = ''
        try { $loadedPath = [string]$type.Assembly.Location } catch { }
        # No receipt means the bytes on disk may no longer be the image
        # already loaded. Its location is useful only for the diagnostic.
        $loadedDescription = $(if ($loadedPath) { $loadedPath } else { 'an in-memory or source-compiled assembly' })
        throw ("A different Caelestia desktop takeover assembly is already loaded in this process ({0}); " +
            "the requested payload input is {1}. Start the payload command in a fresh PowerShell process.") -f $loadedDescription, $inputPath
    }
    if ($useDll) {
        try {
            Add-Type -Path $dll -ErrorAction Stop
            $global:CaelestiaDesktopTakeoverInput = [pscustomobject]@{ Kind = $inputKind; Sha256 = $inputHash; Path = $inputPath }
            return
        } catch {
            # A DLL that passed metadata but still fails to bind is not a
            # partial success: fall through and compile from source.
        }
    }
    Add-Type -Path $source -ReferencedAssemblies (Get-CaelestiaDesktopTakeoverReferences) -ErrorAction Stop
    $sourceHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant()
    $global:CaelestiaDesktopTakeoverInput = [pscustomobject]@{ Kind = 'source'; Sha256 = $sourceHash; Path = $source }
}

# A precompiled payload DLL is only trusted when its build metadata exists and
# names this host: the same CLR major version and the same PowerShell edition.
# Missing or partial metadata means the DLL came from an untracked build, so it
# is never loaded even when it happens to match.
function Test-CaelestiaDesktopTakeoverBuildMetadata([string]$ScriptRoot) {
    $metadataPath = Join-Path $ScriptRoot 'DesktopTakeover.build.json'
    if (-not (Test-Path -LiteralPath $metadataPath -PathType Leaf)) { return $false }
    try {
        $meta = Get-Content -LiteralPath $metadataPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $builtClr = [string]$meta.clrVersion
        $builtEdition = [string]$meta.psEdition
        if (-not $builtClr -or -not $builtEdition) { return $false }
        $builtMajor = ($builtClr -split '\.')[0]
        if ($builtMajor -cne ([Environment]::Version.Major).ToString()) { return $false }
        if ($builtEdition -cne [string]$PSVersionTable.PSEdition) { return $false }
        return $true
    } catch {
        return $false
    }
}

# The public contract the installed scripts bind against. Every required method
# signature (name + exact parameter types), every required public static
# property getter (name + type), and every required public instance field
# (name + exact type) must be present. A DLL missing any member or overload is
# never loaded: the contract failure compiles the source instead.
function Get-CaelestiaDesktopTakeoverContract {
    return [ordered]@{
        Methods = [ordered]@{
            'Caelestia.Takeover.Supervisor' = [ordered]@{
                Run = @(
                    'System.String,System.Boolean,System.Boolean,System.Boolean',
                    'System.String,System.Boolean,System.Boolean,System.Boolean,System.Boolean'
                )
                RecoverActive = @(
                    '',
                    'System.Int32'
                )
            }
            'Caelestia.Takeover.SupervisorSafety' = [ordered]@{
                Log = @('System.Action')
                Fail = @('System.Action,System.Action')
            }
            'Caelestia.Takeover.Native' = [ordered]@{
                Capture = @('')
                Restore = @('Caelestia.Takeover.Snapshot,System.Int32')
                RestoreOwned = @('Caelestia.Takeover.Snapshot,System.Int32,System.Boolean,System.Boolean')
                Hide = @('System.Boolean')
                RemoveStaleAppBars = @('System.Int32')
                LoadSnapshot = @('System.String')
                SerializeSnapshot = @('Caelestia.Takeover.Snapshot')
                DeserializeSnapshot = @('System.String')
                DeserializeLaunch = @('System.String')
                SerializeTaskbarAction = @('Caelestia.Takeover.TaskbarAction')
            }
            'Caelestia.Takeover.TakeoverJson' = [ordered]@{
                Serialize = @('System.Object')
                Deserialize = @('System.String')
                DeserializeObject = @('System.String')
            }
        }
        Properties = [ordered]@{
            'Caelestia.Takeover.Supervisor' = [ordered]@{
                MutexName = 'System.String'
            }
            'Caelestia.Takeover.Native' = [ordered]@{
                ExplorerWorkDeferred = 'System.Boolean'
            }
        }
        Fields = [ordered]@{
            'Caelestia.Takeover.Launch' = [ordered]@{
                Executable = 'System.String'
                Arguments = 'System.String'
                WorkingDirectory = 'System.String'
                ConfigPath = 'System.String'
                StateDirectory = 'System.String'
                StdoutPath = 'System.String'
                StderrPath = 'System.String'
                InstallLockKey = 'System.String'
                PowerShellPath = 'System.String'
                RestartFrozenShell = 'System.Boolean'
                RestoreWorkAreas = 'System.Boolean'
                Environment = 'System.Collections.Generic.Dictionary`2[System.String,System.String]'
                TestWindowOwners = 'System.Collections.Generic.List`1[System.Int32]'
            }
            'Caelestia.Takeover.Snapshot' = [ordered]@{
                TaskbarFlags = 'System.UInt64'
                TaskbarFlagsSaved = 'System.Boolean'
                MultiMonitorTaskbarSaved = 'System.Boolean'
                MultiMonitorTaskbar = 'System.Nullable`1[System.Int32]'
                Displays = 'System.Collections.Generic.List`1[Caelestia.Takeover.Display]'
                Bars = 'System.Collections.Generic.List`1[Caelestia.Takeover.Bar]'
                Regions = 'System.Collections.Generic.List`1[Caelestia.Takeover.SavedRegion]'
            }
        }
    }
}

function Get-CaelestiaNormalizedTypeName([type]$Type) {
    if (-not $Type.IsGenericType) { return $Type.FullName }
    $genericDef = $Type.GetGenericTypeDefinition().FullName
    $argNames = @($Type.GetGenericArguments() | ForEach-Object { Get-CaelestiaNormalizedTypeName $_ })
    return ($genericDef + '[' + ($argNames -join ',') + ']')
}

# Check one loaded or reflection-only assembly against the takeover contract.
# Every required public static method overload (exact parameter types), every
# required public static getter property (exact type), and every required
# public instance field (exact type) must match. Works for both live Type
# objects (Core collectible context) and reflection-only Type objects (Desktop).
function Test-CaelestiaTakeoverContract($Assembly) {
    $contract = Get-CaelestiaDesktopTakeoverContract
    $types = @{}
    foreach ($type in $Assembly.GetTypes()) { $types[$type.FullName] = $type }
    foreach ($name in $contract.Methods.Keys) {
        if (-not $types.ContainsKey($name)) { return $false }
        $methods = @{}
        foreach ($method in $types[$name].GetMethods([Reflection.BindingFlags]'Public,Static')) {
            if (-not $methods.ContainsKey($method.Name)) { $methods[$method.Name] = @() }
            $sig = (@($method.GetParameters() | ForEach-Object { Get-CaelestiaNormalizedTypeName $_.ParameterType }) -join ',')
            $methods[$method.Name] += $sig
        }
        foreach ($required in $contract.Methods[$name].Keys) {
            if (-not $methods.ContainsKey($required)) { return $false }
            # Every listed overload signature must be present (not just one).
            foreach ($requiredSig in $contract.Methods[$name][$required]) {
                if ($methods[$required] -cnotcontains [string]$requiredSig) { return $false }
            }
        }
    }
    foreach ($name in $contract.Properties.Keys) {
        if (-not $types.ContainsKey($name)) { return $false }
        foreach ($propName in $contract.Properties[$name].Keys) {
            $prop = $types[$name].GetProperty($propName, [Reflection.BindingFlags]'Public,Static')
            if (-not $prop -or -not $prop.GetGetMethod($false)) { return $false }
            if ((Get-CaelestiaNormalizedTypeName $prop.PropertyType) -cne $contract.Properties[$name][$propName]) { return $false }
        }
    }
    foreach ($name in $contract.Fields.Keys) {
        if (-not $types.ContainsKey($name)) { return $false }
        $fields = @{}
        foreach ($field in $types[$name].GetFields([Reflection.BindingFlags]'Public,Instance')) {
            $fields[$field.Name] = Get-CaelestiaNormalizedTypeName $field.FieldType
        }
        foreach ($required in $contract.Fields[$name].Keys) {
            if (-not $fields.ContainsKey($required)) { return $false }
            if ($fields[$required] -cne $contract.Fields[$name][$required]) { return $false }
        }
    }
    return $true
}

# Inspect the payload DLL without loading it into the default load context.
# No reference may pull in System.Web.Extensions and every referenced assembly
# must fully resolve on this runtime, so an image built against a different
# BCL is refused rather than partially trusted. The required public types,
# method signatures and fields are checked against the live contract. On Core
# the DLL is inspected inside a collectible AssemblyLoadContext that is always
# unloaded; on Desktop the reflection-only context answers the same shape.
function Test-CaelestiaDesktopTakeoverAssembly([string]$Path) {
    if ($PSVersionTable.PSEdition -eq 'Core') {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop | Out-Null
        $alc = $null
        try {
            $alc = [System.Runtime.Loader.AssemblyLoadContext]::new('caelestia-takeover-probe', $true)
            $stream = [IO.MemoryStream]::new([IO.File]::ReadAllBytes($Path))
            try {
                $assembly = $alc.LoadFromStream($stream)
            } finally { $stream.Dispose() }
            foreach ($reference in $assembly.GetReferencedAssemblies()) {
                if ($reference.Name -ceq 'System.Web.Extensions') { return $false }
                try {
                    $null = [System.Runtime.Loader.AssemblyLoadContext]::Default.LoadFromAssemblyName($reference)
                } catch {
                    return $false
                }
            }
            return Test-CaelestiaTakeoverContract $assembly
        } catch {
            return $false
        } finally {
            if ($null -ne $alc) { $alc.Unload() }
        }
    }
    # Desktop: the reflection-only context inspects metadata without committing
    # the image to the load context. Every referenced assembly must resolve in
    # the reflection-only context too, so the full assembly identity is checked
    # rather than a display name. Any loader failure or missing member fails
    # closed so the source is compiled instead.
    try {
        $assembly = [Reflection.Assembly]::ReflectionOnlyLoadFrom($Path)
        foreach ($reference in $assembly.GetReferencedAssemblies()) {
            if ($reference.Name -ceq 'System.Web.Extensions') { return $false }
            $null = [Reflection.Assembly]::ReflectionOnlyLoad($reference.FullName)
        }
        return Test-CaelestiaTakeoverContract $assembly
    } catch {
        return $false
    }
}

# Test fixtures need a runnable executable, and PS 7 removed
# Add-Type -OutputType ConsoleApplication. Compile with the inbox .NET
# Framework compiler instead; it exists on every Windows machine and fixture
# binaries do not need Core.
function New-CaelestiaTestExecutable([string]$OutputPath, [string]$Source, [string[]]$ReferencedAssemblies = @()) {
    $compiler = Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) {
        $compiler = Join-Path $env:SystemRoot 'Microsoft.NET\Framework\v4.0.30319\csc.exe'
    }
    if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) { throw 'The inbox .NET Framework C# compiler is missing.' }
    $sourcePath = $OutputPath + '.cs'
    [IO.File]::WriteAllText($sourcePath, $Source, [Text.UTF8Encoding]::new($false))
    # Concatenate before the array literal: in an argument list ',' binds
    # tighter than '+', so '/out:' + $Path would append two arguments.
    $arguments = @('/nologo', '/target:exe', ('/out:' + $OutputPath))
    foreach ($reference in $ReferencedAssemblies) { $arguments += ('/r:' + $reference) }
    $arguments += $sourcePath
    try {
        $output = & $compiler @arguments 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { throw "csc.exe exited $LASTEXITCODE`n$output" }
    } finally {
        if (Test-Path -LiteralPath $sourcePath) { [IO.File]::Delete($sourcePath) }
    }
}

# Resolve Python without consulting PATH. SystemRoot's py.exe is preferred;
# PyLauncher and PythonCore registry keys are the only fallback. An explicit
# override remains available to tests and support scenarios.
function Test-CaelestiaLocalExecutableFile([string]$Path, [string]$RequiredLeaf = '') {
    if (-not $Path -or -not [IO.Path]::IsPathRooted($Path) -or $Path.IndexOfAny([char[]]@('"', "`r", "`n")) -ge 0) { return $false }
    try {
        $full = Get-CaelestiaLongPath $Path
        if ($RequiredLeaf -and (Split-Path -Leaf $full) -cne $RequiredLeaf) { return $false }
        if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { return $false }
        $item = Get-Item -LiteralPath $full -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -or $full -match '(?i)[\/]WindowsApps[\/]') { return $false }
        return $full
    } catch { return $false }
}

function Get-CaelestiaPythonRegistryCandidate([string]$Root) {
    try {
        $key = Get-ItemProperty -LiteralPath $Root -ErrorAction SilentlyContinue
        if (-not $key) { return '' }
        foreach ($value in @([string]$key.'(default)', [string]$key.InstallDir, [string]$key.InstallPath)) {
            if (-not $value) { continue }
            $candidate = $value.Trim().TrimEnd('\')
            if ((Split-Path -Leaf $candidate) -cne 'py.exe') { $candidate = Join-Path $candidate 'py.exe' }
            $valid = Test-CaelestiaLocalExecutableFile $candidate 'py.exe'
            if ($valid) { return $valid }
        }
    } catch { }
    return ''
}

function Resolve-CaelestiaPythonHost([string]$Python = '') {
    if ($Python) {
        $override = Test-CaelestiaLocalExecutableFile ([IO.Path]::GetFullPath($Python))
        if (-not $override) { throw "Python override is not an existing local executable file: $Python" }
        return [pscustomobject]@{ Executable = $override; IsLauncher = ((Split-Path -Leaf $override) -ieq 'py.exe') }
    }
    $systemLauncher = Test-CaelestiaLocalExecutableFile (Join-Path $env:SystemRoot 'py.exe') 'py.exe'
    if ($systemLauncher) { return [pscustomobject]@{ Executable = $systemLauncher; IsLauncher = $true } }
    foreach ($root in @('HKLM:\SOFTWARE\Python\PyLauncher', 'HKLM:\SOFTWARE\Wow6432Node\Python\PyLauncher', 'HKCU:\SOFTWARE\Python\PyLauncher')) {
        $candidate = Get-CaelestiaPythonRegistryCandidate $root
        if ($candidate) { return [pscustomobject]@{ Executable = $candidate; IsLauncher = $true } }
    }
    foreach ($hive in @('HKLM:\SOFTWARE\Python\PythonCore', 'HKLM:\SOFTWARE\Wow6432Node\Python\PythonCore', 'HKCU:\SOFTWARE\Python\PythonCore')) {
        foreach ($version in @(Get-ChildItem -LiteralPath $hive -ErrorAction SilentlyContinue | Sort-Object Name -Descending)) {
            try {
                $install = Get-ItemProperty -LiteralPath (Join-Path $version.PSPath 'InstallPath') -ErrorAction SilentlyContinue
                if (-not $install) { continue }
                foreach ($candidate in @([string]$install.ExecutablePath, [string]$install.'(default)')) {
                    if (-not $candidate) { continue }
                    $candidate = $candidate.Trim().TrimEnd('\')
                    if ((Split-Path -Leaf $candidate) -ine 'python.exe') { $candidate = Join-Path $candidate 'python.exe' }
                    $valid = Test-CaelestiaLocalExecutableFile $candidate 'python.exe'
                    if ($valid) { return [pscustomobject]@{ Executable = $valid; IsLauncher = $false } }
                }
            } catch { }
        }
    }
    throw 'the Python launcher/interpreter is not installed in SystemRoot or registered under Python\PyLauncher or Python\PythonCore'
}

# Read the scheme dependency lock exactly as the runtime payload sees it.
function Get-CaelestiaSchemeLock([string]$RuntimePrefix) {
    try {
        $lockPath = Join-Path $RuntimePrefix '..\sources.lock.json'
        if (Test-Path -LiteralPath (Join-Path $RuntimePrefix 'install.json')) {
            $installed = Join-Path $RuntimePrefix 'licenses\sources.lock.json'
            if (Test-Path -LiteralPath $installed -PathType Leaf) { $lockPath = $installed }
        }
        if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) { return $null }
        return (Get-Content -LiteralPath $lockPath -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Get-CaelestiaSchemeArchiveSha256([string]$RuntimePrefix) {
    $lock = Get-CaelestiaSchemeLock $RuntimePrefix
    if (-not $lock -or -not $lock.schemeCli) { return '' }
    return [string]$lock.schemeCli.archiveSha256
}

# Caelestia is a per-user Medium-integrity installation. Elevation is never a
# supported shortcut around prerequisite consent: a same-user elevated token
# creates High-IL named objects that the Medium-IL shell cannot release, and an
# over-the-shoulder token can write integration for the wrong user/session.
function Assert-CaelestiaInstallerNotElevated([object]$Elevated = $null, [string]$TokenUser = '', [string]$ConsoleSessionUser = '') {
    $isElevated = $false
    if ($null -ne $Elevated) { $isElevated = [bool]$Elevated }
    else {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [Security.Principal.WindowsPrincipal]::new($identity)
        $isElevated = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    if (-not $isElevated) { return }
    if (-not $TokenUser) { $TokenUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name }
    if (-not $ConsoleSessionUser) {
        try { $ConsoleSessionUser = [string](Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).UserName } catch { $ConsoleSessionUser = '' }
    }
    $elevationKind = 'same-user elevation'
    if ($ConsoleSessionUser -and $TokenUser -and $ConsoleSessionUser -ine $TokenUser) {
        $elevationKind = 'over-the-shoulder elevation'
    }
    throw (("Caelestia cannot be installed from an elevated PowerShell process ({0}). " +
        'Caelestia is a per-user Medium-integrity installation. Run Install.cmd or the installer again as the desktop user without administrator elevation. ' +
        'Same-user elevation creates High-integrity mutexes the Medium-integrity shell cannot release; over-the-shoulder elevation can write per-user integration for the wrong session. ' +
        'No Caelestia installation files were changed.') -f $elevationKind)
}

# Scheme CLI revision pinned by a repository or installed payload.
function Get-CaelestiaSchemeRevision([string]$RuntimePrefix) {
    $lock = Get-CaelestiaSchemeLock $RuntimePrefix
    if (-not $lock -or -not $lock.schemeCli) { return '' }
    return [string]$lock.schemeCli.revision
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
# the same freshly computed identity: the CLI revision and archive digest,
# the wheel lock, the helper and the fcntl shim copied into the venv.
function Get-CaelestiaSchemeIdentity([string]$RuntimePrefix, [string]$Revision) {
    try {
        $directory = Join-Path $RuntimePrefix 'scheme'
        $hashes = @{}
        $material = [Text.StringBuilder]::new()
        $null = $material.Append($Revision)
        $schemeLock = Get-CaelestiaSchemeLock $RuntimePrefix
        if ($schemeLock -and $schemeLock.schemeCli.revision -ceq $Revision -and $schemeLock.schemeCli.archiveSha256) {
            $null = $material.Append("`narchiveSha256=").Append([string]$schemeLock.schemeCli.archiveSha256)
        }
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
    # Never activate an App Execution Alias, an install manager or a PATH shim.
    if ($env:PYLAUNCHER_ALLOW_INSTALL) {
        throw 'Optional scheme preparation requires automatic Python installation to be disabled; no Python launcher was executed.'
    }
    try { $hostSpec = Resolve-CaelestiaPythonHost } catch { return '' }
    $arguments = $(if ($hostSpec.IsLauncher) { '-3 -c "import sys; print(sys.executable)"' } else { '-c "import sys; print(sys.executable)"' })
    $result = Invoke-CaelestiaBounded $hostSpec.Executable $arguments $TimeoutSeconds
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
function Install-CaelestiaSchemeRuntime([string]$RuntimePrefix, [string]$ProfileRoot, [string]$Python = '', [string]$CliArchive = '') {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $record = $null
    $message = ''
    try {
        $scriptPath = Join-Path $RuntimePrefix 'Install-SchemeRuntime.ps1'
        $targetHost = Get-CaelestiaPayloadPowerShellPath $RuntimePrefix
        $schemeArguments = @{ ProfileRoot = $ProfileRoot; LockWaitSeconds = 900 }
        if ($Python) { $schemeArguments['Python'] = $Python }
        if ($CliArchive) { $schemeArguments['CliArchive'] = $CliArchive }
        if (Test-CaelestiaCurrentHostMatchesTarget $targetHost) {
            $record = & $scriptPath @schemeArguments |
                Select-Object -Last 1 | ConvertFrom-Json
        } else {
            $hostArguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $scriptPath,
                '-ProfileRoot', $ProfileRoot, '-LockWaitSeconds', '900')
            if ($Python) { $hostArguments += @('-Python', $Python) }
            if ($CliArchive) { $hostArguments += @('-CliArchive', $CliArchive) }
            $global:LASTEXITCODE = 0
            $output = & $targetHost @hostArguments
            if ($global:LASTEXITCODE -and $global:LASTEXITCODE -ne 0) {
                throw "Scheme provisioning exited with code $($global:LASTEXITCODE)."
            }
            $record = $output | Select-Object -Last 1 | ConvertFrom-Json
        }
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
    # ConvertFrom-Json under PowerShell 7 turns an ISO timestamp into a
    # DateTime; casting that back to [string] yields the caller's locale form
    # ("11/20/2026 02:30:00"), not the 'o' format the record contract needs.
    # Emit UTC ISO text for every typed or string form.
    try {
        $createdVal = (Get-Content -LiteralPath (Join-Path $GenerationRoot 'generation.json') -Raw -Encoding UTF8 | ConvertFrom-Json).created
        if ($createdVal -is [DateTimeOffset]) { $created = $createdVal.UtcDateTime.ToString('o') }
        elseif ($createdVal -is [DateTime]) { $created = $createdVal.ToUniversalTime().ToString('o') }
        else { $created = [string]$createdVal }
    } catch { }
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

# The scheduled launcher and the transactional installer can race: Task
# Scheduler marks the launcher Ready as soon as the short-lived PowerShell
# launcher exits successfully, while the supervised shell it started keeps
# running. This per-launch record is the launcher's durable account of that
# handoff. It is small public state only and is replaced atomically.
function Get-CaelestiaReadinessRecordPath([string]$Prefix, [string]$LaunchId) {
    if ($LaunchId -notmatch '^[A-Za-z0-9][A-Za-z0-9-]{0,95}$') { throw 'Invalid Caelestia launch identifier.' }
    $profile = ''
    try { $profile = [string](Read-CaelestiaInstall $Prefix).profile } catch { }
    if (-not $profile) { $profile = Join-Path $Prefix 'profile' }
    return Join-Path $profile ('runtime\launch-readiness\' + $LaunchId + '.json')
}

function Write-CaelestiaReadinessRecord([string]$Path, [string]$GenerationId, [int]$ProcessId, [int]$ExitCode, [bool]$Ready, [string]$PayloadPath = '', [int]$SupervisorPid = 0) {
    if (-not $Path) { return }
    $directory = [IO.Path]::GetDirectoryName($Path)
    New-Item -ItemType Directory -Force -Path $directory | Out-Null
    Write-CaelestiaJsonAtomic $Path ([ordered]@{
        generationId = $GenerationId
        pid = $ProcessId
        exitCode = $ExitCode
        ready = $Ready
        payloadPath = $PayloadPath
        supervisorPid = $SupervisorPid
        timestampUtc = [DateTime]::UtcNow.ToString('o')
    })
}

function Read-CaelestiaReadinessRecord([string]$Path) {
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        $record = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $record.PSObject.Properties['generationId'] -or
            $null -eq $record.PSObject.Properties['pid'] -or
            $null -eq $record.PSObject.Properties['exitCode'] -or
            $null -eq $record.PSObject.Properties['ready'] -or
            $null -eq $record.PSObject.Properties['timestampUtc']) { return $null }
        return $record
    } catch {
        return $null
    }
}

function Test-CaelestiaReadyState($State, [string]$PreviousGeneration = '', [switch]$LegacyReady) {
    if (-not $State) { return $false }
    $ready = $State.lifecycle.ready -eq $true -or
        ($LegacyReady -and -not $State.PSObject.Properties['lifecycle'] -and $State.screens -gt 0 -and $State.windows.Count -eq $State.screens)
    return $ready -and (-not $PreviousGeneration -or $State.lifecycle.generation -ne $PreviousGeneration)
}

function Test-CaelestiaPayloadSupportsIdentity([string]$RuntimePrefix) {
    $shell = Join-Path $RuntimePrefix 'shell\shell.qml'
    if (-not [IO.File]::Exists($shell)) { return $false }
    $text = [IO.File]::ReadAllText($shell)
    return $text.Contains('payloadPath') -and $text.Contains('supervisorPid')
}

# New payloads publish the payload directory and supervisor owner in public
# IPC state. Requiring those fields keeps an already-running older payload,
# including a legacy payload that predates the fields, from satisfying a new
# activation. A restarted child is acceptable only under the same supervisor.
function Test-CaelestiaReadyIdentity($State, [string]$ExpectedPayload = '', [int]$ExpectedSupervisorPid = 0, [switch]$RequireIdentity) {
    if (-not $State -or -not $State.PSObject.Properties['lifecycle'] -or -not $State.lifecycle) { return (-not $RequireIdentity) }
    $lifecycle = $State.lifecycle
    $hasPayload = $null -ne $lifecycle.PSObject.Properties['payloadPath']
    if ($hasPayload -and $ExpectedPayload -and -not (Test-CaelestiaSamePath ([string]$lifecycle.payloadPath) $ExpectedPayload)) { return $false }
    if ($RequireIdentity -and $ExpectedPayload -and -not $hasPayload) { return $false }
    $hasSupervisor = $null -ne $lifecycle.PSObject.Properties['supervisorPid']
    if ($hasSupervisor -and $ExpectedSupervisorPid -gt 0 -and [int]$lifecycle.supervisorPid -ne $ExpectedSupervisorPid) { return $false }
    if ($RequireIdentity -and $ExpectedSupervisorPid -gt 0 -and -not $hasSupervisor) { return $false }
    return $true
}

function Get-CaelestiaExpectedPayload([string]$Prefix) {
    if (Get-Command Resolve-CaelestiaRuntimePrefix -ErrorAction SilentlyContinue) {
        try { return Resolve-CaelestiaRuntimePrefix $Prefix } catch { }
    }
    return $Prefix
}

# Readiness covers only the new shell starting. Optional provisioning must
# complete before the handoff (Install-CaelestiaSchemeRuntime), never here.
function Wait-CaelestiaReady([string]$Prefix, [int]$TimeoutSeconds = 20, [string]$PreviousGeneration = '', [switch]$LegacyReady, [string]$TaskName = '', [switch]$PassThru, [string]$ExpectedPayload = '', [int]$ExpectedSupervisorPid = 0, [switch]$RequireIdentity) {
    if (-not $ExpectedPayload) { $ExpectedPayload = Get-CaelestiaExpectedPayload $Prefix }
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $recordGeneration = ''
    do {
        try {
            $remaining = [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds
            if ($remaining -le 0) { break }
            $state = Invoke-CaelestiaIpc $Prefix state ([Math]::Min(1000, $remaining)) | ConvertFrom-Json
            if ((Test-CaelestiaReadyState $state $PreviousGeneration -LegacyReady:$LegacyReady) -and
                (Test-CaelestiaReadyIdentity $state $ExpectedPayload $ExpectedSupervisorPid -RequireIdentity:$RequireIdentity) -and
                (-not $recordGeneration -or $state.lifecycle.generation -eq $recordGeneration)) {
                if ($PassThru) { return $state }
                return
            }
        } catch { }
        if ($TaskName -and $clock.Elapsed.TotalSeconds -ge 1) {
            # A constructor/launcher failure must not consume the entire
            # readiness timeout before a safe retry or rollback. Ready is also
            # the successful terminal state of the short-lived launcher.
            $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
            if ($task.State -eq 'Ready') {
                $result = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction Stop
                if ($result.LastRunTime.Year -gt 2000) {
                    if ($result.LastTaskResult -eq 0) {
                        $recordPath = Get-CaelestiaReadinessRecordPath $Prefix $TaskName
                        $record = Read-CaelestiaReadinessRecord $recordPath
                        $recordReady = $record -and $record.ready -eq $true -and $record.exitCode -eq 0 -and
                            $record.pid -gt 0 -and $record.generationId
                        $recordPayload = ''
                        $recordSupervisor = 0
                        if ($record) {
                            if ($record.PSObject.Properties['payloadPath']) { $recordPayload = [string]$record.payloadPath }
                            if ($record.PSObject.Properties['supervisorPid']) { $recordSupervisor = [int]$record.supervisorPid }
                            if (-not $recordSupervisor) { $recordSupervisor = [int]$record.pid }
                        }
                        if ($recordReady -and $recordPayload -and -not (Test-CaelestiaSamePath $recordPayload $ExpectedPayload)) { $recordReady = $false }
                        if ($recordReady) { $recordGeneration = [string]$record.generationId }
                        try {
                            $finalState = Invoke-CaelestiaIpc $Prefix state 1000 | ConvertFrom-Json
                            $finalSupervisor = if ($recordReady) { $recordSupervisor } else { $ExpectedSupervisorPid }
                            # The supervisor and payload own identity. A watchdog
                            # may replace the first child generation before this
                            # final check; that healthy replacement still passes.
                            if ((Test-CaelestiaReadyState $finalState $PreviousGeneration -LegacyReady:$LegacyReady) -and
                                (Test-CaelestiaReadyIdentity $finalState $ExpectedPayload $finalSupervisor -RequireIdentity:($RequireIdentity -or $recordReady))) {
                                if ($PassThru) { return $finalState }
                                return
                            }
                        } catch { }
                        if ($recordReady) {
                            # The launcher confirmed readiness. Allow a transient
                            # IPC outage to recover within the original budget.
                            Start-Sleep -Milliseconds 50
                            continue
                        }
                    }
                    throw 'Scheduled Caelestia launch exited before readiness.'
                }
            }
        }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Caelestia did not become ready within $TimeoutSeconds seconds. See the profile logs and runtime\supervisor-*\watchdog*.log."
}

function Test-CaelestiaLauncherSupportsReadiness([string]$Launcher) {
    if (-not [IO.File]::Exists($Launcher)) { return $false }
    return [IO.File]::ReadAllText($Launcher) -match '\[string\]\s*\$ReadinessRecordPath\b'
}

# Task Scheduler owns the process tree, not the invoking agent/terminal's job.
# On-demand only, interactive and non-elevated, with no autostart registration.
function Get-CaelestiaLaunchPlan([string]$Prefix, [switch]$PreparedSchemeRuntime, [switch]$DisableSchemeProvisioning, [string]$RuntimePrefix = '', [string]$LaunchId = '', [switch]$ReplacingRoot) {
    $launcher = Join-Path $Prefix 'Start-Caelestia.ps1'
    # The child runs on the host the selected payload needs: PS 7 for current
    # installs, 5.1 for a rolled-back legacy payload. An explicit RuntimePrefix
    # measures the version about to be activated, not the uncommitted selector.
    $resolvedRuntime = $RuntimePrefix
    if (-not $resolvedRuntime) {
        $resolvedRuntime = $Prefix
        if (Get-Command Resolve-CaelestiaRuntimePrefix -ErrorAction SilentlyContinue) {
            try { $resolvedRuntime = Resolve-CaelestiaRuntimePrefix $Prefix } catch { $resolvedRuntime = $Prefix }
        }
    }
    $shellHost = Get-CaelestiaPayloadPowerShellPath $resolvedRuntime
    $launchArguments = '-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "' + $launcher + '" -Prefix "' + $Prefix + '"'
    $runtimeLauncher = Join-Path $resolvedRuntime 'Start-Caelestia.ps1'
    $rootLauncher = if ($ReplacingRoot) { Join-Path $resolvedRuntime 'Start-CaelestiaEntry.ps1' } else { $launcher }
    if ($LaunchId -and (Test-CaelestiaLauncherSupportsReadiness $rootLauncher) -and
        (Test-CaelestiaLauncherSupportsReadiness $runtimeLauncher)) {
        $recordPrefix = if ($ReplacingRoot) { $resolvedRuntime } else { $Prefix }
        $readinessRecordPath = Get-CaelestiaReadinessRecordPath $recordPrefix $LaunchId
        $launchArguments += ' -ReadinessRecordPath "' + $readinessRecordPath + '"'
    }
    # Activation only consumes the scheme runtime prepared before the handoff.
    if ($PreparedSchemeRuntime) { $launchArguments += ' -PreparedSchemeRuntime' }
    elseif ($DisableSchemeProvisioning) { $launchArguments += ' -SkipSchemeRuntime' }
    return [pscustomobject]@{
        ShellHost = $shellHost
        Arguments = $launchArguments
    }
}

function New-CaelestiaLaunchTask([string]$Prefix, [switch]$PreparedSchemeRuntime, [switch]$DisableSchemeProvisioning, [string]$RuntimePrefix = '', [switch]$ReplacingRoot) {
    $taskName = 'Caelestia-Start-' + [guid]::NewGuid().ToString('N')
    $plan = Get-CaelestiaLaunchPlan $Prefix -PreparedSchemeRuntime:$PreparedSchemeRuntime -DisableSchemeProvisioning:$DisableSchemeProvisioning -RuntimePrefix $RuntimePrefix -LaunchId $taskName -ReplacingRoot:$ReplacingRoot
    $action = New-ScheduledTaskAction -Execute $plan.ShellHost `
        -Argument $plan.Arguments `
        -WorkingDirectory $env:USERPROFILE
    $principal = New-ScheduledTaskPrincipal -UserId ([Security.Principal.WindowsIdentity]::GetCurrent().Name) -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -ErrorAction Stop | Out-Null
    return $taskName
}

function Test-CaelestiaTaskSchedulerAccessDenied($ErrorRecord) {
    if (-not $ErrorRecord) { return $false }
    if ($ErrorRecord.Exception -is [UnauthorizedAccessException]) { return $true }
    $text = ((@([string]$ErrorRecord, [string]$ErrorRecord.Exception.Message, [string]$ErrorRecord.FullyQualifiedErrorId) -join ' '))
    return $text -match 'access is denied|accessdenied|0x80070005|2147024891|0x800704ec|2147023636|group policy|permissiondenied'
}


# Start-Process has no job-object escape control. Group Policy fallback runs
# from installers that may themselves be inside kill-on-close jobs, so use
# CreateProcess explicitly. BREAKAWAY is requested first; where a job's limit
# forbids it, Windows is allowed to create the same-session child normally.
function Start-CaelestiaOutOfJobProcess([string]$FilePath, [string]$Arguments, [string]$WorkingDirectory, [ref]$BreakawayUsed) {
    if (-not ('CaelestiaProcessIsolation.DetachedProcess' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;
namespace CaelestiaProcessIsolation {
    public static class DetachedProcess {
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        class StartupInfo {
            public int cb; public string reserved, desktop, title;
            public int x, y, xSize, ySize, xCountChars, yCountChars, fillAttribute, flags;
            public short showWindow, reserved2; public IntPtr reserved3, stdInput, stdOutput, stdError;
        }
        [StructLayout(LayoutKind.Sequential)]
        class ProcessInformation { public IntPtr process, thread; public int processId, threadId; }
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern bool CreateProcess(string application, StringBuilder commandLine, IntPtr processSecurity, IntPtr threadSecurity,
            bool inheritHandles, uint flags, IntPtr environment, string currentDirectory, StartupInfo startup, ProcessInformation information);
        [DllImport("kernel32.dll", SetLastError = true)] static extern bool CloseHandle(IntPtr handle);
        const uint CreateNewProcessGroup = 0x00000200, CreateNoWindow = 0x08000000, CreateUnicodeEnvironment = 0x00000400, CreateBreakawayFromJob = 0x01000000;
        public static int Start(string application, string arguments, string workingDirectory, out bool breakaway) {
            breakaway = false;
            string command = "\"" + application + "\" " + arguments;
            uint baseFlags = CreateNewProcessGroup | CreateNoWindow | CreateUnicodeEnvironment;
            for (int attempt = 0; attempt < 2; attempt++) {
                uint flags = baseFlags | (attempt == 0 ? CreateBreakawayFromJob : 0);
                var startup = new StartupInfo(); startup.cb = Marshal.SizeOf(startup);
                var information = new ProcessInformation();
                var mutableCommand = new StringBuilder(command);
                if (!CreateProcess(null, mutableCommand, IntPtr.Zero, IntPtr.Zero, false, flags, IntPtr.Zero, workingDirectory, startup, information)) {
                    int error = Marshal.GetLastWin32Error();
                    if (attempt == 0 && error == 5) continue; // ERROR_ACCESS_DENIED: job forbids breakaway.
                    throw new System.ComponentModel.Win32Exception(error);
                }
                breakaway = attempt == 0;
                CloseHandle(information.thread);
                CloseHandle(information.process);
                return information.processId;
            }
            throw new InvalidOperationException("CreateProcess did not run.");
        }
    }
}
'@ -ErrorAction Stop
    }
    $used = $false
    $id = [CaelestiaProcessIsolation.DetachedProcess]::Start($FilePath, $Arguments, $WorkingDirectory, [ref]$used)
    $BreakawayUsed.Value = $used
    return $id
}

# Task Scheduler can be disabled for standard users by Group Policy. That
# policy must not become a rollback-causing shell failure: use the same verified
# payload host and script arguments through an independent Start-Process launch,
# with a clear diagnostic. The scheduled task remains primary whenever allowed.
function Start-CaelestiaDirectDetached([string]$Prefix, [switch]$LegacyReady, [switch]$PreparedSchemeRuntime, [switch]$DisableSchemeProvisioning, [string]$RuntimePrefix = '') {
    $plan = Get-CaelestiaLaunchPlan $Prefix -PreparedSchemeRuntime:$PreparedSchemeRuntime -DisableSchemeProvisioning:$DisableSchemeProvisioning -RuntimePrefix $RuntimePrefix
    Write-Warning 'Task Scheduler refused the Caelestia launch (access denied or Group Policy). Starting Caelestia directly for this session instead; startup remains unregistered and non-elevated.'
    $breakaway = $false
    $processId = Start-CaelestiaOutOfJobProcess $plan.ShellHost $plan.Arguments $env:USERPROFILE ([ref]$breakaway)
    if (-not $breakaway) { Write-Warning 'The caller job does not permit breakaway; Caelestia was started in the same session without job breakaway.' }
    $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
    $expectedPayload = if ($RuntimePrefix) { $RuntimePrefix } else { Get-CaelestiaExpectedPayload $Prefix }
    $requireIdentity = Test-CaelestiaPayloadSupportsIdentity $expectedPayload
    try {
        Wait-CaelestiaReady $Prefix -TimeoutSeconds 75 -LegacyReady:$LegacyReady -ExpectedPayload $expectedPayload -RequireIdentity:$requireIdentity
    } catch {
        $launchError = $_
        try {
            if ($process -and -not $process.HasExited) { $process.Kill(); $process.WaitForExit(1000) }
            Invoke-CaelestiaPayloadCommand (Resolve-CaelestiaRuntimePrefix $Prefix -Running) @{ Command = 'Quit' } | Out-Null
        } catch {
            Write-Warning "Caelestia cleanup after a failed direct launch did not complete: $($_.Exception.Message)"
        }
        throw $launchError
    } finally {
        if ($process) { $process.Dispose() }
    }
}

function Start-CaelestiaDetached([string]$Prefix, [switch]$LegacyReady, [string]$TaskName = '', [switch]$PreparedSchemeRuntime, [switch]$DisableSchemeProvisioning, [string]$RuntimePrefix = '', [switch]$ReplacingRoot) {
    if (-not $TaskName) {
        try {
            $TaskName = New-CaelestiaLaunchTask $Prefix -PreparedSchemeRuntime:$PreparedSchemeRuntime -DisableSchemeProvisioning:$DisableSchemeProvisioning -RuntimePrefix $RuntimePrefix -ReplacingRoot:$ReplacingRoot
        } catch {
            if (Test-CaelestiaTaskSchedulerAccessDenied $_) {
                Start-CaelestiaDirectDetached $Prefix -LegacyReady:$LegacyReady -PreparedSchemeRuntime:$PreparedSchemeRuntime -DisableSchemeProvisioning:$DisableSchemeProvisioning -RuntimePrefix $RuntimePrefix
                return
            }
            throw
        }
    }
    try {
        for ($attempt = 0; $attempt -lt 2; $attempt++) {
            $taskStarted = $false
            try {
                Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
                $taskStarted = $true
                # Scheduled activation includes the launcher's banner replay
                # and first-frame gate, not only the child's 20 s render budget.
                $expectedPayload = if ($RuntimePrefix) { $RuntimePrefix } else { Get-CaelestiaExpectedPayload $Prefix }
                $requireIdentity = Test-CaelestiaPayloadSupportsIdentity $expectedPayload
                Wait-CaelestiaReady $Prefix -TimeoutSeconds 75 -LegacyReady:$LegacyReady -TaskName $taskName -ExpectedPayload $expectedPayload -RequireIdentity:$requireIdentity
                return
            } catch {
                $launchError = $_
                if (-not $taskStarted -and (Test-CaelestiaTaskSchedulerAccessDenied $launchError)) {
                    Write-Warning "Task Scheduler could not start the Caelestia launch task: $($launchError.Exception.Message)"
                    Start-CaelestiaDirectDetached $Prefix -LegacyReady:$LegacyReady -PreparedSchemeRuntime:$PreparedSchemeRuntime -DisableSchemeProvisioning:$DisableSchemeProvisioning -RuntimePrefix $RuntimePrefix
                    return
                }
                try {
                    # Do not allow a slow launcher to start later over a retry or
                    # rollback. Restore owned state before attempting another run.
                    Stop-ScheduledTask -TaskName $taskName -ErrorAction Stop
                    # Quit the version actually running, not the selector's
                    # target: a partially activated upgrade leaves the selector
                    # pointing at the incoming payload while the outgoing one
                    # still serves the desktop.
                    Invoke-CaelestiaPayloadCommand (Resolve-CaelestiaRuntimePrefix $Prefix -Running) @{ Command = 'Quit' } | Out-Null
                    $recordPath = Get-CaelestiaReadinessRecordPath $Prefix $TaskName
                    if ([IO.File]::Exists($recordPath)) { [IO.File]::Delete($recordPath) }
                } catch {
                    # Cleanup must not replace the startup error, and if the
                    # launcher/task state cannot be verified, never retry over it.
                    Write-Warning "Caelestia cleanup after a failed launch did not complete: $($_.Exception.Message)"
                    throw $launchError
                }
                if ($attempt -eq 1) { throw $launchError }
                # A readiness receipt is bound to one launch identifier. Never
                # reuse the failed task's identifier: replacement shells under
                # the same supervisor are valid, but a stale receipt from the
                # failed launcher is not. The caller's cleanup of the original
                # name is harmless after this re-registration.
                try {
                    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
                    $taskName = New-CaelestiaLaunchTask $Prefix -PreparedSchemeRuntime:$PreparedSchemeRuntime -DisableSchemeProvisioning:$DisableSchemeProvisioning -RuntimePrefix $RuntimePrefix -ReplacingRoot:$ReplacingRoot
                } catch {
                    Write-Warning "Caelestia startup could not register a fresh retry launch: $($_.Exception.Message)"
                    throw $launchError
                }
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
# the Apps & features UninstallString. conhost.exe --headless gives the
# selected PowerShell host a console without a window, so the entries never
# flash a console and never need VBScript or another Windows Script Host
# engine. The launcher derives its own prefix, so the command does not repeat
# the path and stays under Windows' 260-character limit for a Run value. A
# future signed launcher EXE (#20) replaces this helper and
# Caelestia-Launcher.ps1, nothing else.
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
# and PowerShell paths can be shortened: the 8.3 name is the same file, and it
# is kept only when it resolves back to that file. An empty result means no
# safe shortening.
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

function Get-CaelestiaLaunchCommand([string]$Prefix, [string]$Action, [int]$MaxLength = 0, [string]$RuntimePrefix = '') {
    if ($Action -notin @('start', 'switch-back', 'uninstall', 'uninstall-quiet')) {
        throw "Unknown Caelestia launch action: $Action"
    }
    $conhost = Join-Path $env:SystemRoot 'System32\conhost.exe'
    # The entry runs the selected payload's scripts, so it uses the host that
    # payload needs: PowerShell 7 for current installs, inbox Windows
    # PowerShell 5.1 for a rolled-back legacy payload.
    # An explicit -RuntimePrefix names the incoming payload's host, so a
    # pre-activation Run-value check measures the command it is about to write
    # rather than the command the still-outgoing selector produces.
    $runtimePrefix = $RuntimePrefix
    if (-not $runtimePrefix) {
        $runtimePrefix = $Prefix
        if (Get-Command Resolve-CaelestiaRuntimePrefix -ErrorAction SilentlyContinue) {
            try { $runtimePrefix = Resolve-CaelestiaRuntimePrefix $Prefix } catch { $runtimePrefix = $Prefix }
        }
    }
    $powershell = Get-CaelestiaPayloadPowerShellPath $runtimePrefix
    $launcher = Join-Path $Prefix 'Caelestia-Launcher.ps1'
    $command = New-CaelestiaLaunchCommand $conhost $powershell $launcher $Action
    if (-not $MaxLength -or $command.CommandLine.Length -le $MaxLength) { return $command }
    # The Microsoft Store alias is much longer than the classic powershell.exe
    # path, so a long prefix may need both components in 8.3 form. Try each
    # alone, then both.
    $shortLauncher = Get-CaelestiaShortPath $launcher
    $shortPowerShell = Get-CaelestiaShortPath $powershell
    foreach ($pair in @(
        @($powershell, $shortLauncher),
        @($shortPowerShell, $launcher),
        @($shortPowerShell, $shortLauncher))) {
        if (-not $pair[0] -or -not $pair[1]) { continue }
        $shortCommand = New-CaelestiaLaunchCommand $conhost $pair[0] $pair[1] $Action
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
        UninstallString = (Get-CaelestiaLaunchCommand $Prefix 'uninstall' -RuntimePrefix $RuntimePrefix).CommandLine
        QuietUninstallString = (Get-CaelestiaLaunchCommand $Prefix 'uninstall-quiet' -RuntimePrefix $RuntimePrefix).CommandLine
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
    $launch = Get-CaelestiaLaunchCommand $Prefix 'start' -RuntimePrefix $RuntimePrefix
    $switchBack = Get-CaelestiaLaunchCommand $Prefix 'switch-back' -RuntimePrefix $RuntimePrefix
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
    if ($writeRun) { $runCommand = Get-CaelestiaAutostartValue $Prefix -RuntimePrefix $RuntimePrefix }
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
    # A Run-only install has no shortcuts or Apps & features entry, but its Run
    # command still names the selected payload and must be refreshed on a
    # version change just like every other integration record.
    if ($integration.RunName) {
        try {
            $existing += [bool](Get-ItemProperty -LiteralPath (Get-CaelestiaAutostartKey) `
                -Name $integration.RunName -ErrorAction SilentlyContinue)
        } catch { }
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
