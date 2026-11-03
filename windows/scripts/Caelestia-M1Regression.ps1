[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QtPrefix,
    [string]$BuildRoot,
    [string]$RunRoot,
    [switch]$Offscreen,
    # One cache path per suite invocation. A top-level harness leaves it empty
    # and gets a fresh path; Battery passes its path to the nested Audio harness.
    [string]$CachePath
)

# Runs the M1 bar/session smoke at most once per suite invocation and returns
# the same Start-ShellPrototype result to every caller. The cache lives under
# the disposable build root, never in the staged profile or the installation.
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
if (-not $BuildRoot) { $BuildRoot = Join-Path $repoRoot 'windows\.local\build' }
$BuildRoot = [IO.Path]::GetFullPath($BuildRoot)
if (-not $CachePath) {
    $cacheRoot = Join-Path $BuildRoot 'm1-regression'
    New-Item -ItemType Directory -Force -Path $cacheRoot | Out-Null
    $CachePath = Join-Path $cacheRoot ('suite-' + [guid]::NewGuid().ToString('N') + '.json')
}
$CachePath = [IO.Path]::GetFullPath($CachePath)
$cacheParent = Split-Path -Parent $CachePath
if ($cacheParent) { New-Item -ItemType Directory -Force -Path $cacheParent | Out-Null }

if (Test-Path -LiteralPath $CachePath -PathType Leaf) {
    $cached = Get-Content -LiteralPath $CachePath -Raw | ConvertFrom-Json
    $cached | Add-Member -NotePropertyName m1Cached -NotePropertyValue $true -Force
    $cached | Add-Member -NotePropertyName m1CachePath -NotePropertyValue $CachePath -Force
    Write-Output $cached
    return
}

# -NoThrow lets the result (including a failed or timed-out run) be cached so
# the next harness in the same suite does not repeat the same broken smoke.
$result = & "$PSScriptRoot\Start-ShellPrototype.ps1" -QtPrefix $QtPrefix -BuildRoot $BuildRoot `
    -RunRoot $RunRoot -Offscreen:$Offscreen -Smoke -ScaleFactor native -ScreenIndex 0 -NoThrow | ConvertFrom-Json
$result | Add-Member -NotePropertyName m1Cached -NotePropertyValue $false -Force
$result | Add-Member -NotePropertyName m1CachePath -NotePropertyValue $CachePath -Force
$result | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $CachePath -Encoding UTF8
Write-Output $result
