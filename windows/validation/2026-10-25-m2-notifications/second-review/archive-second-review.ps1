param(
    [Parameter(Mandatory)][string]$HarnessOutput,
    [Parameter(Mandatory)][string]$FixtureResult,
    [Parameter(Mandatory)][string]$ArchiveRoot
)
$ErrorActionPreference = 'Stop'
$validationRoot = (Resolve-Path -LiteralPath $PSScriptRoot).Path
$ArchiveRoot = [IO.Path]::GetFullPath($ArchiveRoot)
if (-not $ArchiveRoot.StartsWith($validationRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Archive must be inside the validation folder.'
}
function Copy-Evidence([string]$Source, [string]$RelativePath) {
    $target = Join-Path $ArchiveRoot $RelativePath
    if ([IO.Path]::GetFullPath($Source) -eq [IO.Path]::GetFullPath($target)) { return }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
    Copy-Item -LiteralPath $Source -Destination $target -Force
}
function Copy-Run($Run, [string]$Name) {
    Copy-Evidence $Run.stdout "$Name/stdout.log"
    Copy-Evidence $Run.stderr "$Name/stderr.log"
    $prefix = $Run.stdout -replace '\.stdout\.log$', ''
    Copy-Evidence "$prefix.json" "$Name/result.json"
    if ($Run.sources -is [string] -and (Test-Path -LiteralPath $Run.sources)) {
        Copy-Evidence $Run.sources "$Name/sources.json"
    }
    if ($Run.screenshot -and (Test-Path -LiteralPath $Run.screenshot)) {
        Copy-Evidence $Run.screenshot "$Name/capture.png"
    }
}
function Copy-Fixture([string]$ResultPath, [string]$Name) {
    $run = Get-Content -LiteralPath $ResultPath -Raw | ConvertFrom-Json
    Copy-Run $run $Name
    foreach ($source in $run.sources) {
        $fileName = Split-Path -Leaf $source.source
        Copy-Evidence (Join-Path $run.stage $fileName) "$Name/staged-$fileName"
    }
}
$matrix = Get-Content -LiteralPath (Join-Path $HarnessOutput 'result.json') -Raw | ConvertFrom-Json
if (-not $matrix.passed) { throw 'Harness did not pass.' }
if ($matrix.sourceDirty) { throw 'Acceptance must be a clean-source run.' }
$fixture = Get-Content -LiteralPath $FixtureResult -Raw | ConvertFrom-Json
if (-not $fixture.passed) { throw 'Fixture did not pass.' }
if ($fixture.sourceDirty) { throw 'Fixture acceptance must be a clean-source run.' }
Copy-Evidence (Join-Path $HarnessOutput 'result.json') 'matrix.json'
foreach ($file in @('desktop-before.json', 'desktop-after.json')) {
    Copy-Evidence (Join-Path $HarnessOutput $file) $file
}
$seen = @{}
foreach ($record in $matrix.records) {
    $name = $record.kind
    if ($record.kind -in @('disabled', 'local-persist', 'local-expire-dismiss', 'local-extra-screen')) {
        $name = "$($record.kind)-$($record.result.notificationsMode.ToLowerInvariant())-screen$($record.result.screenIndex)"
    }
    if ($seen.ContainsKey($name)) { $seen[$name]++; $name = "$name-$($seen[$name])" } else { $seen[$name] = 1 }
    Copy-Run $record.result $name
}
Copy-Fixture $FixtureResult 'fixture-standalone'
Copy-Evidence $PSCommandPath 'archive-second-review.ps1'
$entries = @(Get-ChildItem -LiteralPath $validationRoot -File -Recurse | Where-Object {
    $_.Name -notin @('README.md', '.gitignore', '.gitattributes', 'artifacts.sha256.json')
} | Sort-Object FullName | ForEach-Object {
    [ordered]@{
        path = $_.FullName.Substring($validationRoot.Length + 1).Replace('\', '/')
        sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
        bytes = $_.Length
    }
})
$entries | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $validationRoot 'artifacts.sha256.json') -Encoding UTF8
[pscustomobject]@{
    archive = $ArchiveRoot
    artifacts = $entries.Count
    fixtureAssertions = $fixture.fixture.assertions
    harnessRevision = $matrix.sourceRevision
}
