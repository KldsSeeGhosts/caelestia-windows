[CmdletBinding()]
param(
    # Optional exact snapshot, when the supervisor itself was terminated.
    [string]$SnapshotPath,
    # Profile-scoped Quit already stopped its verified supervisor. Never signal
    # a different profile that may have acquired the session in the meantime.
    [switch]$InactiveOnly,
    [switch]$RestartExplorer
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Caelestia-InstallCommon.ps1')
Import-CaelestiaDesktopTakeover -ScriptRoot $PSScriptRoot
$ownership = $null
$acquired = $false
try {
    if ($InactiveOnly) {
        $ownership = [Threading.Mutex]::new($false, [Caelestia.Takeover.Supervisor]::MutexName)
        try { $acquired = $ownership.WaitOne(0) } catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw 'Another desktop supervisor owns this session; leaving its desktop untouched.' }
    } else {
        [Caelestia.Takeover.Supervisor]::RecoverActive()
    }
    if ($RestartExplorer) {
        # Explicit opt-in only, and only for this logon session. Fast user
        # switching and remote sessions can each own an explorer.exe with the
        # same image name; killing all of them would sign another user out of
        # their shell. AccessDenied from another session is filtered before
        # Stop-Process rather than treated as this session's failure.
        $sessionId = [Diagnostics.Process]::GetCurrentProcess().SessionId
        foreach ($explorer in @(Get-Process -Name explorer -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $sessionId })) {
            try { Stop-Process -InputObject $explorer -Force -ErrorAction Stop }
            catch { Write-Warning "Could not stop Explorer PID $($explorer.Id): $($_.Exception.Message)" }
        }
        Start-Process explorer.exe
        Start-Sleep -Seconds 3
    }
    $snapshot = $null
    if ($SnapshotPath) {
        $snapshot = [Caelestia.Takeover.Native]::LoadSnapshot($SnapshotPath)
    }
    [Caelestia.Takeover.Native]::Restore($snapshot, 0)
    [Caelestia.Takeover.Native]::Capture() | ConvertTo-Json -Depth 6
} finally {
    if ($acquired) { $ownership.ReleaseMutex() }
    if ($ownership) { $ownership.Dispose() }
}
