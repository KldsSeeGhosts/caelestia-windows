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
try { . (Join-Path $PSScriptRoot 'Caelestia-Support.ps1') }
catch {
    [Console]::Error.WriteLine('Support helper unavailable. Install both packaged support scripts together.')
    exit 1
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
    $start.FileName = Join-Path ([Environment]::GetFolderPath('System')) 'WindowsPowerShell\v1.0\powershell.exe'
    $arguments = @('-NoProfile', '-NonInteractive', '-File', $PSCommandPath, '-Collect', '-Prefix', $Prefix)
    if ($SnapshotPath) { $arguments += @('-SnapshotPath', $SnapshotPath) }
    # All arguments are literal local paths. Quotes are illegal in Windows paths.
    $start.Arguments = ($arguments | ForEach-Object { '"' + $_ + '"' }) -join ' '
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
