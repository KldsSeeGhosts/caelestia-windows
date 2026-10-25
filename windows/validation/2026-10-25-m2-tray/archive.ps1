[CmdletBinding()]
param(
    # Directory printed by Test-TrayPrototype.ps1 (contains result.json).
    [Parameter(Mandatory)][string]$RunRoot,
    # Build root used for the run; its logs/ hold the per-run records.
    [Parameter(Mandatory)][string]$BuildRoot
)

# Copies the raw validation artifacts into this archive without rewriting paths,
# then records every copied file's SHA-256. Run from the repository root after
# Test-TrayPrototype.ps1 has produced a clean result.
$ErrorActionPreference = 'Stop'
$destination = [IO.Path]::GetFullPath($PSScriptRoot)
$runRoot = [IO.Path]::GetFullPath($RunRoot)
$BuildRoot = [IO.Path]::GetFullPath($BuildRoot)
$logRoot = Join-Path $BuildRoot 'logs'
$run = Get-Content -LiteralPath (Join-Path $runRoot 'result.json') -Raw | ConvertFrom-Json
if (-not $run.passed) { throw 'The run result is not passing; nothing was archived.' }
Copy-Item -LiteralPath (Join-Path $runRoot 'result.json') -Destination (Join-Path $destination 'matrix.json') -Force
foreach ($name in @('desktop-before.json', 'desktop-after.json')) {
    Copy-Item -LiteralPath (Join-Path $runRoot $name) -Destination (Join-Path $destination $name) -Force
}

function Get-RunName($Result) {
    if ($Result.stage) { return [IO.Path]::GetFileName($Result.stage.TrimEnd('\')) }
    if ($Result.stdout) { return [IO.Path]::GetFileNameWithoutExtension($Result.stdout) }
    return $null
}

function Copy-RunEvidence($Result, [string]$Folder, [switch]$Screenshot, [switch]$Sources) {
    $target = Join-Path $destination $Folder
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    $name = Get-RunName $Result
    Copy-Item -LiteralPath (Join-Path $logRoot "$name.json") -Destination (Join-Path $target 'result.json') -Force
    foreach ($ext in @('stdout', 'stderr')) {
        $path = Join-Path $logRoot "$name.$ext.log"
        if (Test-Path -LiteralPath $path) {
            Copy-Item -LiteralPath $path -Destination (Join-Path $target "$ext.log") -Force
        }
    }
    if ($Screenshot) {
        Copy-Item -LiteralPath $Result.screenshot -Destination (Join-Path $target 'capture.png') -Force
    }
    if ($Sources) {
        Copy-Item -LiteralPath $Result.sources -Destination (Join-Path $target 'sources.json') -Force
    }
}

$screenNames = @{}
foreach ($record in $run.records) {
    switch ($record.kind) {
        'fixture' {
            $fixture = $record.result
            Copy-RunEvidence $fixture 'fixture'
            foreach ($name in @('TrayService.qml', 'TrayServiceTest.qml')) {
                Copy-Item -LiteralPath (Join-Path $fixture.stage $name) -Destination (Join-Path $destination "fixture\$name") -Force
            }
        }
        'tray' {
            $folder = "tray-$($record.mode.ToLowerInvariant())-screen$($record.screen)"
            Copy-RunEvidence $record.result $folder -Screenshot -Sources
        }
        'tray-fixture' {
            Copy-RunEvidence $record.result 'tray-fixture' -Screenshot -Sources
        }
        'm1-regression' {
            Copy-RunEvidence $record.result 'm1-regression' -Screenshot
        }
        'media-fixture' {
            Copy-RunEvidence $record.result 'shared-regressions/media-fixture'
        }
        'battery-fixture' {
            Copy-RunEvidence $record.result 'shared-regressions/battery-fixture'
        }
        default { }
    }
}

# Build provenance from the root used for these runs.
$build = Join-Path $destination 'build'
New-Item -ItemType Directory -Force -Path $build | Out-Null
foreach ($name in @('build.json', 'environment.json', 'configure-backend-command.json',
    'build-backend-command.json', 'configure-plugins-command.json',
    'build-plugins-command.json', 'install-plugins-command.json',
    'configure-backend.log', 'build-backend.log', 'configure-plugins.log',
    'build-plugins.log', 'install-plugins.log')) {
    $path = Join-Path $logRoot $name
    if (Test-Path -LiteralPath $path) {
        Copy-Item -LiteralPath $path -Destination (Join-Path $build $name) -Force
    }
}

$files = Get-ChildItem -LiteralPath $destination -Recurse -File |
    Where-Object { $_.Name -notin @('artifacts.sha256.json', 'archive.ps1', 'README.md') } |
    Sort-Object FullName
$base = $destination.TrimEnd('\') + '\'
$artifacts = foreach ($file in $files) {
    [ordered]@{
        # Windows PowerShell 5.1 has no Path.GetRelativePath.
        path = $file.FullName.Substring($base.Length).Replace('\', '/')
        bytes = $file.Length
        sha256 = (Get-FileHash -LiteralPath $file.FullName).Hash
    }
}
$artifacts | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $destination 'artifacts.sha256.json') -Encoding UTF8
Write-Output "Archived $($artifacts.Count) artifacts into $destination"
