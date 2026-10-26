<#
.SYNOPSIS
Imports supported KSG Shell preferences without changing KSG Shell.
.DESCRIPTION
Without -OutFile, prints the merged shell.json to stdout and writes nothing.
-DryRun also suppresses writes with -OutFile. -Summary prints a value-safe JSON
mapping report instead of the config. Existing output requires -Force, which
creates a byte-for-byte backup before replacement.

Emits Caelestia ConfigRoot fields and the Windows facade's windows.tiling
extension. Imported tiling always starts in Observe mode, never Interactive.
See windows/docs/MIGRATING-FROM-KSG-SHELL.md.
#>
[CmdletBinding()]
param(
    [string]$SettingsFile = (Join-Path $env:APPDATA 'com.ksg.shell\settings.json'),
    [string]$BaseFile,
    [string]$OutFile,
    [switch]$DryRun,
    [switch]$Summary,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2

function ConvertTo-Map($Value) {
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $map = [ordered]@{}
        foreach ($property in $Value.PSObject.Properties) {
            $map[$property.Name] = ConvertTo-Map $property.Value
        }
        return $map
    }
    if ($Value -is [array]) {
        $items = New-Object 'System.Collections.Generic.List[object]'
        foreach ($item in $Value) { $items.Add((ConvertTo-Map $item)) }
        return ,$items.ToArray()
    }
    return $Value
}

function Read-Object([string]$Path) {
    try {
        $value = ConvertTo-Map (Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
    } catch {
        # Do not echo JSON parse exceptions, which can include private source values.
        throw 'Cannot read settings: expected a readable JSON object.'
    }
    if ($value -isnot [System.Collections.IDictionary]) {
        throw 'Settings root must be a JSON object.'
    }
    return $value
}

function Get-Value($Map, [string]$Path) {
    $value = $Map
    foreach ($part in $Path.Split('.')) {
        if ($value -isnot [System.Collections.IDictionary] -or -not $value.Contains($part)) {
            return $null
        }
        $value = $value[$part]
    }
    return ,$value
}

function Set-Value($Map, [string]$Path, $Value) {
    $parts = $Path.Split('.')
    $node = $Map
    for ($i = 0; $i -lt $parts.Length - 1; $i++) {
        $key = $parts[$i]
        if (-not $node.Contains($key)) { $node[$key] = [ordered]@{} }
        if ($node[$key] -isnot [System.Collections.IDictionary]) {
            throw "Base config has a non-object at '$key'; refusing to discard it."
        }
        $node = $node[$key]
    }
    $node[$parts[-1]] = $Value
}

$warnings = New-Object 'System.Collections.Generic.List[string]'
$mappings = New-Object 'System.Collections.Generic.List[object]'
function Read-Bool([string]$Path) {
    $value = Get-Value $source $Path
    # KSG SettingsKey defaults all boolean preferences to true.
    if ($null -eq $value) { return $true }
    if ($value -is [bool]) { return $value }
    $warnings.Add("Invalid $Path; using KSG's default (true).")
    return $true
}

function Read-Gap([string]$Path) {
    $value = Get-Value $source $Path
    if ($null -eq $value) { return 10.0 }
    if ($value -is [ValueType] -and $value -isnot [bool] -and
        $value -isnot [char] -and $value -isnot [datetime]) {
        # Same clamp as KSG SettingsKey::parse, preserving fractional DIPs.
        return [Math]::Min(40.0, [Math]::Max(0.0, [double]$value))
    }
    $warnings.Add("Invalid $Path; using KSG's default (10).")
    return 10.0
}

function Record-Mapping([string]$From, [string]$To) {
    $mappings.Add([ordered]@{ source = $From; target = $To })
}

function Set-Entry([string]$Path, [string]$Id, [bool]$Enabled, $Defaults) {
    $entries = Get-Value $merged $Path
    if ($null -eq $entries) { $entries = $Defaults }
    if ($entries -isnot [array]) { throw "Base '$Path' must be an array." }
    $found = $false
    foreach ($entry in $entries) {
        if ($entry -isnot [System.Collections.IDictionary] -or -not $entry.Contains('id')) {
            throw "Base '$Path' contains an entry without an id."
        }
        if ($entry.id -ceq $Id) {
            $entry['enabled'] = $Enabled
            $found = $true
        }
    }
    if (-not $found) { $entries = @($entries) + @([ordered]@{ id = $Id; enabled = $Enabled }) }
    Set-Value $merged $Path $entries
}

# Resolve and protect the source profile before considering any output.
$sourcePath = [IO.Path]::GetFullPath($SettingsFile)
$sourceDirectory = [IO.Path]::GetDirectoryName($sourcePath)
$protectedDirectories = @(
    $sourceDirectory,
    [IO.Path]::GetFullPath((Join-Path $env:APPDATA 'com.ksg.shell'))
)
$outputPath = $null
if ($OutFile) {
    $outputPath = [IO.Path]::GetFullPath($OutFile)
    foreach ($directory in $protectedDirectories) {
        if ($outputPath.Equals($directory, [StringComparison]::OrdinalIgnoreCase) -or
            $outputPath.StartsWith($directory.TrimEnd('\', '/') + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw 'OutFile must be outside the KSG source profile, even with -Force.'
        }
    }
}
$source = Read-Object $sourcePath

# A separate output must still merge the user's production config by default.
# When replacing an output, that output is the base unless explicitly overridden.
$basePath = $null
if ($BaseFile) {
    $basePath = [IO.Path]::GetFullPath($BaseFile)
} elseif ($outputPath -and (Test-Path -LiteralPath $outputPath)) {
    $basePath = $outputPath
} else {
    $productionConfig = Join-Path $env:LOCALAPPDATA 'caelestia-windows\config\shell.json'
    if (Test-Path -LiteralPath $productionConfig) { $basePath = $productionConfig }
}
$merged = [ordered]@{}
if ($basePath) { $merged = Read-Object $basePath }
$replacing = $outputPath -and (Test-Path -LiteralPath $outputPath)
if ($replacing -and -not $Force -and -not $DryRun) {
    throw 'OutFile already exists. Review with -DryRun; use -Force to back up and replace it.'
}

Set-Value $merged 'bar.clock.showDate' (Read-Bool 'bar.showDate')
Record-Mapping 'bar.showDate' 'bar.clock.showDate'
Set-Value $merged 'osd.enabled' (Read-Bool 'osd.enabled')
Record-Mapping 'osd.enabled' 'osd.enabled'

# ConfigRoot has no bar.enabled. Disabling every screen hides the whole bar,
# rather than leaving an empty reserved strip by merely disabling its entries.
if (Read-Bool 'bar.enabled') {
    Set-Value $merged 'bar.persistent' $true
    Record-Mapping 'bar.enabled' 'bar.persistent'
} else {
    $screens = Get-Value $merged 'bar.excludedScreens'
    if ($null -eq $screens) { $screens = @() }
    if ($screens -isnot [array]) { throw "Base 'bar.excludedScreens' must be an array." }
    Set-Value $merged 'bar.excludedScreens' @(@($screens) + '.*' | Select-Object -Unique)
    Record-Mapping 'bar.enabled' 'bar.excludedScreens (all screens)'
}

# Seed only absent lists with upstream defaults. Merge existing lists by id,
# preserving order, unrelated entries and extra properties on each entry.
$barDefaults = @(
    'logo', 'workspaces', 'spacer', 'activeWindow', 'spacer',
    'tray', 'clock', 'statusIcons', 'power'
) | ForEach-Object { [ordered]@{ id = $_; enabled = $true } }
Set-Entry 'bar.entries' 'tray' (Read-Bool 'bar.items.tray') @($barDefaults)
Record-Mapping 'bar.items.tray' 'bar.entries[id=tray].enabled'

$statusDefaults = @(
    'lockStatus', 'audio', 'microphone', 'kbLayout', 'network', 'bluetooth', 'battery'
) | ForEach-Object {
    [ordered]@{ id = $_; enabled = ($_ -in @('lockStatus', 'network', 'bluetooth', 'battery')) }
}
foreach ($pair in @(
    @('keyboard', 'kbLayout'), @('bluetooth', 'bluetooth'),
    @('network', 'network'), @('volume', 'audio'), @('power', 'battery')
)) {
    $from = 'bar.items.' + $pair[0]
    Set-Entry 'bar.statusIcons' $pair[1] (Read-Bool $from) @($statusDefaults)
    Record-Mapping $from ("bar.statusIcons[id={0}].enabled" -f $pair[1])
}

# KSG has no persisted user rules. Preserve reviewed Caelestia include/exclude/
# float/monitor settings from the base rather than guessing from unknown keys.
$savedEnabled = Read-Bool 'wm.enabled'
$savedGap = Read-Gap 'wm.gap'
$savedPadding = Read-Gap 'wm.padding'
Set-Value $merged 'windows.tiling.enabled' $savedEnabled
Set-Value $merged 'windows.tiling.mode' 'observe'
# The native backend Q_PROPERTYs accept integer DIPs.
Set-Value $merged 'windows.tiling.gapsIn' ([int][Math]::Round($savedGap, [MidpointRounding]::AwayFromZero))
Set-Value $merged 'windows.tiling.gapsOut' ([int][Math]::Round($savedPadding, [MidpointRounding]::AwayFromZero))
Record-Mapping 'wm.enabled' 'windows.tiling.enabled (Observe only)'
Record-Mapping 'wm.gap' 'windows.tiling.gapsIn'
Record-Mapping 'wm.padding' 'windows.tiling.gapsOut'

$report = [ordered]@{
    schemaVersion = 1
    dryRun = (-not $outputPath -or [bool]$DryRun)
    mergedExistingConfig = [bool]$basePath
    mapped = @($mappings.ToArray())
    tiling = [ordered]@{
        savedEnabled = $savedEnabled
        savedGapDip = $savedGap
        savedPaddingDip = $savedPadding
        imported = $true
        switchOverMode = 'observe'
        modeVariable = 'CAELESTIA_WINDOWS_TILING'
        includedVariable = 'CAELESTIA_WINDOWS_TILING_INCLUDED'
        excludedVariable = 'CAELESTIA_WINDOWS_TILING_EXCLUDED'
        reason = 'Mapped into windows.tiling; integer DIPs rounded to nearest. Observe never enables tiling. Interactive requires manual switch-over and a reviewed non-empty include list.'
    }
    notImported = @(
        'wm layout/drag/stacking/floating/resize: different tiling engine; no equivalent config fields.',
        'Per-app rules: KSG uses bundled rules only, not user float/tile/ignore lists. Regex/compound matchers cannot safely become M3 wildcards.',
        'Keybinds: KSG tiler chords are hardcoded; Caelestia drawer shortcut names are different actions and have no shell.json keybind field.',
        'Wallpaper: KSG has no saved wallpaper setting. Windows owns the wallpaper, also read by the Caelestia Windows adapter.',
        'Theme/accent: KSG follows Windows live; no saved override. Caelestia dynamic scheme is separate.',
        'Monitor preferences: native KSG settings parsing does not persist monitor selection; no stable KSG-to-Qt screen-name mapping.',
        'bar.items.notifications: no matching Caelestia bar entry; sidebar.enabled controls the whole drawer, not icon visibility.',
        'dock settings and data/dock/state.yml: no equivalent dock or pinned-app schema in Caelestia.',
        'shell.startAtSignIn/hideTaskbar/notificationArea: takeover and autostart require separate opt-in; not imported.',
        'Backups, unknown keys and other profile files are not imported or echoed.'
    )
    warnings = @($warnings.ToArray())
}

$json = $merged | ConvertTo-Json -Depth 100
if ($outputPath -and -not $DryRun) {
    $parent = [IO.Path]::GetDirectoryName($outputPath)
    if (-not (Test-Path -LiteralPath $parent -PathType Container)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    # Stage a sibling, then replace atomically. File.Replace both backs up the
    # existing bytes and avoids truncation if serialization or writing fails.
    $temporary = Join-Path $parent ('.ksg-import-' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [IO.File]::WriteAllText($temporary, $json + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
        if ($replacing) {
            $backup = $outputPath + '.' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '.' + [guid]::NewGuid().ToString('N') + '.bak'
            [IO.File]::Replace($temporary, $outputPath, $backup)
            Write-Verbose 'Existing output backed up before replacement.'
        } else {
            # Move refuses an output created since our existence check.
            [IO.File]::Move($temporary, $outputPath)
        }
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary }
    }
}
if ($Summary) {
    $report | ConvertTo-Json -Depth 12
} else {
    $json
}
