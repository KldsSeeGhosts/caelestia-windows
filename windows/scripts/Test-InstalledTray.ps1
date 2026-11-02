[CmdletBinding()]
param(
    [string]$Prefix = (Join-Path $env:LOCALAPPDATA 'Programs\caelestia-windows')
)

# Check the runtime selected by the installed launcher, not a stale legacy
# shell/ directory left at the stable prefix after a versioned install.
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
. (Join-Path $Prefix 'Caelestia-InstallCommon.ps1')
$record = Read-CaelestiaInstall $Prefix
$runtime = if ($record.version -eq 2) {
    Resolve-CaelestiaRuntimePrefix $Prefix -Running
} else {
    $Prefix
}
$mappings = @(
    @('modules/bar/Bar.qml', 'shell/modules/bar/Bar.qml'),
    @('modules/bar/components/Tray.qml', 'shell/modules/bar/components/TrayContent.qml'),
    @('modules/bar/components/TrayItem.qml', 'shell/modules/bar/components/TrayItem.qml'),
    @('windows/shell/adapters/modules/bar/components/Tray.qml', 'shell/modules/bar/components/Tray.qml'),
    @('windows/services/tray/Tray.qml', 'shell/services/WindowsTray.qml')
)
$files = foreach ($pair in $mappings) {
    $target = Join-Path $runtime $pair[1]
    $matches = (Test-Path -LiteralPath $target -PathType Leaf) -and
        (Get-FileHash -LiteralPath (Join-Path $repoRoot $pair[0])).Hash -eq
        (Get-FileHash -LiteralPath $target).Hash
    [ordered]@{ file = $pair[1]; matchesSource = $matches }
}
$config = Get-Content -LiteralPath (Join-Path $record.profile 'config\shell.json') -Raw | ConvertFrom-Json
$settings = [ordered]@{
    entryEnabled = @($config.bar.entries | Where-Object { $_.id -eq 'tray' -and $_.enabled }).Count -gt 0
    compact = $config.bar.tray.compact -eq $true
    originalColours = $config.bar.tray.recolour -eq $false
    nativeMenus = $config.bar.popouts.tray -eq $false
}
$selected = $record.version -ne 2 -or (Split-Path -Leaf $runtime) -eq $record.current
$passed = $selected -and @($files | Where-Object { -not $_.matchesSource }).Count -eq 0 -and
    @($settings.Values | Where-Object { -not $_ }).Count -eq 0
[ordered]@{
    passed = $passed
    schema = $record.version
    selectedRuntime = $selected
    files = @($files)
    settings = $settings
} | ConvertTo-Json -Depth 5
if (-not $passed) { throw 'Installed tray does not match the requested feature or settings in the selected runtime.' }
