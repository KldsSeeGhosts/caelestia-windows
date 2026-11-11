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
Add-Type -Path (Join-Path $PSScriptRoot 'DesktopTakeover.cs') -ReferencedAssemblies System.Windows.Forms, System.Web.Extensions
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
        # Explicit opt-in only: affects existing Explorer windows.
        Get-Process explorer -ErrorAction SilentlyContinue | Stop-Process
        Start-Process explorer.exe
        Start-Sleep -Seconds 3
    }
    $snapshot = $null
    if ($SnapshotPath) {
        $serializer = New-Object Web.Script.Serialization.JavaScriptSerializer
        $snapshot = $serializer.Deserialize((Get-Content -LiteralPath $SnapshotPath -Raw), [Caelestia.Takeover.Snapshot])
    }
    [Caelestia.Takeover.Native]::Restore($snapshot, 0)
    [Caelestia.Takeover.Native]::Capture() | ConvertTo-Json -Depth 6
} finally {
    if ($acquired) { $ownership.ReleaseMutex() }
    if ($ownership) { $ownership.Dispose() }
}
