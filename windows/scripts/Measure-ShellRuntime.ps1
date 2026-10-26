[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QtPrefix,
    [Parameter(Mandatory)][string]$BuildRoot,
    [Parameter(Mandatory)][string]$RunRoot,
    [ValidateRange(60, 86400)][int]$DurationSeconds = 1200,
    [ValidateRange(15, 600)][int]$IdleSeconds = 120,
    [ValidateRange(0, 15)][int]$ScreenIndex = 1
)

$ErrorActionPreference = 'Stop'
if ($DurationSeconds -le 2 * $IdleSeconds) { throw 'Duration must include an exercise interval.' }
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$BuildRoot = (Resolve-Path -LiteralPath $BuildRoot).Path
$RunRoot = [IO.Path]::GetFullPath($RunRoot)
if ($RunRoot.StartsWith($BuildRoot + '\', [StringComparison]::OrdinalIgnoreCase) -or $RunRoot -eq $BuildRoot) {
    throw 'Use a fresh RunRoot outside the shared build.'
}
if (Test-Path -LiteralPath $RunRoot) { throw 'RunRoot must be new, to isolate this run.' }
New-Item -ItemType Directory -Path $RunRoot | Out-Null
$exe = Join-Path $BuildRoot 'quickshell\qs.exe'
$env:PATH = "$QtPrefix\bin;$BuildRoot\install\qml\Caelestia\lib;$env:PATH"
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class RuntimeGuiResources {
    [DllImport("user32.dll")] public static extern uint GetGuiResources(IntPtr process, uint flags);
}
'@

function Invoke-Prototype([string]$Method, [string[]]$Values = @()) {
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $exe
    $info.Arguments = "ipc --pid $($shellProcess.Id) call prototype $Method " + ($Values -join ' ')
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $client = [Diagnostics.Process]::Start($info)
    try {
        $outTask = $client.StandardOutput.ReadToEndAsync()
        $errTask = $client.StandardError.ReadToEndAsync()
        if (-not $client.WaitForExit(8000)) { $client.Kill(); throw "IPC timed out: $Method" }
        $output = $outTask.GetAwaiter().GetResult().Trim()
        $errors = $errTask.GetAwaiter().GetResult().Trim()
        if ($client.ExitCode -ne 0) { throw "IPC $Method failed: $errors $output" }
        return $output
    } finally { $client.Dispose() }
}

$launchArgs = '-NoProfile -File "' + (Join-Path $PSScriptRoot 'Start-ShellPrototype.ps1') +
    '" -QtPrefix "' + $QtPrefix + '" -BuildRoot "' + $BuildRoot + '" -RunRoot "' + $RunRoot +
    '" -Combined -RuntimeProbe -ScreenIndex ' + $ScreenIndex + ' -Wait'
$existing = @(Get-Process qs -ErrorAction SilentlyContinue | Select-Object Id, StartTime, Path)
$launcher = Start-Process powershell -ArgumentList $launchArgs -WindowStyle Hidden -PassThru `
    -RedirectStandardOutput (Join-Path $RunRoot 'launcher.stdout.log') `
    -RedirectStandardError (Join-Path $RunRoot 'launcher.stderr.log')
$shellProcess = $null
$success = $false
try {
    $startup = [Diagnostics.Stopwatch]::StartNew()
    while ($startup.Elapsed.TotalSeconds -lt 40) {
        $child = Get-CimInstance Win32_Process -Filter "ParentProcessId=$($launcher.Id) AND Name='qs.exe'" | Select-Object -First 1
        if ($child) { $shellProcess = Get-Process -Id $child.ProcessId; break }
        if ($launcher.HasExited) { throw 'Launcher exited before starting qs.exe; see launcher logs.' }
        Start-Sleep -Milliseconds 250
    }
    if (-not $shellProcess) { throw 'No shell child found.' }
    Start-Sleep -Seconds 5
    $initialState = Invoke-Prototype state | ConvertFrom-Json
    Invoke-Prototype showPanel @('idle', '0') | Out-Null
    $metadata = [ordered]@{
        sourceRevision = (& git -C $repoRoot rev-parse HEAD).Trim()
        sourceStatus = @(& git -C $repoRoot status --short)
        backendPin = (& git -C $repoRoot rev-parse HEAD:windows/deps/quickshell).Trim()
        build = Get-Content (Join-Path $BuildRoot 'logs\build.json') -Raw | ConvertFrom-Json
        executable = $exe; executableSha256 = (Get-FileHash $exe).Hash
        qtVersion = (Get-Item "$QtPrefix\bin\Qt6Core.dll").VersionInfo.FileVersion
        os = [Environment]::OSVersion.VersionString
        logicalProcessors = [Environment]::ProcessorCount
        processId = $shellProcess.Id; processStart = $shellProcess.StartTime.ToUniversalTime().ToString('o')
        startedUtc = [DateTime]::UtcNow.ToString('o'); durationSeconds = $DurationSeconds
        idleSeconds = $IdleSeconds; sampleSeconds = 15; actionSeconds = 10
        launchCommand = "powershell $launchArgs"; existingProcesses = $existing
        initialState = $initialState
    }
    $metadata | ConvertTo-Json -Depth 16 | Set-Content (Join-Path $RunRoot 'metadata.json') -Encoding UTF8
    $actions = @('dashboard:0', 'dashboard:1', 'dashboard:2', 'dashboard:3', 'idle:0',
        'launcher:0', 'scroll:50', 'scroll:100', 'scroll:0', 'idle:0', 'audio:0', 'idle:0',
        'network:0', 'idle:0', 'bluetooth:0', 'idle:0', 'battery:0', 'idle:0',
        'utilities:0', 'idle:0', 'sidebar:0', 'idle:0', 'osd:0', 'idle:0')
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $nextSample = 0.0
    $nextAction = [double]$IdleSeconds
    $actionIndex = 0
    $endIdle = $false
    $shellProcess.Refresh()
    $lastCpu = $shellProcess.TotalProcessorTime.TotalSeconds
    $lastSample = 0.0
    while ($true) {
        $elapsed = $clock.Elapsed.TotalSeconds
        if ($shellProcess.HasExited) { throw 'Shell exited during measurement.' }
        $phase = if ($elapsed -lt $IdleSeconds) { 'initial-idle' } elseif ($elapsed -lt $DurationSeconds - $IdleSeconds) { 'exercise' } else { 'final-idle' }
        if ($phase -eq 'final-idle' -and -not $endIdle) {
            Invoke-Prototype showPanel @('idle', '0') | Out-Null
            $endIdle = $true
        }
        if ($phase -eq 'exercise' -and $elapsed -ge $nextAction) {
            $action = $actions[$actionIndex % $actions.Count]
            $parts = $action.Split(':')
            $reply = if ($parts[0] -eq 'scroll') { Invoke-Prototype scrollLauncher @($parts[1]) } else { Invoke-Prototype showPanel @($parts[0], $parts[1]) }
            if ($reply -eq 'false' -or $reply -eq '-1') { throw "Action rejected: $action" }
            $state = Invoke-Prototype state | ConvertFrom-Json
            [ordered]@{ elapsedSeconds = $elapsed; action = $action; reply = $reply; state = $state } |
                ConvertTo-Json -Depth 12 -Compress | Add-Content (Join-Path $RunRoot 'actions.jsonl') -Encoding UTF8
            $actionIndex++
            $nextAction += 10
        }
        if ($elapsed -ge $nextSample) {
            $shellProcess.Refresh()
            $sampleTime = $clock.Elapsed.TotalSeconds
            $cpu = $shellProcess.TotalProcessorTime.TotalSeconds
            $corePercent = if ($sampleTime - $lastSample -gt 1) { 100 * ($cpu - $lastCpu) / ($sampleTime - $lastSample) } else { 0 }
            [pscustomobject][ordered]@{
                utc = [DateTime]::UtcNow.ToString('o'); elapsedSeconds = [Math]::Round($sampleTime, 3); phase = $phase
                privateBytes = $shellProcess.PrivateMemorySize64; workingSet = $shellProcess.WorkingSet64
                handles = $shellProcess.HandleCount; gdi = [RuntimeGuiResources]::GetGuiResources($shellProcess.Handle, 0)
                user = [RuntimeGuiResources]::GetGuiResources($shellProcess.Handle, 1); threads = $shellProcess.Threads.Count
                cpuCorePercent = [Math]::Round($corePercent, 5)
                cpuMachinePercent = [Math]::Round($corePercent / [Environment]::ProcessorCount, 5)
            } | Export-Csv (Join-Path $RunRoot 'samples.csv') -NoTypeInformation -Append
            $lastCpu = $cpu
            $lastSample = $sampleTime
            $nextSample += 15
            if ([int]$nextSample % 60 -eq 15) { Write-Output "PID $($shellProcess.Id): $([int]$elapsed)s $phase" }
        }
        if ($elapsed -ge $DurationSeconds) { break }
        Start-Sleep -Milliseconds 100
    }
    Invoke-Prototype state | Set-Content (Join-Path $RunRoot 'final-state.json') -Encoding UTF8
    Invoke-Prototype capture | Out-Null
    Start-Sleep -Seconds 1
    $success = $true
} finally {
    # Only the process discovered as this launcher's child is ever stopped.
    if ($shellProcess -and -not $shellProcess.HasExited) {
        try { Invoke-Prototype quit | Out-Null } catch { Write-Warning $_ }
        if (-not $shellProcess.WaitForExit(10000)) { $shellProcess.Kill(); $shellProcess.WaitForExit() }
    }
    $launcher.WaitForExit(15000) | Out-Null
    [ordered]@{ completed = $success; finishedUtc = [DateTime]::UtcNow.ToString('o')
        remainingProcesses = @(Get-Process qs -ErrorAction SilentlyContinue | Select-Object Id, StartTime, Path)
    } | ConvertTo-Json -Depth 6 | Set-Content (Join-Path $RunRoot 'completion.json') -Encoding UTF8
    if ($shellProcess) { $shellProcess.Dispose() }
    $launcher.Dispose()
}
