#requires -Version 5.1
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath "$PSScriptRoot\..\..").Path
$ci = Join-Path $repoRoot 'windows\ci'
$root = Join-Path ([IO.Path]::GetTempPath()) ('caelestia-ci-acceleration-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$checks = 0
function Assert-Refused([scriptblock]$Action, [string]$Pattern, [string]$Name) {
    $message = $null
    try { & $Action | Out-Null } catch { $message = $_.Exception.Message }
    if (-not $message -or $message -notmatch $Pattern) { throw "Expected refusal was not raised: $Name ($message)" }
    $script:checks++
}
try {
    # Hardware-derived parallelism: bounded by processors, 3 GiB per job and
    # the trusted fixture runner's 1-16 range; unmeasurable hardware refuses.
    foreach ($case in @(
        @{ cpu = 4; memory = 16GB; jobs = 4 },
        @{ cpu = 4; memory = 7GB; jobs = 2 },
        @{ cpu = 4; memory = (6GB - 1); jobs = 1 },
        @{ cpu = 4; memory = 6GB; jobs = 2 },
        @{ cpu = 64; memory = 512GB; jobs = 16 },
        @{ cpu = [int]::MaxValue; memory = [double]::MaxValue; jobs = 16 },
        @{ cpu = 16; memory = 63.6GB; jobs = 16 },
        @{ cpu = 1; memory = 1GB; jobs = 1 })) {
        $environment = Join-Path $root ('env-' + [guid]::NewGuid().ToString('N'))
        $null = & "$ci\Get-BuildJobs.ps1" -LogicalProcessors $case.cpu -MemoryBytes $case.memory -EnvironmentFile $environment
        $actual = (Get-Content -LiteralPath $environment -Raw).Trim()
        if ($actual -cne "BUILD_JOBS=$($case.jobs)") { throw "Incorrect build parallelism for $($case.cpu) CPUs: $actual" }
        $checks++
    }
    $environment = Join-Path $root 'refused-env'
    Assert-Refused { & "$ci\Get-BuildJobs.ps1" -LogicalProcessors 0 -MemoryBytes 16GB -EnvironmentFile $environment } 'refusing to guess' 'zero processors'
    Assert-Refused { & "$ci\Get-BuildJobs.ps1" -LogicalProcessors 4 -MemoryBytes 0 -EnvironmentFile $environment } 'refusing to guess' 'zero memory'
    foreach ($invalid in @(-1, [double]::NaN, [double]::PositiveInfinity, [double]::NegativeInfinity)) {
        Assert-Refused { & "$ci\Get-BuildJobs.ps1" -LogicalProcessors 4 -MemoryBytes $invalid -EnvironmentFile $environment } 'refusing to guess' "invalid memory $invalid"
    }
    if (Test-Path -LiteralPath $environment) { throw 'A refused parallelism measurement still wrote BUILD_JOBS.' }
    $checks++
    # Exercise the default discovery branch too, without assuming anything
    # about the machine running this SDK-free regression.
    function Get-CimInstance {
        param([string]$ClassName)
        if ($ClassName -cne 'Win32_ComputerSystem') { throw 'Unexpected hardware query.' }
        return [pscustomobject]@{ TotalPhysicalMemory = $fixtureMemory }
    }
    $fixtureMemory = 7GB
    $environment = Join-Path $root 'measured-env'
    $null = & "$ci\Get-BuildJobs.ps1" -LogicalProcessors 4 -EnvironmentFile $environment
    if ((Get-Content -LiteralPath $environment -Raw).Trim() -cne 'BUILD_JOBS=2') {
        throw 'The measured hardware path did not use the detected memory.'
    }
    $checks++
    $environment = Join-Path $root 'invalid-measured-env'
    foreach ($invalid in @($null, -1, [double]::NaN, [double]::PositiveInfinity)) {
        $fixtureMemory = $invalid
        Assert-Refused { & "$ci\Get-BuildJobs.ps1" -LogicalProcessors 4 -EnvironmentFile $environment } 'refusing to guess' "invalid measured memory $invalid"
    }
    if (Test-Path -LiteralPath $environment) { throw 'Invalid measured hardware still wrote BUILD_JOBS.' }
    $checks++
    Write-Output "PASS CI acceleration: $checks build-parallelism checks."
} finally {
    $resolved = [IO.Path]::GetFullPath($root)
    if ((Split-Path -Parent $resolved) -ne [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') -or
        (Split-Path -Leaf $resolved) -notlike 'caelestia-ci-acceleration-*') { throw 'Unsafe CI-acceleration fixture cleanup.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
