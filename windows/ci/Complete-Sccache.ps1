[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Launcher,
    [Parameter(Mandatory)][string]$Results
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $Results | Out-Null
try {
    & $Launcher --show-stats | Tee-Object -FilePath "$Results/stats.txt"
    if ($LASTEXITCODE -ne 0) { throw 'sccache statistics failed.' }
    & $Launcher --show-stats --stats-format json | Set-Content -LiteralPath "$Results/stats.json" -Encoding utf8
    if ($LASTEXITCODE -ne 0) { throw 'sccache JSON statistics failed.' }
} finally {
    & $Launcher --stop-server
    # "Couldn't connect" when no compile ever started a server is not a
    # failure; only a server that is still alive could be writing objects.
    if ($LASTEXITCODE -ne 0 -and @(Get-Process -Name sccache -ErrorAction SilentlyContinue).Count) {
        throw 'sccache server shutdown failed; do not save active objects.'
    }
}
