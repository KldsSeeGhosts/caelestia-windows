[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Destination,
    [Parameter(Mandatory)][string]$ProfileRoot,
    # The production tree comes from windows/shell/sources.json.
    # Retain the old selector only to reject retired preview requests clearly.
    [ValidateSet('combined', 'shell-live')]
    [string]$Prototype = 'shell-live'
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Caelestia-Toolchain.ps1')
Initialize-CaelestiaToolchainModules
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$Destination = [IO.Path]::GetFullPath($Destination)
$ProfileRoot = [IO.Path]::GetFullPath($ProfileRoot)
if ($Prototype -ne 'shell-live') {
    throw 'The combined developer preview has been retired. Use -Prototype shell-live for production staging.'
}
New-Item -ItemType Directory -Force -Path $Destination | Out-Null
$files = [ordered]@{}
# The installer and public smoke share the production map.
$manifest = Get-Content -LiteralPath (Join-Path $repoRoot 'windows\shell\sources.json') -Raw | ConvertFrom-Json
$stagedTargets = @{}
foreach ($entry in $manifest.PSObject.Properties) {
    if ($entry.Name -match '^windows/tests/') {
        throw "Production staging must not reference private fixtures: $($entry.Name)"
    }
    # One target, one source. A duplicate would silently let the last entry
    # win, which is how a test or fixture file could reach production.
    if ($stagedTargets.ContainsKey($entry.Value)) {
        throw "Duplicate production staging target '$($entry.Value)' in $($stagedTargets[$entry.Value]) and $($entry.Name)."
    }
    $stagedTargets[$entry.Value] = $entry.Name
    $files[$entry.Name] = $entry.Value
}
$sourceLock = Get-Content -LiteralPath (Join-Path $repoRoot 'windows/sources.lock.json') -Raw | ConvertFrom-Json
foreach ($font in $sourceLock.fonts) {
    foreach ($fontFile in $font.files) {
        $path = Join-Path $repoRoot $fontFile.path
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -ne $fontFile.sha256.ToLowerInvariant()) {
            throw "Bundled font checksum mismatch: $($fontFile.path)"
        }
        $destRel = if ($fontFile.path.StartsWith('windows/')) { $fontFile.path.Substring('windows/'.Length) } else { $fontFile.path }
        $files[$fontFile.path] = $destRel
    }
}
$sha256 = [Security.Cryptography.SHA256]::Create()
try {
$hashes = foreach ($entry in $files.GetEnumerator()) {
    $source = [IO.Path]::GetFullPath((Join-Path $repoRoot $entry.Key))
    $target = [IO.Path]::GetFullPath((Join-Path $Destination $entry.Value))
    if (-not $source.StartsWith($repoRoot + '\', [StringComparison]::OrdinalIgnoreCase) -or
        -not $target.StartsWith($Destination + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Staging path escapes its root: $($entry.Key)"
    }
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($target)) | Out-Null
    # Read/hash/copy the same bytes once. The old loop copied then reopened
    # both files to hash every unchanged asset, including the bundled fonts.
    $bytes = [IO.File]::ReadAllBytes($source)
    $sourceHash = [BitConverter]::ToString($sha256.ComputeHash($bytes)).Replace('-', '')
    [IO.File]::WriteAllBytes($target, $bytes)
    $transformed = $entry.Value -in @('shell.qml', 'modules/bar/components/workspaces/Workspace.qml')
    if ($entry.Value -eq 'shell.qml') {
        $shell = [IO.File]::ReadAllText($target)
        # Every bounded host uses the same process-local Nerd fonts, including
        # mono text in service slices. Keep this adaptation out of upstream QML.
        if ([regex]::Matches($shell, '(?m)^ShellRoot \{').Count -ne 1) {
            throw 'Expected one ShellRoot for the Windows font loader.'
        }
        $shell = $shell.Replace('ShellRoot {', "ShellRoot {`n    WindowsFonts { id: windowsFonts }")
        $header = @("DataDir $ProfileRoot\data", "StateDir $ProfileRoot\state", "CacheDir $ProfileRoot\cache") |
            ForEach-Object { "//@ pragma $_" }
        [IO.File]::WriteAllText($target, (($header -join "`n") + "`n" + $shell), (New-Object Text.UTF8Encoding($false)))
    }
    if ($entry.Value -eq 'modules/bar/components/workspaces/Workspace.qml') {
        # Qt 6.11's QML font value exposes family, not families. The Windows
        # helper preserves Rubik/configured primary and adds the bundled Nerd
        # font explicitly, without changing system fallback or upstream QML.
        $workspace = [IO.File]::ReadAllText($target)
        $familyBinding = 'font.family: Tokens.font.workspaces'
        if ([regex]::Matches($workspace, [regex]::Escape($familyBinding)).Count -ne 1) {
            throw 'Expected one workspace font binding for the Windows fallback.'
        }
        $workspace = [regex]::Replace($workspace, '(?m)^import QtQuick\r?$',
            "import Caelestia.Windows`nimport QtQuick")
        $workspace = $workspace.Replace($familyBinding,
            'font: WindowsFontFallback.workspaceFont(Tokens.font.body.small, Tokens.font.workspaces)')
        [IO.File]::WriteAllText($target, $workspace, (New-Object Text.UTF8Encoding($false)))
    }
    [ordered]@{
        source = $entry.Key; staged = $entry.Value
        sourceSha256 = $sourceHash
        stagedSha256 = $(if ($transformed) {
            [BitConverter]::ToString($sha256.ComputeHash([IO.File]::ReadAllBytes($target))).Replace('-', '')
        } else {
            # Retain timestamps so a repeated install can skip unchanged files.
            [IO.File]::SetLastWriteTimeUtc($target, [IO.File]::GetLastWriteTimeUtc($source))
            $sourceHash
        })
    }
}
$hashes | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Destination 'sources.json') -Encoding UTF8
    # A qmldir that names a file the map never copied is how a live install
    # can start, then fail to load (IdleHold.qml after ).
    foreach ($qmldir in @(Get-ChildItem -LiteralPath $Destination -Recurse -Filter qmldir -File)) {
        foreach ($line in @(Get-Content -LiteralPath $qmldir.FullName)) {
            if ($line -notmatch '\.qml\s*$') { continue }
            $name = ($line -split '\s+')[-1]
            $qml = Join-Path $qmldir.DirectoryName $name
            if (-not (Test-Path -LiteralPath $qml -PathType Leaf)) {
                throw "Staged $($qmldir.FullName.Substring($Destination.Length + 1)) lists $name, but that file is not in the payload."
            }
        }
    }
} finally { $sha256.Dispose() }
Write-Output $Destination
