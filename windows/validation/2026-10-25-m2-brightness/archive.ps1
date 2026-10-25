[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ValidationOutput,
    [Parameter(Mandatory)][string]$LogRoot,
    [Parameter(Mandatory)][string]$Destination
)

$ErrorActionPreference = 'Stop'
$ValidationOutput = [IO.Path]::GetFullPath($ValidationOutput)
$LogRoot = [IO.Path]::GetFullPath($LogRoot)
$Destination = [IO.Path]::GetFullPath($Destination)
New-Item -ItemType Directory -Force -Path $Destination | Out-Null
$matrix = Get-Content -LiteralPath (Join-Path $ValidationOutput 'result.json') -Raw | ConvertFrom-Json
Copy-Item -LiteralPath (Join-Path $ValidationOutput 'result.json') -Destination (Join-Path $Destination 'matrix.json') -Force
foreach ($name in @('desktop-before', 'desktop-after', 'gamma-before', 'gamma-after')) {
    Copy-Item -LiteralPath (Join-Path $ValidationOutput "$name.json") -Destination (Join-Path $Destination "$name.json") -Force
}

function Copy-Run([string]$Folder, $Result) {
    $target = Join-Path $Destination $Folder
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    $Result | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $target 'result.json') -Encoding UTF8
    foreach ($property in @('sources', 'stdout', 'stderr', 'screenshot')) {
        $path = $Result.$property
        if ($path -is [string] -and (Test-Path -LiteralPath $path -PathType Leaf)) {
            Copy-Item -LiteralPath $path -Destination (Join-Path $target (Split-Path -Leaf $path)) -Force
        }
    }
}

foreach ($record in $matrix.records) {
    if ($record.kind -eq 'fixture') {
        Copy-Run 'fixture' $record.result
        $staged = Get-ChildItem -LiteralPath (Join-Path $record.result.stage 'BrightnessServiceTest.qml') -ErrorAction SilentlyContinue
        if ($staged) {
            Copy-Item -LiteralPath $staged.FullName -Destination (Join-Path $Destination 'fixture\BrightnessServiceTest.qml') -Force
        }
    } elseif ($record.kind -eq 'brightness') {
        $folder = 'brightness-{0}-screen{1}' -f $record.result.brightnessMode.ToLowerInvariant(), $record.result.screenIndex
        Copy-Run $folder $record.result
    } elseif ($record.kind -eq 'm1-regression') {
        Copy-Run 'm1-regression' $record.result
    }
}

# Copy the standalone final fixture and regression JSON logs that were captured
# with explicit commands, so the archive does not rely on the build directory.
foreach ($name in @('final-brightness-service.json', 'final-media-service.json', 'final-battery-service.json')) {
    $source = Join-Path $LogRoot $name
    if (Test-Path -LiteralPath $source -PathType Leaf) {
        New-Item -ItemType Directory -Force -Path (Join-Path $Destination 'commands') | Out-Null
        Copy-Item -LiteralPath $source -Destination (Join-Path $Destination "commands\$name") -Force
    }
}
$protocol = Join-Path $LogRoot 'final-brightness-prototype.log'
if (Test-Path -LiteralPath $protocol -PathType Leaf) {
    New-Item -ItemType Directory -Force -Path (Join-Path $Destination 'commands') | Out-Null
    Copy-Item -LiteralPath $protocol -Destination (Join-Path $Destination 'commands\final-brightness-prototype.log') -Force
}

$artifacts = Get-ChildItem -LiteralPath $Destination -Recurse -File |
    Where-Object { $_.Name -ne 'artifacts.sha256.json' -and $_.Name -ne 'archive.ps1' } |
    Sort-Object FullName |
    ForEach-Object {
        [ordered]@{
            path = $_.FullName.Substring($Destination.Length + 1).Replace('\', '/')
            bytes = $_.Length
            sha256 = (Get-FileHash -LiteralPath $_.FullName).Hash.ToLowerInvariant()
        }
    }
[ordered]@{ sourceRevision = $matrix.sourceRevision; backendRevision = $matrix.backendRevision
    validationOutput = $ValidationOutput; artifacts = @($artifacts) } |
    ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $Destination 'artifacts.sha256.json') -Encoding UTF8
Write-Output ([ordered]@{ destination = $Destination; artifacts = @($artifacts).Count } | ConvertTo-Json)
