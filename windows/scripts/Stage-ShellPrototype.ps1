[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Destination,
    [Parameter(Mandatory)][string]$ProfileRoot,
    # 'shell' is the M1 bar/session host. Every other value names one bounded
    # slice under windows/<name>-prototype with its own shell.qml and
    # sources.json manifest. One slice per stage. 'combined' unions the M1
    # manifest with every service slice manifest plus the combined adapters.
    [ValidateSet('shell', 'audio', 'battery', 'media', 'brightness', 'network', 'bluetooth', 'apps', 'tray', 'notifications', 'hypr', 'tiling', 'combined')]
    [string]$Prototype = 'shell'
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$Destination = [IO.Path]::GetFullPath($Destination)
$ProfileRoot = [IO.Path]::GetFullPath($ProfileRoot)
New-Item -ItemType Directory -Force -Path $Destination | Out-Null
$files = [ordered]@{
    'windows/shell-prototype/shell.qml' = 'shell.qml'
    'windows/assets/material-symbols-rounded/MaterialSymbolsRounded.ttf' = 'assets/material-symbols-rounded/MaterialSymbolsRounded.ttf'
    'windows/assets/material-symbols-rounded/LICENSE' = 'assets/material-symbols-rounded/LICENSE'
    'windows/assets/rubik/Rubik.ttf' = 'assets/rubik/Rubik.ttf'
    'windows/assets/rubik/OFL.txt' = 'assets/rubik/OFL.txt'
    'windows/assets/README.md' = 'assets/README.md'
    'windows/shell-prototype/WindowsFonts.qml' = 'WindowsFonts.qml'
}
$sourceLock = Get-Content -LiteralPath (Join-Path $repoRoot 'windows/sources.lock.json') -Raw | ConvertFrom-Json
foreach ($font in $sourceLock.fonts) {
    foreach ($fontFile in $font.files) {
        $path = Join-Path $repoRoot $fontFile.path
        if ((Get-FileHash -LiteralPath $path).Hash -ne $fontFile.sha256) {
            throw "Bundled font checksum mismatch: $($fontFile.path)"
        }
        $files.Add($fontFile.path, $fontFile.path.Substring('windows/'.Length))
    }
}
if ($Prototype -ne 'shell') {
    $files.Remove('windows/shell-prototype/shell.qml')
    $files.Add("windows/$Prototype-prototype/shell.qml", 'shell.qml')
}
$manifest = Get-Content -LiteralPath (Join-Path $repoRoot 'windows\shell-prototype\sources.json') -Raw | ConvertFrom-Json
foreach ($entry in $manifest.PSObject.Properties) { $files.Add($entry.Name, $entry.Value) }
if ($Prototype -eq 'tray') {
    # The base manifest stages an unavailable Tray adapter. This slice stages
    # the original component plus its item/menu dependencies instead.
    $files.Remove('windows/shell-prototype/adapters/modules/bar/components/Tray.qml')
}
# The combined prototype replaces the base manifest's unavailable adapters for
# every target that now has the original component or a combined adapter.
if ($Prototype -eq 'combined') {
    foreach ($baseAdapter in @(
        'windows/shell-prototype/adapters/modules/bar/components/OsIcon.qml',
        'windows/shell-prototype/adapters/modules/bar/components/Tray.qml',
        'windows/shell-prototype/adapters/modules/bar/components/StatusIcons.qml',
        'windows/shell-prototype/adapters/modules/bar/components/workspaces/Workspaces.qml',
        'windows/shell-prototype/adapters/modules/bar/components/ActiveWindow.qml',
        'windows/shell-prototype/adapters/modules/bar/popouts/Wrapper.qml',
        'windows/shell-prototype/adapters/modules/bar/popouts/ClipWrapper.qml',
        'windows/shell-prototype/adapters/modules/drawers/Panels.qml',
        'windows/shell-prototype/adapters/services/Hypr.qml',
        'windows/shell-prototype/adapters/utils/Paths.qml',
        'windows/shell-prototype/adapters/Caelestia/Services/qmldir',
        'modules/session/Content.qml'
    )) { $files.Remove($baseAdapter) }
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
# The combined prototype unions every service slice onto the base manifest.
# Slice entries whose staged target is provided by the combined adapters are
# skipped; the tray slice's original ColouredIcon over the notifications
# slice's lightness-only adapter is the one deliberate overwrite, so the
# notifications adapter is skipped explicitly to keep a single source of truth.
if ($Prototype -eq 'combined') {
    $combinedSkips = @{
        'audio' = @('modules/bar/popouts/AudioPopout.qml')
        'battery' = @('modules/bar/components/status/BatteryStatus.qml', 'modules/bar/popouts/Battery.qml', 'windows/services/battery/Battery.qml')
        'bluetooth' = @('modules/bar/popouts/Bluetooth.qml', 'windows/services/bluetooth/Bluetooth.qml')
        'brightness' = @('modules/osd/Content.qml')
        'network' = @('modules/bar/popouts/Network.qml')
        'notifications' = @('windows/notifications-prototype/adapters/components/effects/ColouredIcon.qml', 'windows/notifications-prototype/adapters/modules/utilities/Wrapper.qml')
        'apps' = @('windows/apps-prototype/adapters/modules/launcher/items/ActionItem.qml', 'windows/apps-prototype/adapters/modules/launcher/items/CalcItem.qml', 'windows/apps-prototype/adapters/modules/launcher/services/Actions.qml', 'windows/apps-prototype/adapters/modules/launcher/services/Schemes.qml', 'windows/apps-prototype/adapters/modules/launcher/services/M3Variants.qml')
        'tray' = @('modules/bar/components/Tray.qml', 'windows/services/tray/Tray.qml')
    }
    foreach ($slice in @('audio', 'battery', 'bluetooth', 'brightness', 'media', 'network', 'notifications', 'tray', 'apps')) {
        $sliceManifest = Get-Content -LiteralPath (Join-Path $repoRoot "windows\$slice-prototype\sources.json") -Raw | ConvertFrom-Json
        foreach ($entry in $sliceManifest.PSObject.Properties) {
            if ($combinedSkips[$slice] -contains $entry.Name) { continue }
            # Several slices stage the identical upstream file (PopoutState,
            # Icons, shared controls). The first staging of a source wins; the
            # recorded hashes prove the bytes are the same upstream file.
            if (-not $files.Contains($entry.Name)) { $files.Add($entry.Name, $entry.Value) }
        }
    }
}
$hashes = foreach ($entry in $files.GetEnumerator()) {
    $source = [IO.Path]::GetFullPath((Join-Path $repoRoot $entry.Key))
    $target = [IO.Path]::GetFullPath((Join-Path $Destination $entry.Value))
    if (-not $source.StartsWith($repoRoot + '\', [StringComparison]::OrdinalIgnoreCase) -or
        -not $target.StartsWith($Destination + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw "Staging path escapes its root: $($entry.Key)"
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
    Copy-Item -LiteralPath $source -Destination $target -Force
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
        sourceSha256 = (Get-FileHash -LiteralPath $source).Hash
        stagedSha256 = (Get-FileHash -LiteralPath $target).Hash
    }
}
$hashes | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Destination 'sources.json') -Encoding UTF8
Write-Output $Destination
