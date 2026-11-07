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
        @{ cpu = 64; memory = 512GB; jobs = 16 },
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
    if (Test-Path -LiteralPath $environment) { throw 'A refused parallelism measurement still wrote BUILD_JOBS.' }
    $checks++
    Write-Output "PASS CI acceleration: $checks build-parallelism checks."
} finally {
    $resolved = [IO.Path]::GetFullPath($root)
    if ((Split-Path -Parent $resolved) -ne [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') -or
        (Split-Path -Leaf $resolved) -notlike 'caelestia-ci-acceleration-*') { throw 'Unsafe CI-acceleration fixture cleanup.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
