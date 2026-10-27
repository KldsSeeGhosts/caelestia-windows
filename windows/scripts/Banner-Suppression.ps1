[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$StateDirectory,
    [ValidateSet('Worker', 'Restore')][string]$Command = 'Restore',
    # Test-only override. Production callers never supply this argument.
    [string]$RegistryRoot = 'Software\Microsoft\Windows\CurrentVersion\Notifications\Settings'
)

$ErrorActionPreference = 'Stop'
$journalPath = Join-Path ([IO.Path]::GetFullPath($StateDirectory)) 'banner-suppression.json'
$mutexName = 'Local\CaelestiaBannerSuppression-' + [Diagnostics.Process]::GetCurrentProcess().SessionId
if ($RegistryRoot -ne 'Software\Microsoft\Windows\CurrentVersion\Notifications\Settings') {
    if ($RegistryRoot -notmatch '^Software\\CaelestiaWindowsTest\\[A-Za-z0-9-]+$') {
        throw 'The registry override is restricted to a dedicated test key.'
    }
    $mutexName += '-test'
}
$mutex = New-Object Threading.Mutex($false, $mutexName)
$locked = $false
$loaded = $false
$entries = @{}
$relinquished = @{}

function Save-Journal {
    New-Item -ItemType Directory -Force -Path $StateDirectory | Out-Null
    $payload = @{ version = 1; registryRoot = $RegistryRoot; entries = @($entries.Values) } | ConvertTo-Json -Depth 5 -Compress
    $tmp = $journalPath + '.tmp'
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($payload)
    $stream = [IO.FileStream]::new($tmp, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
    if ([IO.File]::Exists($journalPath)) {
        $backup = $journalPath + '.bak'
        [IO.File]::Replace($tmp, $journalPath, $backup)
        if ([IO.File]::Exists($backup)) { [IO.File]::Delete($backup) }
    }
    else { [IO.File]::Move($tmp, $journalPath) }
}

function Load-Journal {
    $script:entries = @{}
    if (-not [IO.File]::Exists($journalPath)) { return }
    $journal = [IO.File]::ReadAllText($journalPath) | ConvertFrom-Json
    if ($journal.version -ne 1 -or $journal.registryRoot -cne $RegistryRoot -or $null -eq $journal.entries) {
        throw 'Invalid banner suppression journal. No registry values were changed.'
    }
    foreach ($entry in $journal.entries) {
        if ($entry.name -isnot [string] -or -not (Valid-Name $entry.name) -or
            $entry.present -isnot [bool] -or ($entry.present -and $entry.value -isnot [int] -and $entry.value -isnot [long])) {
            throw 'Invalid banner suppression journal entry. No registry values were changed.'
        }
        if ($script:entries.ContainsKey($entry.name)) { throw 'Duplicate banner suppression journal entry.' }
        $script:entries[$entry.name] = $entry
    }
}

function Valid-Name([string]$name) {
    return $name.Length -gt 0 -and $name.Length -le 1024 -and
        $name -notmatch '[\x00-\x1f]' -and
        @($name.Split('\') | Where-Object { $_ -eq '' -or $_ -eq '.' -or $_ -eq '..' }).Count -eq 0
}

function Restore-Entries {
    foreach ($name in @($entries.Keys)) {
        $entry = $entries[$name]
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey("$RegistryRoot\$name", $true)
        try {
            $owned = $key -and @($key.GetValueNames()) -contains 'ShowBanner' -and
                $key.GetValueKind('ShowBanner') -eq [Microsoft.Win32.RegistryValueKind]::DWord -and
                $key.GetValue('ShowBanner') -eq 0
            if ($owned) {
                if ($entry.present) {
                    $key.SetValue('ShowBanner', [int]$entry.value, [Microsoft.Win32.RegistryValueKind]::DWord)
                } else { $key.DeleteValue('ShowBanner', $false) }
                $key.Flush()
            } else { $relinquished[$name] = $true }
        } finally { if ($key) { $key.Close() } }
        # Persist progress after each restore so a crash can resume safely.
        $entries.Remove($name)
        Save-Journal
    }
    if ([IO.File]::Exists($journalPath)) { [IO.File]::Delete($journalPath) }
}

function Suppress-One([string]$name, [string[]]$keep) {
    if (-not (Valid-Name $name) -or $name -like 'Windows.SystemToast.*' -or
        $name -ieq 'Windows.Defender.SecurityCenter' -or $keep -icontains $name -or
        $entries.ContainsKey($name) -or $relinquished.ContainsKey($name)) { return }
    $root = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($RegistryRoot, $true)
    if (-not $root) { throw 'Notification settings root is unavailable.' }
    $key = $null
    try {
        $key = $root.OpenSubKey($name, $true)
        if (-not $key) { $key = $root.CreateSubKey($name) }
        $present = @($key.GetValueNames()) -contains 'ShowBanner'
        if ($present -and $key.GetValueKind('ShowBanner') -ne [Microsoft.Win32.RegistryValueKind]::DWord) {
            [Console]::Error.WriteLine("Skipping non-DWORD ShowBanner: $name")
            return
        }
        $old = if ($present) { [int]$key.GetValue('ShowBanner') } else { 0 }
        # Existing zero is already the desired state. Never claim ownership of it.
        if ($present -and $old -eq 0) { return }
        $entries[$name] = @{ name = $name; present = $present; value = $old }
        Save-Journal
        $key.SetValue('ShowBanner', 0, [Microsoft.Win32.RegistryValueKind]::DWord)
        $key.Flush()
    } finally {
        if ($key) { $key.Close() }
        $root.Close()
    }
}

function Get-Names($key, [string]$prefix) {
    foreach ($childName in $key.GetSubKeyNames()) {
        $name = if ($prefix) { "$prefix\$childName" } else { $childName }
        $child = $key.OpenSubKey($childName)
        if ($child) {
            try {
                # Executable AUMIDs can contain backslashes. Intermediate
                # container keys are not application settings.
                if ($child.ValueCount -gt 0 -or $child.SubKeyCount -eq 0) { $name }
                Get-Names $child $name
            } finally { $child.Close() }
        }
    }
}

try {
    try { $locked = $mutex.WaitOne(30000) } catch [Threading.AbandonedMutexException] { $locked = $true }
    if (-not $locked) { throw 'Timed out waiting for banner suppression recovery.' }
    Load-Journal
    $loaded = $true
    Restore-Entries
    if ($Command -eq 'Worker') {
        [Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
        [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
        Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Threading;
public sealed class BannerCommandReader {
    public readonly BlockingCollection<string> Lines = new BlockingCollection<string>();
    public BannerCommandReader() {
        var thread = new Thread(() => {
            try {
                string line;
                while ((line = Console.In.ReadLine()) != null) Lines.Add(line);
            } finally { Lines.CompleteAdding(); }
        });
        thread.IsBackground = true;
        thread.Start();
    }
}
'@
        $keep = @()
        $reader = [BannerCommandReader]::new()
        $queue = New-Object 'System.Collections.Generic.Queue[string]'
        $stopping = $false
        while (-not $stopping) {
            if ($queue.Count -gt 0) { $line = $queue.Dequeue() }
            else {
                $line = $null
                if (-not $reader.Lines.TryTake([ref]$line, -1)) { break }
            }
            $message = $line | ConvertFrom-Json
            if ($message.command -eq 'stop') { break }
            if ($message.command -eq 'configure') {
                # Restore first so a newly excluded application immediately
                # regains its setting, then apply the new exclusion list.
                Restore-Entries
                $keep = @($message.keep | Where-Object { $_ -is [string] })
                $root = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey($RegistryRoot)
                if (-not $root) { throw 'Notification settings root is unavailable.' }
                try { $names = @(Get-Names $root '') } finally { $root.Close() }
                foreach ($name in $names) {
                    # A loss of mirroring must interrupt a long initial scan,
                    # not wait for every application's setting to be written.
                    $incoming = $null
                    while ($reader.Lines.TryTake([ref]$incoming, 0)) {
                        $incomingMessage = $incoming | ConvertFrom-Json
                        if ($incomingMessage.command -eq 'stop') { $stopping = $true; break }
                        $queue.Enqueue($incoming)
                        $incoming = $null
                    }
                    if ($reader.Lines.IsCompleted) { $stopping = $true }
                    if ($stopping) { break }
                    Suppress-One $name $keep
                }
            } elseif ($message.command -eq 'app' -and $message.name -is [string]) {
                Suppress-One $message.name $keep
            } else { throw 'Invalid banner suppression command.' }
            [Console]::Out.WriteLine('ok')
        }
    }
} finally {
    if ($locked) {
        try { if ($loaded) { Restore-Entries } } finally { $mutex.ReleaseMutex() }
    }
    $mutex.Dispose()
}
