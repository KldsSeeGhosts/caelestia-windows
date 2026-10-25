[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$Destination,
    [Parameter(Mandatory)][string]$ProfileRoot,
    [switch]$Audio,
    [switch]$Battery,
    [switch]$Media,
    [switch]$Session
)

$ErrorActionPreference = 'Stop'
$entryPoints = @(@($Audio, $Battery, $Media) | Where-Object { $_ }).Count
if ($entryPoints -gt 1) { throw 'Select one prototype entry point per stage.' }
if ($Session -and $entryPoints -gt 0) { throw 'The session mode extends the M1 host and cannot be combined with another entry point.' }
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
if ($Audio) {
    $files.Remove('windows/shell-prototype/shell.qml')
    $files.Add('windows/audio-prototype/shell.qml', 'shell.qml')
}
if ($Battery) {
    $files.Remove('windows/shell-prototype/shell.qml')
    $files.Add('windows/battery-prototype/shell.qml', 'shell.qml')
}
if ($Media) {
    $files.Remove('windows/shell-prototype/shell.qml')
    $files.Add('windows/media-prototype/shell.qml', 'shell.qml')
}
$manifest = Get-Content -LiteralPath (Join-Path $repoRoot 'windows\shell-prototype\sources.json') -Raw | ConvertFrom-Json
foreach ($entry in $manifest.PSObject.Properties) { $files.Add($entry.Name, $entry.Value) }
if ($Audio) {
    $audioManifest = Get-Content -LiteralPath (Join-Path $repoRoot 'windows\audio-prototype\sources.json') -Raw | ConvertFrom-Json
    foreach ($entry in $audioManifest.PSObject.Properties) { $files.Add($entry.Name, $entry.Value) }
}
if ($Battery) {
    $batteryManifest = Get-Content -LiteralPath (Join-Path $repoRoot 'windows\battery-prototype\sources.json') -Raw | ConvertFrom-Json
    foreach ($entry in $batteryManifest.PSObject.Properties) { $files.Add($entry.Name, $entry.Value) }
}
if ($Media) {
    $mediaManifest = Get-Content -LiteralPath (Join-Path $repoRoot 'windows\media-prototype\sources.json') -Raw | ConvertFrom-Json
    foreach ($entry in $mediaManifest.PSObject.Properties) { $files.Add($entry.Name, $entry.Value) }
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
