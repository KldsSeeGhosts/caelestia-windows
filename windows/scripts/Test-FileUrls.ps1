#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QtPrefix,
    [string]$BuildRoot,
    # Parent for a new, exclusively owned child. Existing runs are never reused.
    [string]$OutputRoot
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
if (-not $BuildRoot) { $BuildRoot = Join-Path $repoRoot 'windows\.local\build' }
if (-not $OutputRoot) {
    $OutputRoot = if ($env:CAELESTIA_TEST_OUTPUT_ROOT) { $env:CAELESTIA_TEST_OUTPUT_ROOT }
        else { Join-Path ([IO.Path]::GetTempPath()) 'validation-erm630' }
}
$OutputRoot = [IO.Path]::GetFullPath($OutputRoot)
if ($OutputRoot -eq $repoRoot -or
    $OutputRoot.StartsWith($repoRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'File-URL test output must stay outside the source checkout.'
}
if ($OutputRoot.StartsWith('\\') -or $OutputRoot.StartsWith('//')) {
    throw 'File-URL test output must be on a local filesystem.'
}
$QtPrefix = (Resolve-Path -LiteralPath $QtPrefix).Path
$BuildRoot = (Resolve-Path -LiteralPath $BuildRoot).Path
$node = (Get-Command node.exe -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$runRoot = Join-Path $OutputRoot ('file-urls-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $runRoot | Out-Null

function ConvertTo-SafeReceiptText([string]$Text) {
    $mappings = @(
        @{ path = $runRoot; label = '$OUTPUT_ROOT' },
        @{ path = $repoRoot; label = '$REPO_ROOT' },
        @{ path = $BuildRoot; label = '$BUILD_ROOT' },
        @{ path = $QtPrefix; label = '$QT_PREFIX' },
        @{ path = (Split-Path -Parent $node); label = '$NODE_DIR' }
    )
    if ($env:CAELESTIA_TEST_RUNTIME_PREFIX) {
        $mappings += @{ path = [IO.Path]::GetFullPath($env:CAELESTIA_TEST_RUNTIME_PREFIX); label = '$RUNTIME_PREFIX' }
    }
    $mappings = $mappings | Sort-Object { $_.path.Length } -Descending
    foreach ($mapping in $mappings) {
        foreach ($spelling in @($mapping.path, $mapping.path.Replace('\', '/')) | Select-Object -Unique) {
            $Text = [regex]::Replace($Text, [regex]::Escape($spelling),
                $mapping.label.Replace('$', '$$'), [Text.RegularExpressions.RegexOptions]::IgnoreCase)
        }
    }
    return $Text
}

$summary = [ordered]@{
    schemaVersion = 1
    suite = 'FileUrls'
    passed = $false
    sourceRevision = (& git -C $repoRoot rev-parse HEAD).Trim()
    sourceDirty = [bool](& git -C $repoRoot status --porcelain)
    nodeCommand = @('$NODE_DIR/node.exe', '--test', '--test-reporter=tap', '$REPO_ROOT/windows/tests/FileUrls.test.js')
    nodeExitCode = $null
    nodeTests = $null
    nodePassed = $null
    nodeFailed = $null
    nodeCancelled = $null
    nodeSkipped = $null
    nodeTodo = $null
    qmlAssertions = 0
    qtVersion = $null
    runnerSha256 = $null
    nativeCommand = $null
    nativeArguments = $null
    nativeExitCode = $null
    nativeTimedOut = $null
    diagnostics = @()
    nativeVisibleWallpaperAcceptance = 'NOT RUN; STOP preserved'
}

$previousEnvironment = @{}
foreach ($name in @('CAELESTIA_TEST_OUTPUT_ROOT', 'TEMP', 'TMP')) {
    $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
$failure = $null
try {
    # Use an explicit code point so Windows PowerShell 5.1 does not interpret
    # a BOM-less UTF-8 source file using its legacy system code page.
    $unicode = [char]0x00FC
    $dataRoot = Join-Path $runRoot ("data\reserved # percent% space $unicode")
    $sourceDirectory = Join-Path $dataRoot ("source # 50% $unicode")
    $targetDirectory = Join-Path $dataRoot ("dashboard state # 50% $unicode")
    $syntheticProfile = Join-Path $runRoot 'synthetic-profile'
    $temporary = Join-Path $runRoot 'temporary'
    $sourcePath = Join-Path $sourceDirectory 'photo#draft 50%.png'
    $targetPath = Join-Path $targetDirectory 'profile-picture'
    New-Item -ItemType Directory -Path $sourceDirectory, $targetDirectory, $syntheticProfile, $temporary | Out-Null

    # Public synthetic 2x2 PNG, never captured clipboard or profile data.
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

    # Harmless native stderr must not become a PowerShell terminating error.
    $ErrorActionPreference = 'Continue'
    $nodeOutput = @(& $node --test --test-reporter=tap (Join-Path $repoRoot 'windows\tests\FileUrls.test.js') 2>&1 |
        ForEach-Object { "$_" })
    $summary.nodeExitCode = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    $nodeOutput | Set-Content -LiteralPath (Join-Path $runRoot 'node.log') -Encoding UTF8
    $countFields = [ordered]@{
        tests = 'nodeTests'; pass = 'nodePassed'; fail = 'nodeFailed'
        cancelled = 'nodeCancelled'; skipped = 'nodeSkipped'; todo = 'nodeTodo'
    }
    foreach ($name in $countFields.Keys) {
        $counts = [regex]::Matches(($nodeOutput -join "`n"), "(?m)^# $name ([0-9]+)\s*$")
        if ($counts.Count -ne 1) { throw "Missing or ambiguous Node TAP count: $name." }
        $summary[$countFields[$name]] = [int]$counts[0].Groups[1].Value
    }
    if ($summary.nodeExitCode -ne 0 -or $summary.nodeTests -ne 9 -or
        $summary.nodePassed -ne $summary.nodeTests -or $summary.nodeFailed -ne 0 -or
        $summary.nodeCancelled -ne 0 -or $summary.nodeSkipped -ne 0 -or $summary.nodeTodo -ne 0) {
        throw 'Node file-URL regressions failed, were skipped, or reported inconsistent counts.'
    }

    . "$PSScriptRoot\Caelestia-QmlFixture.ps1"
    $env:CAELESTIA_TEST_OUTPUT_ROOT = $runRoot
    $env:TEMP = $temporary
    $env:TMP = $temporary
    # Keep only this run's new staging/profile tree. No old TEMP cleanup is
    # attempted, and the complete fixture stays inside the owned output child.
    $result = Invoke-QmlFixture -QtPrefix $QtPrefix -BuildRoot $BuildRoot -Name file-urls `
        -ShellFixture -UseQuickshell -Keep `
        -FakeDirectories @('windows/tests/fakes/file-urls') `
        -Sources @('windows/tests/FileUrlBoundaryTest.qml') `
        -FixtureFile 'windows/tests/FileUrlBoundaryTest.qml' `
        -Marker CAELESTIA_FILE_URL_QT -MinimumAssertions 34 `
        -Environment @{
            CAELESTIA_FILE_URL_SOURCE_PATH = $sourcePath.Replace('\', '/')
            CAELESTIA_FILE_URL_TARGET_PATH = $targetPath.Replace('\', '/')
            USERPROFILE = $syntheticProfile
        }
    $summary.qmlAssertions = if ($result.fixture) { $result.fixture.assertions } else { 0 }
    $summary.qtVersion = $result.qtVersion
    $summary.runnerSha256 = $result.runnerSha256
    $summary.nativeCommand = ConvertTo-SafeReceiptText $result.command
    $summary.nativeArguments = ConvertTo-SafeReceiptText $result.arguments
    $summary.nativeExitCode = $result.exitCode
    $summary.nativeTimedOut = $result.timedOut
    $summary.diagnostics = @($result.diagnostics | ForEach-Object { ConvertTo-SafeReceiptText "$_" })
    if (-not $result.passed -or $summary.qmlAssertions -ne 34) { throw 'Qt file-URL regression fixture failed or assertion count changed.' }
    if ((& git -C $repoRoot rev-parse HEAD).Trim() -ne $summary.sourceRevision -or
        [bool](& git -C $repoRoot status --porcelain) -ne $summary.sourceDirty) {
        throw 'Source revision or dirty state changed during validation.'
    }
    $summary.passed = $true
} catch {
    $failure = ConvertTo-SafeReceiptText $_.Exception.Message
    $summary.diagnostics += $failure
} finally {
    foreach ($name in $previousEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name], 'Process')
    }
    $summary | ConvertTo-Json -Depth 5 |
        Set-Content -LiteralPath (Join-Path $runRoot 'summary.json') -Encoding UTF8
}
$summary | ConvertTo-Json -Depth 5
if ($failure) { throw $failure }
