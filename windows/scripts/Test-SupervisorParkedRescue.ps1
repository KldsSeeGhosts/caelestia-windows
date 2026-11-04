[CmdletBinding()]
param(
    [switch]$Worker,
    [string]$Spec,
    [string]$Token
)
$ErrorActionPreference = 'Stop'
if ($Worker) {
    Add-Type -Path (Join-Path $PSScriptRoot 'DesktopTakeover.cs') -ReferencedAssemblies System.Windows.Forms, System.Web.Extensions
    exit [Caelestia.Takeover.Supervisor]::RunIsolatedTest($Spec, $Token)
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('caelestia-parked-rescue-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$fixture = Join-Path $root 'fixture.exe'
Add-Type -Path (Join-Path $PSScriptRoot 'SupervisorPipeFixture.cs') -OutputAssembly $fixture -OutputType ConsoleApplication
$windowHost = $null
$watchdog = $null
function Wait-Until([scriptblock]$condition, [int]$seconds, [string]$message) {
    $deadline = [DateTime]::UtcNow.AddSeconds($seconds)
    do {
        if (& $condition) { return }
        Start-Sleep -Milliseconds 50
    } while ([DateTime]::UtcNow -lt $deadline)
    throw $message
}
function Read-State([string]$handle) {
    $state = @{}
    foreach ($line in @(& $fixture 'state' $handle)) {
        $pair = $line -split '=', 2
        if ($pair.Count -eq 2) { $state[$pair[0]] = $pair[1] }
    }
    if ($LASTEXITCODE -ne 0 -or -not $state.ContainsKey('onscreen')) { throw "Could not read window state for $handle." }
    return $state
}
try {
    # One hidden top-level window to park and one control that is never tagged.
    $windowHost = Start-Process -FilePath $fixture -ArgumentList @('window', ('"' + $root + '"')) -PassThru -WindowStyle Hidden
    Wait-Until { @(Get-ChildItem -LiteralPath $root -Filter 'window-*').Count -gt 0 } 10 'Parked-window fixture did not start.'
    $marker = @(Get-ChildItem -LiteralPath $root -Filter 'window-*')[0]
    $handle = (Get-Content -LiteralPath $marker.FullName -Raw).Trim()
    $control = (Get-Content -LiteralPath (Join-Path $root ($marker.Name -replace '^window-', 'control-')) -Raw).Trim()

    # The rectangle to restore, packed exactly as the tiler packs it.
    $packed = [uint64]100 -bor ([uint64]100 -shl 16) -bor ([uint64]320 -shl 32) -bor ([uint64]200 -shl 48)
    # A fake shell parks the window off screen, tags it, and dies.
    & $fixture 'park' $root $handle ([string]$packed) '-32000' '-32000' | Out-Null
    Wait-Until { (Read-State $handle).onscreen -eq '0' } 5 'Fixture window was not parked off screen.'
    $before = Read-State $handle
    if ($before.prop -ne '1') { throw 'Fixture window does not carry the parked property.' }
    # Safety: a real parked window must never be part of this run.
    $others = @(& $fixture 'list' | Where-Object { $_ -ne "parked=$handle" })
    if ($others.Count -ne 0) { throw "Another shell has parked windows; refusing to run: $($others -join ', ')" }

    $dir = Join-Path $root 'supervisor'
    New-Item -ItemType Directory -Path $dir | Out-Null
    $token = [guid]::NewGuid().ToString('N')
    $specPath = Join-Path $dir 'launch.json'
    $statusPath = Join-Path $dir 'watchdog.json'
    @{
        Executable = $fixture
        Arguments = 'park "' + $dir + '" ' + $handle + ' ' + ([string]$packed) + ' -32000 -32000'
        WorkingDirectory = $dir; StateDirectory = $dir
        StdoutPath = (Join-Path $dir 'stdout.log'); StderrPath = (Join-Path $dir 'stderr.log')
        RestoreWorkAreas = $false; Environment = @{}
    } | ConvertTo-Json | Set-Content -LiteralPath $specPath -Encoding UTF8
    $workerArgs = @('-NoProfile', '-STA', '-File', ('"' + $PSCommandPath + '"'),
        '-Worker', '-Spec', ('"' + $specPath + '"'), '-Token', $token)
    $watchdog = Start-Process -FilePath "$PSHOME\powershell.exe" -ArgumentList $workerArgs -WindowStyle Hidden -PassThru
    if (-not $watchdog.WaitForExit(30000)) { throw 'Supervisor did not give up after repeated crashes.' }
    $status = Get-Content -LiteralPath $statusPath -Raw | ConvertFrom-Json
    if ($status.phase -ne 'crash-give-up') { throw "Unexpected final phase: $($status.phase)" }
    if (@(Get-ChildItem -LiteralPath $dir -Filter 'parked-*').Count -ne 3) {
        throw 'The fake shell did not crash three times with the window parked.'
    }

    $after = Read-State $handle
    if ($after.onscreen -ne '1') { throw "Window is still off screen after the supervisor gave up: $($after.rect)" }
    if ($after.prop -ne '0') { throw 'The parked property was left on the window.' }
    if ((Read-State $control).onscreen -ne '0') { throw 'A window without the parked property was moved.' }
    Write-Output 'PASS parked-rescue: a window a crashing shell parked off screen came back on screen when the supervisor gave up.'
} finally {
    if ($watchdog) {
        if (-not $watchdog.HasExited) { $watchdog.Kill(); $watchdog.WaitForExit(5000) | Out-Null }
        $watchdog.Dispose()
    }
    if ($windowHost) {
        if (-not $windowHost.HasExited) { $windowHost.Kill(); $windowHost.WaitForExit(5000) | Out-Null }
        $windowHost.Dispose()
    }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
