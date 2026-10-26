# Quick file-only smoke. No shell launch, native build, registry or process writes.
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$importer = Join-Path $PSScriptRoot 'Import-KsgShellSettings.ps1'
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('caelestia-import-smoke-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path (Join-Path $temporary 'source') | Out-Null
New-Item -ItemType Directory -Path (Join-Path $temporary 'output') | Out-Null
function Assert($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
try {
    $source = Join-Path $temporary 'source\settings.json'
    $base = Join-Path $temporary 'output\base.json'
    $output = Join-Path $temporary 'output\shell.json'
    @'
{
  "bar": {"enabled": false, "showDate": false, "items": {"tray": false, "volume": false}},
  "osd": {"enabled": false},
  "wm": {"enabled": false, "gap": 12.5, "padding": 900},
  "token": "fixture-do-not-import",
  "wallpaper": "fixture-do-not-import"
}
'@ | Set-Content -LiteralPath $source -Encoding UTF8
    @'
{
  "bar": {
    "entries": [{"id":"clock","enabled":false},{"id":"tray","enabled":true,"extra":42}],
    "statusIcons": [{"id":"microphone","enabled":true},{"id":"audio","enabled":true}]
  },
  "appearance": {"rounding":{"scale":1.5}},
  "future": {"empty": [], "nested": [[1,2], [], null], "nothing": null}
}
'@ | Set-Content -LiteralPath $base -Encoding UTF8
    $sourceHash = (Get-FileHash -LiteralPath $source).Hash
    $json = & $importer -SettingsFile $source -BaseFile $base -OutFile $output -DryRun
    Assert (-not (Test-Path -LiteralPath $output)) 'DryRun wrote output.'
    $config = $json | ConvertFrom-Json
    Assert ($config.bar.excludedScreens[0] -eq '.*') 'Disabled bar not excluded.'
    Assert (-not $config.bar.clock.showDate -and -not $config.osd.enabled) 'Boolean false lost.'
    Assert ($config.bar.entries.Count -eq 2 -and -not $config.bar.entries[0].enabled) 'List order/unrelated entry changed.'
    Assert ($config.bar.entries[1].extra -eq 42 -and -not $config.bar.entries[1].enabled) 'Entry properties lost.'
    Assert ($config.bar.statusIcons[0].enabled -and -not $config.bar.statusIcons[1].enabled) 'Status merge failed.'
    Assert ($config.appearance.rounding.scale -eq 1.5) 'Unrelated setting changed.'
    Assert ($config.future.empty -is [array] -and $config.future.empty.Count -eq 0) 'Empty array lost.'
    Assert ($config.future.nested[0].Count -eq 2 -and $config.future.nested[1].Count -eq 0 -and
        $null -eq $config.future.nested[2] -and $null -eq $config.future.nothing) 'Nested array/null changed.'
    Assert ($json -notmatch 'fixture-do-not-import') 'Unknown source values leaked.'
    $report = & $importer -SettingsFile $source -BaseFile $base -Summary | ConvertFrom-Json
    Assert ($report.tiling.savedGapDip -eq 12.5 -and $report.tiling.savedPaddingDip -eq 40 -and
        -not $report.tiling.savedEnabled -and -not $report.tiling.imported) 'Tiling report incorrect.'

    & $importer -SettingsFile $source -BaseFile $base -OutFile $output | Out-Null
    $before = (Get-FileHash -LiteralPath $output).Hash
    $refused = $false
    try { & $importer -SettingsFile $source -OutFile $output | Out-Null } catch { $refused = $true }
    Assert $refused 'Existing file was not protected.'
    Assert ((Get-FileHash -LiteralPath $output).Hash -eq $before) 'Refusal changed output.'
    & $importer -SettingsFile $source -OutFile $output -Force | Out-Null
    $backups = @(Get-ChildItem -LiteralPath (Split-Path $output) -Filter 'shell.json.*.bak')
    Assert ($backups.Count -eq 1 -and (Get-FileHash -LiteralPath $backups[0].FullName).Hash -eq $before) 'Backup differs.'
    Assert ((Get-FileHash -LiteralPath $output).Hash -eq $before) 'Second import not idempotent.'
    $refused = $false
    try { & $importer -SettingsFile $source -OutFile $source -Force | Out-Null } catch { $refused = $true }
    Assert $refused 'Source overwrite allowed.'
    Assert ((Get-FileHash -LiteralPath $source).Hash -eq $sourceHash) 'Source file changed.'
    '{"passed":true,"scope":"file-only importer smoke","checks":["dry-run","false values","id-based list merge","unknown data preservation","source value filtering","tiling report","overwrite refusal","byte-identical backup","idempotence","source protection"]}'
} finally {
    # Delete only the exact, verified temporary workspace created above.
    $resolved = [IO.Path]::GetFullPath($temporary)
    $tempRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolved.StartsWith($tempRoot, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($resolved) -notlike 'caelestia-import-smoke-*') {
        throw 'Refusing cleanup outside the smoke workspace.'
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
