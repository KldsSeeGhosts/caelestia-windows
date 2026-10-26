[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Destination,
    [Parameter(Mandatory)][string]$ProfileRoot,
    # 'shell' is the M1 bar/session host. Every other value names one bounded
    # slice under windows/<name>-prototype with its own shell.qml and
    # sources.json manifest. One slice per stage.
    [ValidateSet('shell', 'audio', 'battery', 'media', 'network', 'bluetooth', 'apps', 'tray', 'hypr', 'tiling')]
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
        $header = @("DataDir $ProfileRoot\data", "StateDir $ProfileRoot\state", "CacheDir $ProfileRoot\cache") |
            ForEach-Object { "//@ pragma $_" }
        [IO.File]::WriteAllText($target, (($header -join "`n") + "`n" + $shell), (New-Object Text.UTF8Encoding($false)))
    }
    [ordered]@{
        source = $entry.Key; staged = $entry.Value
        sourceSha256 = (Get-FileHash -LiteralPath $source).Hash
        stagedSha256 = (Get-FileHash -LiteralPath $target).Hash
    }
}
$hashes | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $Destination 'sources.json') -Encoding UTF8
Write-Output $Destination
