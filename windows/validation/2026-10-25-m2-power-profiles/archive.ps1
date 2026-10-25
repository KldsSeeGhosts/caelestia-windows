param(
    [Parameter(Mandatory)][string]$ValidationRoot,
    [Parameter(Mandatory)][string]$ArchiveRoot
)
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..\..')).Path
$buildRoot = 'D:\AiStack\caelestia-windows\windows\.local\build'
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
}
function Copy-Fixture($Fixture, $Prefix) {
    $base = $(if ($Prefix -eq '.') { 'fixture' } else { "$Prefix/fixture" })
    if ($null -ne $Fixture.battery -and $null -ne $Fixture.profiles) {
        # Test-BatteryService runs two pure fixtures and reports both.
        Copy-Evidence $Fixture.battery.stdout "$base/battery.stdout.log"
        Copy-Evidence $Fixture.battery.stderr "$base/battery.stderr.log"
        Copy-Evidence $Fixture.profiles.stdout "$base/profiles.stdout.log"
        Copy-Evidence $Fixture.profiles.stderr "$base/profiles.stderr.log"
        $prefix = $Fixture.battery.stdout -replace '\.battery\.stdout\.log$', ''
        Copy-Evidence "$prefix.json" "$base/result.json"
        foreach ($source in $Fixture.sources) {
            $fileName = Split-Path -Leaf $source.source
            Copy-Evidence (Join-Path $Fixture.stage $fileName) "$base/$fileName"
        }
    } else {
        # Other slices (for example audio) report one fixture record.
        Copy-Run $Fixture $base
        foreach ($source in $Fixture.sources) {
            $fileName = Split-Path -Leaf $source.source
            Copy-Evidence (Join-Path $Fixture.stage $fileName) "$base/$fileName"
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
        } elseif ($record.kind -eq 'fixture') {
            Copy-Fixture $record.result $Prefix
        } else {
            $name = $record.kind
            if ($record.kind -in @('battery', 'audio')) {
                $mode = $(if ($record.kind -eq 'battery') { $record.result.batteryMode } else { $record.result.audioMode })
                $name = "$name-$($mode.ToLowerInvariant())-screen$($record.result.screenIndex)"
            }
            Copy-Run $record.result "$Prefix/$name"
        }
    }
}
Copy-Matrix $ValidationRoot '.'
foreach ($file in @('build.json', 'server.log')) {
    if (Test-Path -LiteralPath (Join-Path $buildRoot "logs/$file")) {
        Copy-Evidence (Join-Path $buildRoot "logs/$file") "build/$file"
    }
}
Copy-Evidence (Join-Path $buildRoot 'battery-prototype-profile/config/shell.json') 'isolated-shell.json'
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
