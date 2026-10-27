[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QtPrefix,
    [Parameter(Mandatory)][string]$BuildRoot,
    [string]$RunRoot
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$BuildRoot = [IO.Path]::GetFullPath($BuildRoot)
if (-not $RunRoot) { $RunRoot = Join-Path $env:TEMP 'caelestia-focus-follows-mouse-tests' }
$run = Join-Path ([IO.Path]::GetFullPath($RunRoot)) (Get-Date -Format 'yyyyMMdd-HHmmss-fff')
New-Item -ItemType Directory -Force -Path $run | Out-Null

$exe = Join-Path $BuildRoot 'caelestia\lib\focus-follows-mouse-tests.exe'
if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) {
    throw "Missing focus-follows-mouse test: $exe (run windows/scripts/Build-Prototype.ps1 first)."
}

# The test uses a fake system boundary; it never reads or writes the real
# Windows X-Mouse setting. Run it from a disposable directory anyway.
$previousPath = $env:PATH
$env:PATH = "$QtPrefix\bin;$env:PATH"
Push-Location -LiteralPath $run
try {
    & $exe -o "$run\tests.txt,txt" | Out-Null
    $exit = $LASTEXITCODE
} finally {
    Pop-Location
    $env:PATH = $previousPath
}

$log = Join-Path $run 'tests.txt'
$passed = $exit -eq 0 -and (Test-Path -LiteralPath $log -PathType Leaf) -and
    (Select-String -LiteralPath $log -Pattern 'Totals:.*\b0 failed\b' -Quiet)
$result = [ordered]@{
    passed = $passed
    exitCode = $exit
    executable = $exe
    executableSha256 = (Get-FileHash -LiteralPath $exe).Hash
    log = $log
    sourceRevision = (& git -C $repoRoot rev-parse HEAD).Trim()
    sourceDirty = [bool](& git -C $repoRoot status --porcelain)
    qtVersion = (& "$QtPrefix\bin\qtpaths.exe" --qt-version).Trim()
    command = $exe
    run = $run
}
$result | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $run 'result.json') -Encoding UTF8
$result | ConvertTo-Json
if (-not $passed) {
    throw "Focus-follows-mouse tests failed: $run"
}
