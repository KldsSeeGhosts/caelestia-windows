param(
    [Parameter(Mandatory)][string]$HarnessOutput,
    [Parameter(Mandatory)][string]$FixtureResult,
    [Parameter(Mandatory)][string]$MediaFixtureResult,
    [string]$BatteryFixtureResult,
    [Parameter(Mandatory)][string]$ArchiveRoot
)
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..\..')).Path
$buildRoot = Join-Path $repoRoot 'windows\.local\build'
$ArchiveRoot = [IO.Path]::GetFullPath($ArchiveRoot)
if (-not $ArchiveRoot.StartsWith($repoRoot + '\windows\validation\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Archive must be inside windows/validation.'
}
function Copy-Evidence([string]$Source, [string]$RelativePath) {
    $target = Join-Path $ArchiveRoot $RelativePath
    if ([IO.Path]::GetFullPath($Source) -eq [IO.Path]::GetFullPath($target)) { return }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
    Copy-Item -LiteralPath $Source -Destination $target
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
    if ($Run.fixture) {
        foreach ($source in $Run.sources) {
            $fileName = Split-Path -Leaf $source.source
            Copy-Evidence (Join-Path $Run.stage $fileName) "$Name/staged-$fileName"
        }
    }
}
function Copy-Fixture([string]$ResultPath, [string]$Name, [switch]$Staged) {
    $run = Get-Content -LiteralPath $ResultPath -Raw | ConvertFrom-Json
    Copy-Run $run $Name
    if ($Staged) {
        foreach ($source in $run.sources) {
            $fileName = Split-Path -Leaf $source.source
            Copy-Evidence (Join-Path $run.stage $fileName) "$Name/staged-$fileName"
        }
    }
}
$matrix = Get-Content -LiteralPath (Join-Path $HarnessOutput 'result.json') -Raw | ConvertFrom-Json
if (-not $matrix.passed) { throw 'Harness did not pass.' }
if ($matrix.sourceDirty) { throw 'Acceptance must be a clean-source run.' }
Copy-Evidence (Join-Path $HarnessOutput 'result.json') 'matrix.json'
foreach ($file in Get-ChildItem -LiteralPath $HarnessOutput -File -Filter '*.json') {
    if ($file.Name -ne 'result.json') { Copy-Evidence $file.FullName $file.Name }
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
Copy-Fixture $FixtureResult 'fixture-standalone' -Staged
Copy-Fixture $MediaFixtureResult 'regressions/media-service' -Staged
if ($BatteryFixtureResult) { Copy-Fixture $BatteryFixtureResult 'regressions/battery-service' -Staged }
foreach ($file in @('build.json', 'environment.json')) {
    $path = Join-Path $buildRoot "logs/$file"
    if (Test-Path -LiteralPath $path) { Copy-Evidence $path "build/$file" }
}
Copy-Evidence $PSCommandPath 'archive.ps1'
$entries = @(Get-ChildItem -LiteralPath $ArchiveRoot -File -Recurse | Where-Object {
    $_.Name -notin @('README.md', '.gitignore', '.gitattributes', 'artifacts.sha256.json')
} | Sort-Object FullName | ForEach-Object {
    [ordered]@{
        path = $_.FullName.Substring($ArchiveRoot.Length + 1).Replace('\', '/')
        sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
        bytes = $_.Length
    }
})
$entries | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $ArchiveRoot 'artifacts.sha256.json') -Encoding UTF8
[pscustomobject]@{ archive = $ArchiveRoot; artifacts = $entries.Count }
