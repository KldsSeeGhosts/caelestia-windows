[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Destination,
    [Parameter(Mandatory)][string]$ProfileRoot,
    # 'shell-live' stages the production tree from the one production map at
    # windows/shell/sources.json. 'combined' stages that same map plus the
    # private combined test host's overlay. Every other value names one bounded
    # slice under windows/<name>-prototype with its own shell.qml and
    # sources.json manifest, and is a test host, not production.
    [ValidateSet('shell', 'audio', 'battery', 'media', 'brightness', 'network', 'bluetooth', 'apps', 'tray', 'notifications', 'hypr', 'tiling', 'combined', 'shell-live')]
    [string]$Prototype = 'shell'
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$Destination = [IO.Path]::GetFullPath($Destination)
$ProfileRoot = [IO.Path]::GetFullPath($ProfileRoot)
$shellLive = $Prototype -eq 'shell-live'
$production = $shellLive -or $Prototype -eq 'combined'
New-Item -ItemType Directory -Force -Path $Destination | Out-Null
$files = [ordered]@{}
if ($production) {
    # The installer and the private shell test host stage the same production
    # map, so production never depends on a prototype or fixture folder. The
    # release excludes those folders; nothing here may point into one.
    $manifest = Get-Content -LiteralPath (Join-Path $repoRoot 'windows\shell\sources.json') -Raw | ConvertFrom-Json
    $stagedTargets = @{}
    foreach ($entry in $manifest.PSObject.Properties) {
        if ($entry.Name -match '^windows/[^/]+-prototype/') {
            throw "Production staging must not reference a prototype folder: $($entry.Name)"
        }
        # One target, one source. A duplicate would silently let the last entry
        # win, which is how a test or fixture file could reach production.
        if ($stagedTargets.ContainsKey($entry.Value)) {
            throw "Duplicate production staging target '$($entry.Value)' in $($stagedTargets[$entry.Value]) and $($entry.Name)."
        }
        $stagedTargets[$entry.Value] = $entry.Name
        $files[$entry.Name] = $entry.Value
    }
    if (-not $shellLive) {
        # Only the combined test host adds its instrumented entry point and the
        # smoke notification. An overlay entry replaces the production entry
        # already staged to the same target.
        $overlay = Get-Content -LiteralPath (Join-Path $repoRoot 'windows\combined-prototype\test-sources.json') -Raw | ConvertFrom-Json
        foreach ($entry in $overlay.PSObject.Properties) {
            foreach ($existing in @($files.Keys)) {
                if ($files[$existing] -eq $entry.Value) { $files.Remove($existing) }
            }
            $files[$entry.Name] = $entry.Value
        }
    }
} else {
    # Bounded slice hosts stage the M1 contract manifest plus one slice manifest.
    $files['windows/shell-prototype/shell.qml'] = 'shell.qml'
    $files['windows/assets/README.md'] = 'assets/README.md'
    $files['windows/shell/WindowsFonts.qml'] = 'WindowsFonts.qml'
    if ($Prototype -ne 'shell') {
        $files.Remove('windows/shell-prototype/shell.qml')
        $files.Add("windows/$Prototype-prototype/shell.qml", 'shell.qml')
    }
    $manifest = Get-Content -LiteralPath (Join-Path $repoRoot 'windows\shell-prototype\sources.json') -Raw | ConvertFrom-Json
    foreach ($entry in $manifest.PSObject.Properties) { $files[$entry.Name] = $entry.Value }
    if ($Prototype -eq 'tray') {
        # The base manifest stages an unavailable Tray adapter. This slice stages
        # the original component plus its item/menu dependencies instead.
        $files.Remove('windows/shell-prototype/adapters/modules/bar/components/Tray.qml')
    }
    if ($Prototype -eq 'hypr') {
        # The base manifest stages contract-only Hypr, Workspaces and ActiveWindow
        # adapters. This slice stages the real facade and the original components
        # (plus their dependencies) instead.
        $files.Remove('windows/shell-prototype/adapters/services/Hypr.qml')
        $files.Remove('windows/shell-prototype/adapters/modules/bar/components/workspaces/Workspaces.qml')
        $files.Remove('windows/shell-prototype/adapters/modules/bar/components/ActiveWindow.qml')
    }
    if ($Prototype -eq 'tiling') {
        # The base manifest stages the contract-only Hypr adapter. This slice
        # stages the real Hypr facade (failure records resolve window names when
        # Hypr observation is separately opted in) plus the tiling service and
        # the original toast surface with its Notifs adapter.
        $files.Remove('windows/shell-prototype/adapters/services/Hypr.qml')
    }
    if ($Prototype -ne 'shell') {
        $sliceManifest = Get-Content -LiteralPath (Join-Path $repoRoot "windows\$Prototype-prototype\sources.json") -Raw | ConvertFrom-Json
        foreach ($entry in $sliceManifest.PSObject.Properties) { $files.Add($entry.Name, $entry.Value) }
    }
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
} finally { $sha256.Dispose() }
Write-Output $Destination
