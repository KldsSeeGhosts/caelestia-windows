#requires -Version 5.1
<#
.SYNOPSIS
Inspect or explicitly capture a bounded QML profile from a disposable loopback target.
.DESCRIPTION
Does not launch, stop, inject into or reconfigure the target. Capture requires a
separately prepared debug-enabled disposable target, pinned identity and explicit
authority. Only the owned profiler process receives stdin. No GUI/input is used.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ProfilerPath,
    [Parameter(Mandatory)][string]$RunRoot,
    [ValidateRange(5,120)][int]$Seconds = 30,
    [ValidateRange(1024,65535)][int]$Port = 3768,
    [int]$TargetPid,
    [long]$TargetCreationTime100ns,
    [string]$TargetImageSha256,
    [switch]$Capture,
    [switch]$AuthorizedPrivateCapture,
    [switch]$DisposableTarget
)
$ErrorActionPreference='Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..\..'))
$output = [IO.Path]::GetFullPath($RunRoot)
if ($output -eq $repo -or $output.StartsWith($repo + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Profile output must be external to the source tree.'
}
if (Test-Path -LiteralPath $output) { throw 'RunRoot must be new; existing evidence is preserved.' }
New-Item -ItemType Directory -Path $output | Out-Null
$record=[ordered]@{
    schemaVersion=1; evidenceClass='profile'; scoredBenchmark=$false
    captureExecuted=$false; complete=$false; secondsRequested=$Seconds
    instrumentationOverhead=$null; overheadStatus='not-measured'
    targetStopped=$false; eventRanges=0; error=$null
    adapterSha256=(Get-FileHash -LiteralPath $PSCommandPath).Hash
}
$clock=[Diagnostics.Stopwatch]::StartNew()
$profiler=$null
$outTask=$null
$errTask=$null
function Start-Profiler([string[]]$Arguments, [switch]$Interactive) {
    $info=[Diagnostics.ProcessStartInfo]::new()
    $info.FileName=$script:ProfilerPath
    $info.Arguments=(@($Arguments | ForEach-Object { '"' + $_.Replace('"','\"') + '"' }) -join ' ')
    $info.UseShellExecute=$false
    $info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true
    $info.RedirectStandardError=$true
    $info.RedirectStandardInput=[bool]$Interactive
    return [Diagnostics.Process]::Start($info)
}
try {
    $ProfilerPath=(Resolve-Path -LiteralPath $ProfilerPath).Path
    $record.toolSha256=(Get-FileHash -LiteralPath $ProfilerPath).Hash
    $helpProcess=Start-Profiler @('--help')
    try {
        $helpOut=$helpProcess.StandardOutput.ReadToEndAsync()
        $helpErr=$helpProcess.StandardError.ReadToEndAsync()
        if (-not $helpProcess.WaitForExit(10000)) { $helpProcess.Kill(); throw 'Profiler help timed out.' }
        $help=$helpOut.GetAwaiter().GetResult() + $helpErr.GetAwaiter().GetResult()
        [IO.File]::WriteAllText((Join-Path $output 'help.txt'),$help)
        if ($helpProcess.ExitCode -ne 0 -or $help -notmatch '--interactive' -or $help -notmatch 'flush' -or $help -notmatch '--attach') {
            throw 'Profiler does not advertise the verified interactive attach/flush contract.'
        }
    } finally { $helpProcess.Dispose() }
    if (-not $Capture) {
        $record.complete=$true
        $record.status='inspected-only'
    } else {
        if (-not $AuthorizedPrivateCapture -or -not $DisposableTarget -or $TargetPid -le 0 -or
            $TargetCreationTime100ns -le 0 -or $TargetImageSha256 -notmatch '^[a-fA-F0-9]{64}$') {
            throw 'Capture requires explicit private/disposable authority and pinned target PID, creation time and image hash.'
        }
        $target=Get-Process -Id $TargetPid -ErrorAction Stop
        try {
            $null=$target.Handle
            if ($target.StartTime.ToUniversalTime().ToFileTimeUtc() -ne $TargetCreationTime100ns -or
                (Get-FileHash -LiteralPath $target.Path).Hash -ne $TargetImageSha256) {
                throw 'Target process identity differs from the authorized disposable process.'
            }
            $listeners=@(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction Stop)
            if ($listeners.Count -eq 0 -or @($listeners | Where-Object {
                $_.OwningProcess -ne $TargetPid -or $_.LocalAddress -notin @('127.0.0.1','::1')
            }).Count -ne 0) { throw 'Debug listener is missing, foreign or not loopback-only.' }
            $target.Refresh()
            if ($target.HasExited) { throw 'Disposable debug target exited before attach.' }
            $hostName=if (@($listeners | Where-Object LocalAddress -eq '127.0.0.1').Count) { '127.0.0.1' } else { '::1' }
            $record.target=[ordered]@{pid=$TargetPid; creationTime100ns=$TargetCreationTime100ns; imageSha256=$TargetImageSha256}
            $record.setupSeconds=$clock.Elapsed.TotalSeconds
            $trace=Join-Path $output 'qml.qtd'
            $profiler=Start-Profiler @('--attach',$hostName,'--port',"$Port",'--interactive','--record','on','--output',$trace) -Interactive
            $outTask=$profiler.StandardOutput.ReadToEndAsync()
            $errTask=$profiler.StandardError.ReadToEndAsync()
            $record.captureExecuted=$true
            $captureClock=[Diagnostics.Stopwatch]::StartNew()
            while ($captureClock.Elapsed.TotalSeconds -lt $Seconds) {
                if ($profiler.WaitForExit(200)) { throw 'Profiler exited before the requested observation finished.' }
                $target.Refresh()
                if ($target.HasExited) { throw 'Disposable target exited before profiling completed.' }
            }
            $record.observationSeconds=$captureClock.Elapsed.TotalSeconds
            $profiler.StandardInput.WriteLine('f')
            $profiler.StandardInput.Flush()
            # Observe a stable output file before quitting, then require a
            # complete parse after process exit. Stability alone is not proof.
            $flushClock=[Diagnostics.Stopwatch]::StartNew()
            $previousLength=-1L
            $stable=0
            while ($flushClock.Elapsed.TotalSeconds -lt 10 -and $stable -lt 5) {
                Start-Sleep -Milliseconds 200
                if (Test-Path -LiteralPath $trace) {
                    $length=(Get-Item -LiteralPath $trace).Length
                    if ($length -gt 0 -and $length -eq $previousLength) { $stable++ } else { $stable=0 }
                    $previousLength=$length
                }
            }
            if ($stable -lt 5) { throw 'No stable flushed profile within the deadline; partial evidence retained.' }
            $profiler.StandardInput.WriteLine('q')
            $profiler.StandardInput.Flush()
            if (-not $profiler.WaitForExit(5000)) { throw 'Profiler did not finish after flush/quit; partial evidence retained.' }
            if ($profiler.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $trace)) { throw 'Profiler failed or produced no trace.' }
            # Parse as XML without resolving external entities. Only actual
            # timestamped ranges count, not event definitions or an empty file.
            $settings=[Xml.XmlReaderSettings]::new()
            $settings.DtdProcessing=[Xml.DtdProcessing]::Prohibit
            $settings.XmlResolver=$null
            $reader=[Xml.XmlReader]::Create($trace,$settings)
            try {
                while ($reader.Read()) {
                    if ($reader.NodeType -eq [Xml.XmlNodeType]::Element -and $reader.LocalName -eq 'range' -and $reader.GetAttribute('startTime')) {
                        $record.eventRanges++
                    }
                }
            } finally { $reader.Dispose() }
            if ($record.eventRanges -eq 0) { throw 'zeroSamples: no timestamped QML event ranges. Unsupported format or missing debug events is not success.' }
            $record.traceSha256=(Get-FileHash -LiteralPath $trace).Hash
            $record.complete=$true
            $record.status='captured-requires-event-analysis'
        } finally { $target.Dispose() }
    }
} catch {
    $record.error=$_.Exception.Message
    $record.status='refused-or-failed'
} finally {
    if ($profiler) {
        if (-not $profiler.HasExited) {
            try { $profiler.StandardInput.WriteLine('q'); $profiler.StandardInput.Flush() } catch {}
            if (-not $profiler.WaitForExit(5000)) { $profiler.Kill(); $profiler.WaitForExit(5000) | Out-Null }
        }
        if ($outTask) { [IO.File]::WriteAllText((Join-Path $output 'stdout.log'),$outTask.GetAwaiter().GetResult()) }
        if ($errTask) { [IO.File]::WriteAllText((Join-Path $output 'stderr.log'),$errTask.GetAwaiter().GetResult()) }
        $profiler.Dispose()
    }
    $record.wallSeconds=$clock.Elapsed.TotalSeconds
    $record | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $output 'qml-profile.json') -Encoding UTF8
}
if (-not $record.complete) { Write-Error $record.error; exit 1 }
$record | ConvertTo-Json -Depth 8
