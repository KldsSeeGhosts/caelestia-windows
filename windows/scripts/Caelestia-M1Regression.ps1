<#
.SYNOPSIS
Runs the M1 bar/session smoke once per suite invocation and reuses its result.
#>
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

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
if (-not $BuildRoot) { $BuildRoot = Join-Path $repoRoot 'windows\.local\build' }
$BuildRoot = [IO.Path]::GetFullPath($BuildRoot)
$QtPrefix = [IO.Path]::GetFullPath($QtPrefix)
if (-not $RunRoot) { $RunRoot = Join-Path $repoRoot 'windows\.local\build' }
$RunRoot = [IO.Path]::GetFullPath($RunRoot)
$profileRoot = Join-Path $RunRoot 'shell-prototype-profile'
if (-not $CachePath) {
    $cacheRoot = Join-Path $BuildRoot 'm1-regression'
    New-Item -ItemType Directory -Force -Path $cacheRoot | Out-Null
    $CachePath = Join-Path $cacheRoot ('suite-' + [guid]::NewGuid().ToString('N') + '.json')
}
$CachePath = [IO.Path]::GetFullPath($CachePath)
$cacheParent = Split-Path -Parent $CachePath
if ($cacheParent) { New-Item -ItemType Directory -Force -Path $cacheParent | Out-Null }

function Get-StagedPayloadSha256([string]$ProfileRoot) {
    $probe = Join-Path $RunRoot ('m1-payload-probe-' + [guid]::NewGuid().ToString('N'))
    try {
        & (Join-Path $PSScriptRoot 'Stage-ShellPrototype.ps1') -Destination $probe `
            -ProfileRoot $ProfileRoot -Prototype shell | Out-Null
        [pscustomobject]@{
            hash = (Get-FileHash -LiteralPath (Join-Path $probe 'sources.json') -Algorithm SHA256).Hash
            error = ''
        }
    } catch {
        [pscustomobject]@{ hash = ''; error = $_.Exception.Message }
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
$cacheMiss = $null
if (-not $prerequisitesPresent) {
    $cacheMiss = 'missing-prerequisite'
} elseif (-not $inputsReadable) {
    $cacheMiss = 'unreadable'
} elseif (-not (Test-Path -LiteralPath $CachePath -PathType Leaf)) {
    $cacheMiss = 'missing-cache'
} else {
    try {
        $cached = Get-Content -LiteralPath $CachePath -Raw | ConvertFrom-Json
        $recorded = $cached.inputs
        if (-not $recorded) {
            $cacheMiss = 'unreadable'
        } elseif (-not [string]::Equals([string]$recorded.buildRoot, $BuildRoot, [StringComparison]::OrdinalIgnoreCase)) {
            $cacheMiss = 'input-mismatch: buildRoot'
        } elseif (-not [string]::Equals([string]$recorded.qtPrefix, $QtPrefix, [StringComparison]::OrdinalIgnoreCase)) {
            $cacheMiss = 'input-mismatch: qtPrefix'
        } elseif (-not [string]::Equals([string]$recorded.sourceRevision, $inputs.sourceRevision, [StringComparison]::Ordinal)) {
            $cacheMiss = 'input-mismatch: sourceRevision'
        } elseif (-not [string]::Equals([string]$recorded.backendRevision, $inputs.backendRevision, [StringComparison]::Ordinal)) {
            $cacheMiss = 'input-mismatch: backendRevision'
        } elseif (([bool]$recorded.offscreen) -ne $Offscreen.IsPresent) {
            $cacheMiss = 'input-mismatch: offscreen'
        } else {
            $payload = Get-StagedPayloadSha256 $profileRoot
            if (-not $payload.hash) {
                $cacheMiss = 'payload-probe-failed: ' + $payload.error
            } elseif (-not [string]::Equals([string]$recorded.payloadSha256, $payload.hash, [StringComparison]::OrdinalIgnoreCase)) {
                $cacheMiss = 'input-mismatch: payloadSha256'
            } else {
                $inputs.payloadSha256 = $payload.hash
                $cachedResult = $cached.result
            }
        }
    } catch {
        $cacheMiss = 'unreadable'
    }
}
if ($cachedResult) {
    $cachedResult | Add-Member -NotePropertyName m1Cached -NotePropertyValue $true -Force
    $cachedResult | Add-Member -NotePropertyName m1CachePath -NotePropertyValue $CachePath -Force
    Write-Output $cachedResult
    return
}

$cacheable = $inputsReadable -and $prerequisitesPresent
try {
    $result = & "$PSScriptRoot\Start-ShellPrototype.ps1" -QtPrefix $QtPrefix -BuildRoot $BuildRoot `
        -RunRoot $RunRoot -ProfileRoot $profileRoot -Offscreen:$Offscreen -Smoke -ScaleFactor native -ScreenIndex 0 -NoThrow | ConvertFrom-Json
} catch {
    $result = [pscustomobject]@{ passed = $false; failure = $_.Exception.Message }
}
$result | Add-Member -NotePropertyName m1Cached -NotePropertyValue $false -Force
$result | Add-Member -NotePropertyName m1CachePath -NotePropertyValue $CachePath -Force
$inputs.payloadSha256 = $(if ($result.sources -and (Test-Path -LiteralPath $result.sources -PathType Leaf)) {
    (Get-FileHash -LiteralPath $result.sources -Algorithm SHA256).Hash
} else { '' })
if ($cacheable) {
    [ordered]@{ inputs = $inputs; result = $result } | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $CachePath -Encoding UTF8
}
if ($cacheMiss) {
    $result | Add-Member -NotePropertyName m1CacheMiss -NotePropertyValue $cacheMiss -Force
}
Write-Output $result
