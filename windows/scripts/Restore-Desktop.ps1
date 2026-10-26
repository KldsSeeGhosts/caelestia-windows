[CmdletBinding()]
param(
    # Optional exact snapshot, when the supervisor itself was terminated.
    [string]$SnapshotPath,
    [switch]$RestartExplorer
)
$ErrorActionPreference = 'Stop'
Add-Type -Path (Join-Path $PSScriptRoot 'DesktopTakeover.cs') -ReferencedAssemblies System.Windows.Forms, System.Web.Extensions
[Caelestia.Takeover.Supervisor]::RecoverActive()
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
