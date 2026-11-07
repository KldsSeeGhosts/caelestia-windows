[CmdletBinding()]
param(
    # Overrides exist for regression tests; CI measures the actual runner.
    [int]$LogicalProcessors = [Environment]::ProcessorCount,
    [double]$MemoryBytes = -1,
    [string]$EnvironmentFile = $env:GITHUB_ENV
)
$ErrorActionPreference = 'Stop'
if ($MemoryBytes -lt 0) {
    $MemoryBytes = [double](Get-CimInstance -ClassName Win32_ComputerSystem).TotalPhysicalMemory
}
# One compile job per logical processor, bounded by 3 GiB of physical memory
# per job for the heaviest Qt/clang-cl translation units, and by the trusted
# fixture runner's accepted range (1-16). Tests are never parallelized here.
if ($LogicalProcessors -lt 1 -or $MemoryBytes -le 0 -or [double]::IsNaN($MemoryBytes)) {
    throw 'Cannot measure runner processors and memory; refusing to guess build parallelism.'
}
$byMemory = [Math]::Floor($MemoryBytes / 3GB)
$jobs = [int][Math]::Max(1, [Math]::Min(16, [Math]::Min($LogicalProcessors, $byMemory)))
if ($EnvironmentFile) { "BUILD_JOBS=$jobs" | Add-Content -LiteralPath $EnvironmentFile -Encoding UTF8 }
Write-Output ("Build parallelism: {0} jobs ({1} logical processors, {2:N1} GiB memory)" -f $jobs, $LogicalProcessors, ($MemoryBytes / 1GB))
