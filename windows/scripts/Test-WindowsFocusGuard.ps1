[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QtPrefix,
    [Parameter(Mandatory)][string]$BuildRoot,
    [string]$RunRoot
)
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$BuildRoot = [IO.Path]::GetFullPath($BuildRoot)
if (-not $RunRoot) {
    $RunRoot = Join-Path ([IO.Path]::GetTempPath()) ("caelestia-focusguard-" + [guid]::NewGuid())
}
$run = [IO.Path]::GetFullPath($RunRoot)
New-Item -ItemType Directory -Force -Path $run | Out-Null
$test = Join-Path $BuildRoot 'caelestia\lib\windowsfocusguard-tests.exe'
if (-not (Test-Path -LiteralPath $test -PathType Leaf)) {
    throw "Missing focus guard test: $test (run windows/scripts/Build-Prototype.ps1 -Tests first)."
}
$log = Join-Path $run 'windowsfocusguard-tests.txt'
# The executable only needs Qt; it never imports the staged shell or a profile.
# The offscreen QPA keeps the fake window out of the live desktop.
$previousPath = $env:PATH
$previousPlatform = $env:QT_QPA_PLATFORM
$env:PATH = "$QtPrefix\bin;$env:PATH"
$env:QT_QPA_PLATFORM = 'offscreen'
Push-Location -LiteralPath $run
try {
    & $test -o "$log,txt" | Out-Null
    $exitCode = $LASTEXITCODE
} finally {
    Pop-Location
    $env:PATH = $previousPath
    $env:QT_QPA_PLATFORM = $previousPlatform
}
$passed = $exitCode -eq 0 -and (Test-Path -LiteralPath $log -PathType Leaf) -and
    (Select-String -LiteralPath $log -Pattern 'Totals:.*\b0 failed\b' -Quiet)
$result = [ordered]@{
    passed = $passed
    exitCode = $exitCode
    test = $test
    log = $log
    sourceRevision = (& git -C $repoRoot rev-parse HEAD).Trim()
    sourceDirty = [bool](& git -C $repoRoot status --porcelain)
    qtVersion = (& "$QtPrefix\bin\qtpaths.exe" --qt-version).Trim()
}
$result | ConvertTo-Json
if (-not $passed) {
    if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log -Tail 40 }
    throw "Windows focus guard test failed: $run"
}
