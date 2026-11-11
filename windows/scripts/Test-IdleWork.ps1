[CmdletBinding()]
param([Parameter(Mandatory)][string]$QtPrefix, [Parameter(Mandatory)][string]$BuildRoot)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path "$PSScriptRoot\..\..").Path
$env:QT_QPA_PLATFORM = 'offscreen'
& python -B "$repo\windows\bench\idle_work.py" --test --seconds 16 --build $BuildRoot --qt $QtPrefix
if ($LASTEXITCODE -ne 0) { throw 'Idle process/clock regression failed.' }
Write-Output '{"assertions": 14}'
