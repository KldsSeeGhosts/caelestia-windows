[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ShellRoot,
    [Parameter(Mandatory)][string]$BackendRoot,
    [Parameter(Mandatory)][ValidateSet('pinned', 'candidate')][string]$Mode,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}$')][string]$BackendSha,
    [Parameter(Mandatory)][string]$ToolRoot,
    [Parameter(Mandatory)][string]$BuildRoot,
    [Parameter(Mandatory)][string]$Results,
    [Parameter(Mandatory)][string]$JUnit,
    [string]$Python = 'python'
)
$ErrorActionPreference = 'Stop'
$ShellRoot = (Resolve-Path -LiteralPath $ShellRoot).Path
$BackendRoot = (Resolve-Path -LiteralPath $BackendRoot).Path
foreach ($output in @($BuildRoot, $Results)) {
    $absolute = [IO.Path]::GetFullPath($output)
    foreach ($source in @($ShellRoot, $BackendRoot)) {
        if ($absolute -eq $source -or $absolute.StartsWith($source + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Pair outputs must stay outside both source roots.'
        }
    }
}
if (Test-Path -LiteralPath $BuildRoot) { throw 'Pair production build requires a fresh build root.' }
New-Item -ItemType Directory -Force -Path $Results | Out-Null
$spec = Get-Content -LiteralPath "$ShellRoot\windows\toolchain.json" -Raw | ConvertFrom-Json
$qt = Join-Path $ToolRoot $spec.qtDirectory
$llvm = Join-Path $ToolRoot "$($spec.llvmDirectory)\bin"
$tools = Join-Path $ToolRoot 'tools\Scripts'
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$scripts = Join-Path $ShellRoot 'windows\scripts'
$env:PATH = "$tools;$qt\bin;$BuildRoot\caelestia\lib;$env:PATH"
$env:QT_QPA_PLATFORM = 'offscreen'
$env:QT_QPA_PLATFORM_PLUGIN_PATH = "$qt\plugins\platforms"
$env:QT_QUICK_BACKEND = 'software'
$env:PYTHONDONTWRITEBYTECODE = '1'
$journal = @('services', 'production', 'release-toolchain', 'plugins', 'shell', 'smoke') | ForEach-Object {
    [ordered]@{ name = $_; outcome = 'not_run'; exitCode = $null; durationSeconds = $null }
}
function Save-Journal {
    $temporary = Join-Path $Results 'integration-stages.tmp'
    $journal | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $temporary -Encoding UTF8
    Move-Item -LiteralPath $temporary -Destination "$Results\integration-stages.json" -Force
}
function Invoke-Gate([int]$Index, [string]$Executable, [string[]]$CommandArguments) {
    $item = $journal[$Index]
    $item.outcome = 'running'
    Save-Journal
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $code = 1
    try {
        $ErrorActionPreference = 'Continue'
        & $Executable @CommandArguments 2>&1 | ForEach-Object { "$_" } |
            Set-Content -LiteralPath "$Results\$($item.name).private.log" -Encoding UTF8
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = 'Stop'
        $item.exitCode = $code
        $item.durationSeconds = [Math]::Round($clock.Elapsed.TotalSeconds, 6)
        $item.outcome = if ($code -eq 0) { 'success' } else { 'failure' }
        Save-Journal
    }
    if ($code -ne 0) { throw "Pair integration stage failed: $($item.name). Raw output excluded." }
}
$common = @('-NoProfile', '-NonInteractive', '-File')
$failed = $false
Save-Journal
try {
    Invoke-Gate 0 $ps ($common + @("$scripts\Test-Validation.ps1", '-Suite', 'Services',
        '-BuildRoot', $BuildRoot, '-QtPrefix', $qt, '-OutputRoot', "$Results\Services"))
    $buildArguments = $common + @("$scripts\Build-Prototype.ps1", '-BuildRoot', $BuildRoot,
        '-QtPrefix', $qt, '-LlvmBin', $llvm, '-Cli11Include', (Join-Path $ToolRoot $spec.cli11Directory),
        '-ToolsBin', $tools, '-Jobs', '2', '-PublicRelease', '-PluginTests')
    if ($Mode -eq 'candidate') { $buildArguments += @('-BackendRoot', $BackendRoot, '-CandidateBackendRevision', $BackendSha) }
    Invoke-Gate 1 $ps $buildArguments
    Invoke-Gate 2 $ps ($common + @("$scripts\New-CaelestiaRelease.ps1", '-BuildRoot', $BuildRoot, '-ValidateToolchainOnly'))
    Invoke-Gate 3 "$tools\ctest.exe" @('--test-dir', "$BuildRoot\caelestia", '--output-on-failure',
        '--timeout', '60', '--no-tests=error', '--output-junit', "$Results\plugins.raw.xml")
    Invoke-Gate 4 $ps ($common + @("$scripts\Test-Validation.ps1", '-Suite', 'Shell',
        '-BuildRoot', $BuildRoot, '-QtPrefix', $qt, '-OutputRoot', "$Results\Shell"))
    $smokeArguments = $common + @("$scripts\Test-Smoke.ps1", '-BuildRoot', $BuildRoot,
        '-QtPrefix', $qt, '-RunRoot', "$Results\smoke")
    if ($Mode -eq 'candidate') { $smokeArguments += @('-CandidateBackendRevision', $BackendSha) }
    Invoke-Gate 5 $ps $smokeArguments
} catch {
    $failed = $true
    Write-Output 'Production pair integration failed; inspect sanitized stage outcomes.'
} finally {
    & $Python -I -B "$PSScriptRoot\pair_result.py" integration-report --results $Results --junit $JUnit
    if ($LASTEXITCODE -ne 0) { $failed = $true }
}
if ($failed) { exit 1 }
