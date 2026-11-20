[CmdletBinding(DefaultParameterSetName = 'Export')]
param(
    [Parameter(Mandatory)][string]$Prefix,
    [Parameter(Mandatory, ParameterSetName = 'Export')][string]$OutputPath,
    [string]$SnapshotPath,
    # Includes worker startup and all metadata/provider reads.
    [Parameter(ParameterSetName = 'Export')][ValidateRange(1, 15000)][int]$TimeoutMilliseconds = 5000,
    [Parameter(Mandatory, ParameterSetName = 'Collect')][switch]$Collect
)

$ErrorActionPreference = 'Stop'
# No dump opt-in exists in this fixed-field JSON exporter. It never collects
# crash dumps, report.txt or raw logs. See windows/docs/SUPPORT-BUNDLE.md for
# explicit manual sharing, including the warning that dumps cannot be redacted.
try { . (Join-Path $PSScriptRoot 'Caelestia-Support.ps1') }
catch {
    [Console]::Error.WriteLine('Support helper unavailable. Install both packaged support scripts together.')
    exit 1
}
# Prefer the shared x64 PowerShell 7 resolver. In the minimal packaged layout
# the common module may be absent, so fall back to the running pwsh host on
# PowerShell 7 and to Windows PowerShell 5.1 on Desktop.
function Resolve-SupportPowerShellPath {
    $common = Join-Path $PSScriptRoot 'Caelestia-InstallCommon.ps1'
    if (Test-Path -LiteralPath $common -PathType Leaf) {
        try {
            . $common
            if (Get-Command Get-CaelestiaPowerShellPath -ErrorAction SilentlyContinue) {
                return (Get-CaelestiaPowerShellPath)
            }
        } catch { }
    }
    if ($PSVersionTable.PSEdition -eq 'Core') {
        # Never resolve pwsh from PATH: an attacker-writable directory could
        # place a shim earlier in PATH than the real host. Only the absolute
        # executable of the currently running process (or $PSHOME) is trusted.
        try {
            $running = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
            if ($running -and $running.EndsWith('\pwsh.exe') -and
                (Test-Path -LiteralPath $running -PathType Leaf)) { return $running }
        } catch { }
        return (Join-Path $PSHOME 'pwsh.exe')
    }
    return (Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell\v1.0\powershell.exe')
}
if ($Collect) {
    try {
        $bundle = Get-CaelestiaSupportBundle $Prefix $SnapshotPath
        $json = ConvertTo-Json -InputObject $bundle -Depth 12 -Compress
        if ([Text.Encoding]::UTF8.GetByteCount($json) -gt 65536) { throw 'oversized' }
        [Console]::Out.Write($json)
        exit 0
    } catch {
        # No exception text, raw provider error, path or source log crosses IPC.
        exit 1
    }
}

$process = $null
$started = $false
$stream = $null
try {
    $Prefix = Resolve-SupportLocalPath $Prefix
    if ($SnapshotPath) { $SnapshotPath = Resolve-SupportLocalPath $SnapshotPath }
    $OutputPath = Resolve-SupportLocalPath $OutputPath
    # A separate new file outside the prefix cannot overwrite installed data.
    if ($OutputPath.StartsWith($Prefix.TrimEnd('\', '/') + '\', [StringComparison]::OrdinalIgnoreCase) -or
        $OutputPath -eq $Prefix -or [IO.File]::Exists($OutputPath) -or [IO.Directory]::Exists($OutputPath) -or
        -not [IO.Directory]::Exists([IO.Path]::GetDirectoryName($OutputPath))) { throw 'invalid' }
    # No shell, profile, executable from the payload, or arbitrary provider runs.
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = Resolve-SupportPowerShellPath
    $arguments = @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', $PSCommandPath, '-Collect', '-Prefix', $Prefix)
    if ($SnapshotPath) { $arguments += @('-SnapshotPath', $SnapshotPath) }
    # Quotes are illegal in these literal Windows paths, but a trailing
    # backslash must be doubled before the closing command-line quote.
    $start.Arguments = ($arguments | ForEach-Object {
        '"' + [regex]::Replace($_, '\\+$', '$0$0') + '"'
    }) -join ' '
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $start.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    $null = $process.Start()
    $started = $true
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $reason = 'none'
    if (-not $process.WaitForExit($TimeoutMilliseconds)) {
        $process.Kill()
        if (-not $process.WaitForExit(1000)) { throw 'unavailable' }
        $reason = 'timeout'
    } elseif ($process.ExitCode -ne 0) { $reason = 'provider-unavailable' }
    if ($reason -eq 'none') {
        $json = $stdout.GetAwaiter().GetResult()
        if ([Text.Encoding]::UTF8.GetByteCount($json) -gt 65536) { throw 'oversized' }
        # Successful output is produced solely by the fixed allowlist worker.
        $check = ConvertFrom-Json -InputObject $json
        if ($check.schema -cne 'caelestia-support-bundle' -or $check.version -ne 1) { throw 'invalid' }
    } else {
        $json = ConvertTo-Json -InputObject (New-SupportBundle $reason) -Depth 12 -Compress
    }
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json)
    # CreateNew refuses overwrite, including a racing existing output file.
    $stream = [IO.File]::Open($OutputPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    $stream.Write($bytes, 0, $bytes.Length)
    $stream.Dispose(); $stream = $null
    Write-Output ('Support bundle written; collection: ' + $reason + '. Inspect the JSON before sharing.')
} catch {
    [Console]::Error.WriteLine('Support export refused or could not complete. Check explicit local paths, output permissions and the packaged support scripts. No raw diagnostic was exported.')
    exit 1
} finally {
    if ($stream) { $stream.Dispose() }
    if ($process) {
        if ($started -and -not $process.HasExited) { try { $process.Kill() } catch { } }
        $process.Dispose()
    }
}
