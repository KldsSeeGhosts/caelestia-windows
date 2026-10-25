[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ValidationDir,
    [string]$BuildRoot
)

# Copy the raw artifacts referenced by one Test-AppsPrototype run into this
# archive without rewriting them. Only reads from the ignored build tree and the
# recorded validation directory.
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..\..')).Path
if (-not $BuildRoot) { $BuildRoot = Join-Path $repoRoot 'windows\.local\build' }
$ValidationDir = [IO.Path]::GetFullPath($ValidationDir)
$result = Get-Content -LiteralPath (Join-Path $ValidationDir 'result.json') -Raw | ConvertFrom-Json
$output = [ordered]@{ copied = @(); runs = @() }

function Copy-Artifact([string]$Source, [string]$Destination) {
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf)) { throw "Missing artifact: $Source" }
    $target = Join-Path $PSScriptRoot $Destination
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
    Copy-Item -LiteralPath $Source -Destination $target -Force
    $output.copied += [ordered]@{
        source = $Source
        archived = $Destination
        sha256 = (Get-FileHash -LiteralPath $target).Hash
    }
}

foreach ($name in @('desktop-before.json', 'desktop-after.json', 'result.json')) {
    Copy-Artifact (Join-Path $ValidationDir $name) $name
}

# Shared regression fixture outputs recorded in the same session.
foreach ($name in @('media-service.json', 'battery-service.json')) {
    $source = Join-Path $BuildRoot "logs\apps-evidence-20261025\$name"
    if (Test-Path -LiteralPath $source -PathType Leaf) {
        Copy-Artifact $source "shared-regressions\$name"
    }
}

$runs = New-Object Collections.Generic.List[object]
foreach ($record in $result.records) {
    $run = $record.result
    $folder = switch ($record.kind) {
        'fixture' { 'fixture' }
        'apps' { 'apps-' + $run.appsMode.ToLowerInvariant() + '-screen' + $run.screenIndex }
        'apps-frequency-read' { 'apps-frequency-read' }
        'apps-corrupt-frequency' { 'apps-corrupt-frequency' }
        'm1-regression' { 'm1-regression' }
        default { throw "Unknown record kind: $($record.kind)" }
    }
    Copy-Artifact $run.stdout "$folder\stdout.log"
    Copy-Artifact $run.stderr "$folder\stderr.log"
    $logJson = $run.stdout -replace '\.stdout\.log$', '.json'
    if (Test-Path -LiteralPath $logJson -PathType Leaf) {
        Copy-Artifact $logJson "$folder\result.json"
    }
    if ($run.sources -is [string] -and (Test-Path -LiteralPath $run.sources -PathType Leaf)) {
        Copy-Artifact $run.sources "$folder\sources.json"
    }
    if ($run.PSObject.Properties.Name -contains 'screenshot' -and $run.screenshot) {
        Copy-Artifact $run.screenshot "$folder\capture.png"
    }
    $runs.Add([ordered]@{
        kind = $record.kind
        folder = $folder
        passed = $run.passed
        prototype = $run.prototype
        mode = $run.appsMode
        screenIndex = $run.screenIndex
        scaleFactor = $run.scaleFactor
        status = $(if ($run.appsSnapshots) { $run.appsSnapshots[0].state.status } else { $null })
        count = $(if ($run.appsSnapshots) { $run.appsSnapshots[0].state.count } else { $null })
        query = $(if ($run.appsSearches) { $run.appsSearches[0].query } else { $null })
        queryCount = $(if ($run.appsSearches) { $run.appsSearches[0].queryCount } else { $null })
        assertions = $run.fixture.assertions
    })
}

# The staged fixture sources are the exact bytes qml.exe loaded.
$fixtureRecord = $result.records | Where-Object { $_.kind -eq 'fixture' } | Select-Object -First 1
if ($fixtureRecord) {
    foreach ($entry in $fixtureRecord.result.sources) {
        Copy-Artifact (Join-Path $fixtureRecord.result.stage $entry.staged) (Join-Path 'fixture' (Split-Path -Leaf $entry.staged))
    }
}

$matrix = [ordered]@{
    sourceRevision = $result.sourceRevision
    sourceDirty = $result.sourceDirty
    backendRevision = $result.backendRevision
    validationDir = $ValidationDir
    passed = $result.passed
    runs = @($runs.ToArray())
}
$matrix | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'matrix.json') -Encoding utf8

$artifacts = [ordered]@{
    generatedAtUtc = [DateTime]::UtcNow.ToString('o')
    files = @($output.copied | Sort-Object archived)
}
$artifacts | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'artifacts.sha256.json') -Encoding utf8
[ordered]@{ copied = $output.copied.Count; runs = $runs.Count; validationDir = $ValidationDir } | ConvertTo-Json
