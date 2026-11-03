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
# A cache is reused only when the build record and the staged QML payload still
# match the inputs recorded with it, so a shared path cannot report a stale pass.
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
if (-not $BuildRoot) { $BuildRoot = Join-Path $repoRoot 'windows\.local\build' }
$BuildRoot = [IO.Path]::GetFullPath($BuildRoot)
$QtPrefix = [IO.Path]::GetFullPath($QtPrefix)
if (-not $RunRoot) { $RunRoot = Join-Path $repoRoot 'windows\.local\build' }
$RunRoot = [IO.Path]::GetFullPath($RunRoot)
if (-not $CachePath) {
    $cacheRoot = Join-Path $BuildRoot 'm1-regression'
    New-Item -ItemType Directory -Force -Path $cacheRoot | Out-Null
    $CachePath = Join-Path $cacheRoot ('suite-' + [guid]::NewGuid().ToString('N') + '.json')
}
$CachePath = [IO.Path]::GetFullPath($CachePath)
$cacheParent = Split-Path -Parent $CachePath
if ($cacheParent) { New-Item -ItemType Directory -Force -Path $cacheParent | Out-Null }

# The smoke stages its QML from this checkout, and the staged shell.qml embeds
# the profile path, so probe with the same profile name the smoke uses and hash
# the manifest the real run also records. A changed payload reruns M1.
function Get-StagedPayloadSha256 {
    $probe = Join-Path $RunRoot ('m1-payload-probe-' + [guid]::NewGuid().ToString('N'))
    try {
        & (Join-Path $PSScriptRoot 'Stage-ShellPrototype.ps1') -Destination $probe `
            -ProfileRoot (Join-Path $RunRoot 'shell-prototype-profile') -Prototype shell | Out-Null
        (Get-FileHash -LiteralPath (Join-Path $probe 'sources.json') -Algorithm SHA256).Hash
    } catch {
        $null
    } finally {
        Remove-Item -LiteralPath $probe -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$inputs = [ordered]@{
    buildRoot = $BuildRoot
    qtPrefix = $QtPrefix
    offscreen = $Offscreen.IsPresent
}
$buildRecord = Join-Path $BuildRoot 'logs\build.json'
$inputsReadable = $false
if (Test-Path -LiteralPath $buildRecord -PathType Leaf) {
    try {
        $record = Get-Content -LiteralPath $buildRecord -Raw | ConvertFrom-Json
        $inputs.sourceRevision = [string]$record.sourceRevision
        $inputs.backendRevision = [string]$record.backendRevision
        $inputsReadable = [bool]$inputs.sourceRevision -and [bool]$inputs.backendRevision
    } catch {
        $inputsReadable = $false
    }
}
$prerequisitesPresent =
    (Test-Path -LiteralPath (Join-Path $QtPrefix 'bin\Qt6Core.dll') -PathType Leaf) -and
    (Test-Path -LiteralPath (Join-Path $BuildRoot 'quickshell\qs.exe') -PathType Leaf)

$cachedResult = $null
if ($inputsReadable -and $prerequisitesPresent -and (Test-Path -LiteralPath $CachePath -PathType Leaf)) {
    try {
        $cached = Get-Content -LiteralPath $CachePath -Raw | ConvertFrom-Json
        $recorded = $cached.inputs
        $sameInputs = $recorded -and
            [string]::Equals([string]$recorded.buildRoot, $BuildRoot, [StringComparison]::OrdinalIgnoreCase) -and
            [string]::Equals([string]$recorded.qtPrefix, $QtPrefix, [StringComparison]::OrdinalIgnoreCase) -and
            [string]::Equals([string]$recorded.sourceRevision, $inputs.sourceRevision, [StringComparison]::Ordinal) -and
            [string]::Equals([string]$recorded.backendRevision, $inputs.backendRevision, [StringComparison]::Ordinal) -and
            ([bool]$recorded.offscreen) -eq $Offscreen.IsPresent
        if ($sameInputs) {
            $inputs.payloadSha256 = Get-StagedPayloadSha256
            $sameInputs = $inputs.payloadSha256 -and
                [string]::Equals([string]$recorded.payloadSha256, $inputs.payloadSha256, [StringComparison]::OrdinalIgnoreCase)
        }
        if ($sameInputs) { $cachedResult = $cached.result }
    } catch {
        $cachedResult = $null
    }
}
if ($cachedResult) {
    $cachedResult | Add-Member -NotePropertyName m1Cached -NotePropertyValue $true -Force
    $cachedResult | Add-Member -NotePropertyName m1CachePath -NotePropertyValue $CachePath -Force
    Write-Output $cachedResult
    return
}

# -NoThrow lets the result (including a failed or timed-out run) be cached so
# the next harness in the same suite does not repeat the same broken smoke.
$result = & "$PSScriptRoot\Start-ShellPrototype.ps1" -QtPrefix $QtPrefix -BuildRoot $BuildRoot `
    -RunRoot $RunRoot -Offscreen:$Offscreen -Smoke -ScaleFactor native -ScreenIndex 0 -NoThrow | ConvertFrom-Json
$result | Add-Member -NotePropertyName m1Cached -NotePropertyValue $false -Force
$result | Add-Member -NotePropertyName m1CachePath -NotePropertyValue $CachePath -Force
$inputs.payloadSha256 = $(if ($result.sources -and (Test-Path -LiteralPath $result.sources -PathType Leaf)) {
    (Get-FileHash -LiteralPath $result.sources -Algorithm SHA256).Hash
} else { '' })
[ordered]@{ inputs = $inputs; result = $result } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $CachePath -Encoding UTF8
Write-Output $result
