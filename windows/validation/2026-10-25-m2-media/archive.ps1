param(
    [Parameter(Mandatory)][string]$ValidationRoot,
    [Parameter(Mandatory)][string]$SharedValidationRoot,
    [Parameter(Mandatory)][string]$ArchiveRoot
)
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$buildRoot = Join-Path $repoRoot 'windows\.local\build'
$ArchiveRoot = [IO.Path]::GetFullPath($ArchiveRoot)
if (-not $ArchiveRoot.StartsWith($repoRoot + '\windows\validation\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Archive must be inside windows/validation.'
}
function Copy-Evidence([string]$Source, [string]$RelativePath) {
    $target = Join-Path $ArchiveRoot $RelativePath
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
    Copy-Item -LiteralPath $Source -Destination $target
}
function Copy-Run($Run, [string]$Name) {
    Copy-Evidence $Run.stdout "$Name/stdout.log"
    Copy-Evidence $Run.stderr "$Name/stderr.log"
    $prefix = $Run.stdout -replace '\.stdout\.log$', ''
    Copy-Evidence "$prefix.json" "$Name/result.json"
    if (Test-Path -LiteralPath "$prefix.sources.json") {
        Copy-Evidence "$prefix.sources.json" "$Name/sources.json"
    }
    foreach ($capture in $Run.captures) {
        Copy-Evidence ([uri]$capture).LocalPath "$Name/capture.png"
    }
    if ($Run.fixture) {
        foreach ($source in $Run.sources) {
            $fileName = Split-Path -Leaf $source.source
            Copy-Evidence (Join-Path $Run.stage $fileName) "$Name/$fileName"
        }
    }
}
function Copy-Matrix([string]$SourceRoot, [string]$Prefix) {
    $matrix = Get-Content -LiteralPath (Join-Path $SourceRoot 'result.json') -Raw | ConvertFrom-Json
    if (-not $matrix.passed -or $matrix.sourceDirty) { throw 'Acceptance must be a passing clean-source run.' }
    Copy-Evidence (Join-Path $SourceRoot 'result.json') "$Prefix/matrix.json"
    foreach ($file in Get-ChildItem -LiteralPath $SourceRoot -File -Filter '*.json') {
        if ($file.Name -ne 'result.json') { Copy-Evidence $file.FullName "$Prefix/$($file.Name)" }
    }
    foreach ($record in $matrix.records) {
        if ($record.kind -eq 'audio-regression') {
            Copy-Matrix $record.result.output "$Prefix/audio-regression"
        } else {
            $name = $record.kind
            if ($record.kind -in @('battery', 'audio', 'media')) {
                $mode = $(if ($record.kind -eq 'battery') { $record.result.batteryMode } elseif ($record.kind -eq 'media') { $record.result.mediaMode } else { $record.result.audioMode })
                $name = "$name-$($mode.ToLowerInvariant())-screen$($record.result.screenIndex)"
            }
            Copy-Run $record.result "$Prefix/$name"
        }
    }
}
Copy-Matrix $ValidationRoot '.'
Copy-Matrix $SharedValidationRoot 'shared-regressions'
foreach ($file in @(
    'build.json', 'environment.json', 'configure-backend-command.json',
    'configure-backend.log', 'build-backend-command.json', 'build-backend.log',
    'configure-plugins-command.json', 'configure-plugins.log',
    'build-plugins-command.json', 'build-plugins.log',
    'install-plugins-command.json', 'install-plugins.log'
)) {
    Copy-Evidence (Join-Path $buildRoot "logs/$file") "build/$file"
}
foreach ($file in @('result.json', 'mpris_status_test.txt', 'mpris_art_cache_test.txt', 'configure-command.json', 'configure.log', 'build-command.json', 'build.log')) {
    Copy-Evidence (Join-Path $buildRoot "media-backend-tests/$file") "backend-fixtures/$file"
}
Copy-Evidence (Join-Path $buildRoot 'media-prototype-profile/config/shell.json') 'isolated-shell.json'
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
[pscustomobject]@{archive=$ArchiveRoot;artifacts=$entries.Count}
