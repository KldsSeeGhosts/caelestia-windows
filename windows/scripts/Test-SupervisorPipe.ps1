[CmdletBinding()]
param(
    [switch]$Worker,
    [string]$Spec,
    [string]$Token,
    [int]$LogDelayMs = 0
)
$ErrorActionPreference = 'Stop'
if ($Worker) {
    Add-Type -Path (Join-Path $PSScriptRoot 'DesktopTakeover.cs') -ReferencedAssemblies System.Windows.Forms, System.Web.Extensions
    exit [Caelestia.Takeover.Supervisor]::RunIsolatedTest($Spec, $Token, $LogDelayMs)
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('caelestia-supervisor-pipe-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$fixture = Join-Path $root 'fixture.exe'
Add-Type -Path (Join-Path $PSScriptRoot 'SupervisorPipeFixture.cs') -OutputAssembly $fixture -OutputType ConsoleApplication
$workers = @()
function Read-Status([string]$path) {
    try { if (Test-Path -LiteralPath $path) { return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json } }
    catch [IO.IOException] {}
    return $null
}
function Wait-Until([scriptblock]$condition, [int]$seconds, [string]$message) {
    $deadline = [DateTime]::UtcNow.AddSeconds($seconds)
    do {
        if (& $condition) { return }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    throw $message
}
function Signal-TestRecovery([string]$token) {
    $eventName = 'Local\CaelestiaDesktopTakeover-Test-' + $token + '-Recovery'
    $event = [Threading.EventWaitHandle]::OpenExisting($eventName)
    try { $event.Set() | Out-Null } finally { $event.Dispose() }
}
try {
    foreach ($scenario in @('restart', 'recovery', 'drain', 'drain-timeout', 'stall-restart')) {
        $dir = Join-Path $root $scenario
        New-Item -ItemType Directory -Path $dir | Out-Null
        $token = [guid]::NewGuid().ToString('N')
        $specPath = Join-Path $dir 'launch.json'
        $statusPath = Join-Path $dir 'watchdog.json'
        @{
            Executable = $fixture; Arguments = $(if ($scenario -like 'drain*') { 'clean "' + $dir + '"' } elseif ($scenario -eq 'stall-restart') { 'crash "' + $dir + '"' } else { 'spawn "' + $dir + '"' })
            WorkingDirectory = $dir; StateDirectory = $dir
            StdoutPath = (Join-Path $dir 'stdout.log'); StderrPath = (Join-Path $dir 'stderr.log')
            RestoreWorkAreas = $false; Environment = @{}
        } | ConvertTo-Json | Set-Content -LiteralPath $specPath -Encoding UTF8
        $args = @('-NoProfile', '-STA', '-File', ('"' + $PSCommandPath + '"'),
            '-Worker', '-Spec', ('"' + $specPath + '"'), '-Token', $token)
        if ($scenario -eq 'drain') { $args += @('-LogDelayMs', '400') }
        if ($scenario -in 'drain-timeout', 'stall-restart') { $args += @('-LogDelayMs', '5000') }
        $watchdog = Start-Process -FilePath "$PSHOME\powershell.exe" -ArgumentList $args -WindowStyle Hidden -PassThru
        $workers += $watchdog
        if ($scenario -eq 'drain-timeout') {
            Wait-Until { @(Get-ChildItem -LiteralPath $dir -Filter 'clean-*').Count -gt 0 } 10 'Dummy clean child did not start.'
            Wait-Until { $status = Read-Status $statusPath; $status -and $status.phase -eq 'clean-exit' } 4 'Drain deadline did not bound shutdown.'
            if (-not $watchdog.WaitForExit(5000)) { throw 'Supervisor did not exit after the drain deadline.' }
            Write-Output 'PASS drain-timeout: shutdown continued despite a stalled log callback.'
            continue
        }
        if ($scenario -eq 'stall-restart') {
            # Each crashing child's only log line stalls past the drain
            # deadline. Once retired, no stale tail may land in the shared
            # log, including after a replacement child has started.
            # Three quick crashes end in crash-give-up; stalled lines would land
            # while the next child runs.
            if (-not $watchdog.WaitForExit(30000)) { throw 'Supervisor did not give up after repeated crashes.' }
            if (@(Get-ChildItem -LiteralPath $dir -Filter 'crash-*').Count -lt 2) { throw 'Supervisor did not restart the crashing child.' }
            $status = Read-Status $statusPath
            if (-not $status -or $status.phase -ne 'crash-give-up') { throw "Unexpected final phase: $($status.phase)" }
            $log = Join-Path $dir 'stdout.log'
            if ((Test-Path -LiteralPath $log) -and (Get-Content -LiteralPath $log -Raw)) {
                throw 'A retired child callback wrote to the shared log after the drain deadline.'
            }
            Write-Output 'PASS stall-restart: stalled callbacks from retired children never reached the shared log.'
            continue
        }
        if ($scenario -eq 'drain') {
            Wait-Until { $status = Read-Status $statusPath; $status -and $status.phase -eq 'clean-exit' } 10 'Clean exit did not complete.'
            if (-not $watchdog.WaitForExit(5000)) { throw 'Clean-exit supervisor did not exit.' }
            $stdout = Get-Content -LiteralPath (Join-Path $dir 'stdout.log') -Raw
            $stderr = Get-Content -LiteralPath (Join-Path $dir 'stderr.log') -Raw
            if ($stdout -ne "stdout-line`r`nstdout-tail`r`n" -or $stderr -ne "stderr-line`r`nstderr-tail`r`n") {
                throw 'Delayed callbacks or final unterminated output were lost.'
            }
            Write-Output 'PASS drain: delayed stdout and stderr callbacks, including unterminated final lines, completed before shutdown.'
            continue
        }
        Wait-Until { @(Get-ChildItem -LiteralPath $dir -Filter 'child-*').Count -gt 0 } 10 'Dummy shell did not start the pipe holder.'
        $marker = Get-ChildItem -LiteralPath $dir -Filter 'child-*' | Select-Object -First 1
        $shellPid = [int]($marker.Name -replace '^child-', '')
        $holderPid = [int](Get-Content -LiteralPath $marker.FullName -Raw)
        Wait-Until { -not (Get-Process -Id $shellPid -ErrorAction SilentlyContinue) } 10 'Dummy shell did not exit.'
        if (-not (Get-Process -Id $holderPid -ErrorAction SilentlyContinue)) { throw 'Pipe holder did not survive its parent.' }
        if ($scenario -eq 'restart') {
            Wait-Until {
                $status = Read-Status $statusPath
                $status -and ($status.phase -eq 'restart-backoff' -or
                    ($status.phase -eq 'running' -and $status.shellPid -ne $shellPid))
            } 8 'Supervisor failed to enter restart-backoff or restart while the pipe holder was alive.'
            Signal-TestRecovery $token
        } else {
            # Give Tick time to encounter the exited child and its open pipes.
            Start-Sleep -Milliseconds 750
            Signal-TestRecovery $token
        }
        Wait-Until { $status = Read-Status $statusPath; $status -and $status.phase -eq 'recovered' } 4 'Recovery was not honoured within the bound.'
        if (-not $watchdog.WaitForExit(5000)) { throw 'Isolated supervisor did not exit.' }
        Write-Output "PASS ${scenario}: pipe holder alive after shell exit; supervisor completed within the bound."
    }
} finally {
    foreach ($watchdog in $workers) {
        if (-not $watchdog.HasExited) { $watchdog.Kill(); $watchdog.WaitForExit(5000) | Out-Null }
        $watchdog.Dispose()
    }
    foreach ($marker in @(Get-ChildItem -LiteralPath $root -Filter 'holder-*' -Recurse)) {
        $holderPid = [int](Get-Content -LiteralPath $marker.FullName -Raw)
        $holder = Get-Process -Id $holderPid -ErrorAction SilentlyContinue
        if ($holder -and $holder.Path -eq $fixture) { $holder.Kill(); $holder.WaitForExit(5000) | Out-Null }
    }
}
