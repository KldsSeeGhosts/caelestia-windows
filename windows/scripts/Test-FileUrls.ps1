[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QtPrefix,
    [string]$BuildRoot = 'C:\b-public-final',
    [string]$OutputRoot = 'D:\Caelestia\validation-erm630'
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
$allowedOutputRoot = [IO.Path]::GetFullPath('D:\Caelestia\validation-erm630').TrimEnd('\')
if ($OutputRoot -ne $allowedOutputRoot -and
    -not $OutputRoot.StartsWith($allowedOutputRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'File-URL test outputs must stay under D:\Caelestia\validation-erm630.'
}
New-Item -ItemType Directory -Force -Path $OutputRoot | Out-Null

$runId = [guid]::NewGuid().ToString('N')
$dataRoot = Join-Path $OutputRoot ("data\reserved # percent% space ü\$runId")
$sourceDirectory = Join-Path $dataRoot 'source # 50% ü'
$targetDirectory = Join-Path $dataRoot 'dashboard state # 50% ü'
$syntheticProfile = Join-Path $OutputRoot 'synthetic-profile'
$sourcePath = Join-Path $sourceDirectory 'photo#draft 50%.png'
$targetPath = Join-Path $targetDirectory 'profile-picture'
New-Item -ItemType Directory -Force -Path $sourceDirectory, $targetDirectory, $syntheticProfile | Out-Null

# Public synthetic 2x2 PNG. It contains no captured clipboard or profile data.
Add-Type -AssemblyName System.Drawing
$bitmap = [Drawing.Bitmap]::new(2, 2)
try {
    $bitmap.SetPixel(0, 0, [Drawing.Color]::Magenta)
    $bitmap.SetPixel(1, 0, [Drawing.Color]::Cyan)
    $bitmap.SetPixel(0, 1, [Drawing.Color]::Yellow)
    $bitmap.SetPixel(1, 1, [Drawing.Color]::Black)
    $bitmap.Save($sourcePath, [Drawing.Imaging.ImageFormat]::Png)
} finally {
    $bitmap.Dispose()
}

$nodeLog = Join-Path $OutputRoot "node-$runId.log"
$nodeOutput = & node.exe --test (Join-Path $repoRoot 'windows\tests\FileUrls.test.js') 2>&1
$nodeExitCode = $LASTEXITCODE
$nodeOutput | Set-Content -LiteralPath $nodeLog -Encoding UTF8
if ($nodeExitCode -ne 0) {
    throw "Node file-URL tests failed with exit code $nodeExitCode."
}

. "$PSScriptRoot\Caelestia-QmlFixture.ps1"
$previousFixtureOutputRoot = $env:CAELESTIA_TEST_OUTPUT_ROOT
$env:CAELESTIA_TEST_OUTPUT_ROOT = $OutputRoot
try {
    $result = Invoke-QmlFixture -QtPrefix $QtPrefix -BuildRoot $BuildRoot -Name file-urls `
        -ShellFixture -UseQuickshell `
        -FakeDirectories @('windows/tests/fakes/file-urls') `
        -Sources @('windows/tests/FileUrlBoundaryTest.qml') `
        -FixtureFile 'windows/tests/FileUrlBoundaryTest.qml' `
        -Marker CAELESTIA_FILE_URL_QT -MinimumAssertions 15 `
        -Environment @{
            CAELESTIA_FILE_URL_SOURCE_PATH = $sourcePath.Replace('\', '/')
            CAELESTIA_FILE_URL_TARGET_PATH = $targetPath.Replace('\', '/')
            USERPROFILE = $syntheticProfile
        }
} finally {
    if ($null -eq $previousFixtureOutputRoot) {
        Remove-Item Env:CAELESTIA_TEST_OUTPUT_ROOT -ErrorAction SilentlyContinue
    } else {
        $env:CAELESTIA_TEST_OUTPUT_ROOT = $previousFixtureOutputRoot
    }
}

$summary = [ordered]@{
    passed = $result.passed
    sourceRevision = $result.sourceRevision
    nodeExitCode = $nodeExitCode
    nodeTests = 7
    nodePassed = 7
    qmlAssertions = if ($result.fixture) { $result.fixture.assertions } else { 0 }
    qtVersion = $result.qtVersion
    runnerSha256 = $result.runnerSha256
    nativeExitCode = $result.exitCode
    nativeTimedOut = $result.timedOut
    diagnostics = @($result.diagnostics)
}
$summary | ConvertTo-Json -Depth 5

if (-not $result.passed) {
    throw 'Qt file-URL regression fixture failed. Inspect the owned output logs.'
}
