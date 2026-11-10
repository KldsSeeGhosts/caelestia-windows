#requires -Version 5.1
[CmdletBinding()]
param([Parameter(Mandatory)][string]$Destination)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path "$PSScriptRoot\..\..").Path
$Destination = [IO.Path]::GetFullPath($Destination)
$temp = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
if (-not $Destination.StartsWith($temp, [StringComparison]::OrdinalIgnoreCase) -or
    (Test-Path -LiteralPath $Destination)) { throw 'Bench stage must be new and under Temp.' }
$profile = Join-Path $Destination 'profile'
$stage = Join-Path $Destination 'imports\qs'
& "$repo\windows\scripts\Stage-ShellPrototype.ps1" -Destination $stage -ProfileRoot $profile -Prototype shell-live | Out-Null
foreach ($name in @('config', 'state', 'runtime', 'cache', 'data')) {
    New-Item -ItemType Directory -Force -Path "$profile\$name" | Out-Null
}
$config = Get-Content "$repo\windows\shell\shell.json" -Raw | ConvertFrom-Json
$config.background.enabled = $false
$config.windows.clipboard.enabled = $false
$config.session.commands = @{}
$config | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath "$profile\config\shell.json" -Encoding UTF8
'{"binds":[]}' | Set-Content -LiteralPath "$profile\config\keybinds.json" -Encoding UTF8
$header = @('data', 'state', 'cache') | ForEach-Object {
    "//@ pragma $($_.Substring(0,1).ToUpper() + $_.Substring(1))Dir $profile\$_"
}
$entry = ($header -join "`n") + "`n" + [IO.File]::ReadAllText("$PSScriptRoot\Bench.qml")
[IO.File]::WriteAllText("$stage\Bench.qml", $entry, [Text.UTF8Encoding]::new($false))
