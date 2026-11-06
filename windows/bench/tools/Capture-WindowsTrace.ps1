#requires -Version 5.1
<#
.SYNOPSIS
Explicitly authorized, bounded, uniquely named WPR capture. Not a scored benchmark.
.DESCRIPTION
Never elevates, installs tools, queries personal shell state, or cancels another
WPR session. Raw traces can include personal/system activity and stay private.
Default invocation only inspects local help. Capture requires both switches.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RunRoot,
    [ValidateRange(5,120)][int]$Seconds = 30,
    [ValidateSet('GeneralProfile')][string]$Profile = 'GeneralProfile',
    [switch]$Capture,
    [switch]$AuthorizedPrivateCapture
)
$ErrorActionPreference = 'Stop'
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$output = [IO.Path]::GetFullPath($RunRoot)
if ($output -eq $repoRoot -or $output.StartsWith($repoRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Trace evidence must be external to the source tree.'
}
if (Test-Path -LiteralPath $output) { throw 'RunRoot must be new; preserve existing evidence.' }
New-Item -ItemType Directory -Path $output | Out-Null
$clock = [Diagnostics.Stopwatch]::StartNew()
$record = [ordered]@{
    privacy='PRIVATE-local-evidence; never upload raw receipts automatically'
    schemaVersion=1; evidenceClass='profile'; scoredBenchmark=$false
    secondsRequested=$Seconds; captureExecuted=$false; complete=$false
    instrumentationOverhead=$null; overheadStatus='not-measured'
    instance=('CaelestiaPerf-' + [Guid]::NewGuid().ToString('N')); profile=$Profile
    cleanup='No session started.'; error=$null
    adapterSha256=(Get-FileHash -LiteralPath $PSCommandPath).Hash
}
function Invoke-TraceTool([string[]]$Arguments, [int]$TimeoutSeconds = 20) {
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $script:wpr.Source
    $info.Arguments = (@($Arguments | ForEach-Object { '"' + $_.Replace('"','\"') + '"' }) -join ' ')
    $info.UseShellExecute=$false
    $info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true
    $info.RedirectStandardError=$true
    $child = [Diagnostics.Process]::Start($info)
    try {
        $stdout = $child.StandardOutput.ReadToEndAsync()
        $stderr = $child.StandardError.ReadToEndAsync()
        if (-not $child.WaitForExit($TimeoutSeconds * 1000)) {
            $child.Kill()
            throw 'WPR command timed out; inspect the named instance before further capture.'
        }
        $text = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
        [IO.File]::AppendAllText((Join-Path $output 'tool.log'), ($Arguments -join ' ') + "`n" + $text + "`n")
        if ($child.ExitCode -ne 0) { throw "WPR refused with exit $($child.ExitCode); no elevation or authentication retry." }
        return $text
    } finally { $child.Dispose() }
}
$started = $false
try {
    $wpr = Get-Command wpr.exe -CommandType Application -ErrorAction Stop
    $record.toolSha256 = (Get-FileHash -LiteralPath $wpr.Source).Hash
    $help = Invoke-TraceTool @('-help','start')
    if ($help -notmatch '-instancename') { throw 'This WPR does not advertise named instances. Refusing global capture.' }
    if (-not $Capture) {
        $record.complete=$true
        $record.status='inspected-only'
    } else {
        if (-not $AuthorizedPrivateCapture) { throw 'Capture requires explicit -AuthorizedPrivateCapture.' }
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = [Security.Principal.WindowsPrincipal]::new($identity)
        if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
            throw 'Kernel profiling requires an already authorized elevated operator. This adapter never requests elevation.'
        }
        $record.setupSeconds=$clock.Elapsed.TotalSeconds
        $started=$true
        $record.cleanup='Start requested; inspect this named instance if startup or cleanup fails.'
        Invoke-TraceTool @('-start',$Profile,'-filemode','-recordtempto',$output,'-instancename',$record.instance) | Out-Null
        $record.captureExecuted=$true
        $captureClock = [Diagnostics.Stopwatch]::StartNew()
        # Short waits keep interruption responsive. No input or providers started.
        while ($captureClock.Elapsed.TotalSeconds -lt $Seconds) { Start-Sleep -Milliseconds 200 }
        $record.observationSeconds=$captureClock.Elapsed.TotalSeconds
        $trace = Join-Path $output 'trace.etl'
        Invoke-TraceTool @('-stop',$trace,'-skipPdbGen','-instancename',$record.instance) -TimeoutSeconds 30 | Out-Null
        $started=$false
        if (-not (Test-Path -LiteralPath $trace) -or (Get-Item -LiteralPath $trace).Length -eq 0) { throw 'No trace bytes. Not a successful profile.' }
        $record.traceSha256=(Get-FileHash -LiteralPath $trace).Hash
        $record.complete=$true
        $record.status='captured-not-analyzed'
        $record.cleanup='Owned named instance stopped.'
    }
} catch {
    $record.error=$_.Exception.Message
    $record.status='refused-or-failed'
} finally {
    if ($started) {
        # Never use an unqualified/global cancel. Failed trace is evidence too.
        try {
            Invoke-TraceTool @('-stop',(Join-Path $output 'interrupted.etl'),'-skipPdbGen','-instancename',$record.instance) -TimeoutSeconds 30 | Out-Null
            $record.cleanup='Owned named instance stopped after failure; interrupted trace retained.'
        } catch { $record.cleanup='Owned instance may remain: ' + $record.instance + '. Manual owner inspection required.' }
    }
    $record.wallSeconds=$clock.Elapsed.TotalSeconds
    $record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $output 'trace.json') -Encoding UTF8
}
if (-not $record.complete) { Write-Error $record.error; exit 1 }
$record | ConvertTo-Json -Depth 8
