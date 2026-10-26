[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QtPrefix,
    [Parameter(Mandatory)][string]$BuildRoot,
    [string]$RunRoot
)
$ErrorActionPreference = 'Stop'
if (-not $RunRoot) { $RunRoot = Join-Path $PSScriptRoot '..\.local\takeover-smoke' }
Add-Type -Path (Join-Path $PSScriptRoot 'DesktopTakeover.cs') -ReferencedAssemblies System.Windows.Forms, System.Web.Extensions
$savedPath = $env:PATH
$env:PATH = "$QtPrefix\bin;$env:PATH"
$currentStatus = $null
function Start-TestShell {
    $lines = & (Join-Path $PSScriptRoot 'Start-ShellPrototype.ps1') -QtPrefix $QtPrefix `
        -BuildRoot $BuildRoot -RunRoot $RunRoot -Combined -HideTaskbar -NoRestartOnCrash
    $line = @($lines | Where-Object { $_ -match 'Status: ' })[-1]
    if (-not $line) { throw 'Launcher did not return a supervisor status path.' }
    return ($line -split 'Status: ', 2)[1]
}
function Assert-OwnedActions([string]$Path) {
    $directory = Split-Path -Parent $Path
    $before = Get-Content -LiteralPath (Join-Path $directory 'desktop-before.json') -Raw | ConvertFrom-Json
    $actions = @(Get-Content -LiteralPath (Join-Path $directory 'taskbar-actions.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
    $hides = @($actions | Where-Object Operation -eq hide)
    if (-not $hides.Count) { throw 'No taskbar hide calls were recorded.' }
    foreach ($action in $hides) {
        if ($action.RequestedVisible) { throw 'Hide requested a visible taskbar.' }
        $original = @($before.Bars | Where-Object { $_.Handle -eq $action.Handle -and $_.Owner -eq $action.Owner })
        $restores = @($actions | Where-Object { $_.Operation -eq 'restore' -and $_.Handle -eq $action.Handle -and $_.Owner -eq $action.Owner })
        if (-not $restores.Count) { throw "No restore call for owned hide HWND $($action.Handle)." }
        $expected = if ($original.Count) { $original[0].Visible } else { $true }
        if ($restores[-1].RequestedVisible -ne $expected) { throw 'Restore did not request the saved visibility.' }
    }
    $races = @($actions | Where-Object { $_.RequestedVisible -ne $_.VisibleAfter }).Count
    return "hide calls=$($hides.Count), restore calls=$(@($actions | Where-Object Operation -eq restore).Count), immediate observations contested=$races"
}
function Wait-TestExit([string]$Path, [string]$Phase) {
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        $status = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        if ($status.phase -eq $Phase) {
            $watchdog = Get-Process -Id $status.watchdogPid -ErrorAction SilentlyContinue
            if ($watchdog -and -not $watchdog.WaitForExit(5000)) { throw 'Test watchdog has not exited.' }
            return $status
        }
        if ([DateTime]::UtcNow -gt $deadline) { throw "Expected $Phase, got $($status.phase)." }
        Start-Sleep -Milliseconds 100
    } while ($true)
}
try {
    $currentStatus = Start-TestShell
    Start-Sleep -Seconds 10
    $status = Get-Content -LiteralPath $currentStatus -Raw | ConvertFrom-Json
    & (Join-Path $BuildRoot 'quickshell\qs.exe') ipc --pid $status.shellPid call prototype quit
    if ($LASTEXITCODE -ne 0) { throw 'Clean Qt.quit IPC failed.' }
    $null = Wait-TestExit $currentStatus 'clean-exit'
    if (Get-Process -Id $status.shellPid -ErrorAction SilentlyContinue) { throw 'Test shell is still running.' }
    Write-Output "PASS clean Qt.quit after 10 seconds: $(Assert-OwnedActions $currentStatus)."
    $currentStatus = Start-TestShell
    Start-Sleep -Seconds 2
    $status = Get-Content -LiteralPath $currentStatus -Raw | ConvertFrom-Json
    Stop-Process -Id $status.shellPid -Force
    $crash = Wait-TestExit $currentStatus 'crash-give-up'
    if (Get-Process -Id $status.shellPid -ErrorAction SilentlyContinue) { throw 'Killed test shell is still running.' }
    if ($crash.exitCode -eq 0) { throw 'Hard kill was incorrectly classified as clean.' }
    Write-Output "PASS hard kill (exit $($crash.exitCode)): $(Assert-OwnedActions $currentStatus)."
} finally {
    if ($currentStatus -and (Test-Path -LiteralPath $currentStatus)) {
        $owned = Get-Content -LiteralPath $currentStatus -Raw | ConvertFrom-Json
        if (Get-Process -Id $owned.watchdogPid -ErrorAction SilentlyContinue) {
            [Caelestia.Takeover.Supervisor]::RecoverActive()
        }
    }
    $env:PATH = $savedPath
}
Write-Output 'Global taskbar/work-area assertions are intentionally deferred while other live shells run.'
