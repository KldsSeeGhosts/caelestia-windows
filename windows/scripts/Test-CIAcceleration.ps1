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
    Assert-Refused { & "$ci\Get-BuildJobs.ps1" -LogicalProcessors 0 -MemoryBytes 16GB -EnvironmentFile '' } 'refusing to guess' 'zero processors'
    Assert-Refused { & "$ci\Get-BuildJobs.ps1" -LogicalProcessors 4 -MemoryBytes 0 -EnvironmentFile '' } 'refusing to guess' 'zero memory'

    # The compiler cache is enabled only from the exact pinned archive. Each
    # refusal happens before extraction and before any CI environment change.
    $pin = Get-Content -LiteralPath "$ci\compiler-cache.json" -Raw | ConvertFrom-Json
    if ($pin.sha256 -cnotmatch '^[a-f0-9]{64}$' -or $pin.url -notlike 'https://github.com/ccache/ccache/releases/download/*') {
        throw 'The committed compiler-cache pin is not an immutable public release digest.'
    }
    $checks++
    $environment = Join-Path $root 'cache-env'
    $forged = Join-Path $root $pin.file
    [IO.File]::WriteAllText($forged, 'not the pinned release')
    $tool = Join-Path $root 'tool-forged'
    Assert-Refused { & "$ci\Enable-CompilerCache.ps1" -ToolDirectory $tool -CacheDirectory (Join-Path $root 'cache') `
        -Archive $forged -EnvironmentFile $environment } 'checksum mismatch' 'forged archive'
    if ((Test-Path -LiteralPath $environment) -or (Test-Path -LiteralPath "$tool\ccache.exe")) {
        throw 'A refused compiler-cache archive changed the CI environment or extracted a tool.'
    }
    $checks++
    $badPin = Join-Path $root 'bad-pin.json'
    $changed = $pin.PSObject.Copy()
    $changed.url = 'https://example.invalid/ccache.zip'
    $changed | ConvertTo-Json | Set-Content -LiteralPath $badPin -Encoding UTF8
    Assert-Refused { & "$ci\Enable-CompilerCache.ps1" -ToolDirectory (Join-Path $root 'tool-pin') `
        -CacheDirectory (Join-Path $root 'cache') -Archive $forged -Pin $badPin -EnvironmentFile $environment } 'Invalid compiler-cache pin' 'unpinned source'
    Assert-Refused { & "$ci\Enable-CompilerCache.ps1" -ToolDirectory (Join-Path $repoRoot 'windows\.ccache-tool') `
        -CacheDirectory (Join-Path $root 'cache') -Archive $forged -EnvironmentFile $environment } 'outside the source checkout' 'tool in checkout'
    Assert-Refused { & "$ci\Enable-CompilerCache.ps1" -ToolDirectory (Join-Path $root 'tool-cache') `
        -CacheDirectory (Join-Path $repoRoot 'windows\.ccache') -Archive $forged -EnvironmentFile $environment } 'outside the source checkout' 'cache in checkout'
    New-Item -ItemType Directory -Path (Join-Path $root 'tool-existing') | Out-Null
    Assert-Refused { & "$ci\Enable-CompilerCache.ps1" -ToolDirectory (Join-Path $root 'tool-existing') `
        -CacheDirectory (Join-Path $root 'cache') -Archive $forged -EnvironmentFile $environment } 'must be fresh' 'reused tool directory'
    if (Test-Path -LiteralPath $environment) { throw 'A refused compiler-cache setup changed the CI environment.' }
    Write-Output "PASS CI acceleration: $checks parallelism and compiler-cache trust checks."
} finally {
    $resolved = [IO.Path]::GetFullPath($root)
    if ((Split-Path -Parent $resolved) -ne [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') -or
        (Split-Path -Leaf $resolved) -notlike 'caelestia-ci-acceleration-*') { throw 'Unsafe CI-acceleration fixture cleanup.' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
