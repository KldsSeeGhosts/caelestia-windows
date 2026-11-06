[CmdletBinding()]
param(
    [string]$QtPrefix,
    [string]$Cli11Include,
    [string]$QuickshellExecutable,
    [switch]$Json,
    [switch]$Strict
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Caelestia-Toolchain.ps1')
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$lock = Get-Content -LiteralPath (Join-Path $repoRoot 'windows\sources.lock.json') -Raw |
    ConvertFrom-Json
if ($lock.schemaVersion -ne 1) {
    throw 'Unsupported Windows source manifest schema.'
}
# One production staging map, shared by the installer and public smoke.
# Every entry must name a production file: fixture folders are private,
# so a production reference to one is a build blocker.
$stagingManifestPath = Join-Path $repoRoot 'windows\shell\sources.json'
$stagingManifest = Get-Content -LiteralPath $stagingManifestPath -Raw | ConvertFrom-Json
$stagingEntries = @($stagingManifest.PSObject.Properties)
$stagingFixtureEntries = @($stagingEntries | Where-Object { $_.Name -match '^windows/tests/' })
$stagingDuplicateTargets = @($stagingEntries | Group-Object Value | Where-Object Count -gt 1)
$stagingMissingSources = @($stagingEntries | Where-Object { -not (Test-Path -LiteralPath (Join-Path $repoRoot $_.Name) -PathType Leaf) })

$blockers = New-Object 'System.Collections.Generic.List[string]'
$tools = New-Object 'System.Collections.Generic.List[object]'
if ($stagingFixtureEntries.Count -ne 0) {
    $blockers.Add("The production staging map references private fixtures: $($stagingFixtureEntries[0].Name)")
}
if ($stagingDuplicateTargets.Count -ne 0) {
    $blockers.Add("The production staging map stages '$($stagingDuplicateTargets[0].Group[0].Value)' from more than one source.")
}
if ($stagingMissingSources.Count -ne 0) {
    $blockers.Add("The production staging map names a missing source: $($stagingMissingSources[0].Name)")
}
$onWindows = [Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT
if (-not $onWindows) {
    $blockers.Add('Run this native Windows prerequisite check in Windows PowerShell.')
}

foreach ($name in @('git', 'cmake', 'ninja')) {
    $command = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    $tools.Add([pscustomobject]@{ name = $name; path = $(if ($command) { $command.Source } else { $null }) })
    if (-not $command) {
        $blockers.Add("$name is not available on PATH.")
    }
}

$compiler = Get-Command clang-cl.exe -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1
$tools.Add([pscustomobject]@{
    name = 'cxxCompiler'
    path = $(if ($compiler) { $compiler.Source } else { $null })
})
if (-not $compiler) {
    $blockers.Add('The supported clang-cl.exe is not available in this environment; run the documented toolchain setup.')
}

$qtTool = $null
if ($QtPrefix) {
    foreach ($name in @('qtpaths6.exe', 'qtpaths.exe')) {
        $candidate = Join-Path $QtPrefix "bin\$name"
        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            $qtTool = (Resolve-Path -LiteralPath $candidate).Path
            break
        }
    }
} else {
    $command = Get-Command qtpaths6.exe, qtpaths.exe -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($command) { $qtTool = $command.Source }
}
$tools.Add([pscustomobject]@{ name = 'qtpaths'; path = $qtTool })
if (-not $qtTool) {
    $blockers.Add('Qt development tools were not found; supply -QtPrefix or configure the Qt build environment.')
}

$runtime = $null
if ($QuickshellExecutable) {
    if (Test-Path -LiteralPath $QuickshellExecutable -PathType Leaf) {
        $runtime = (Resolve-Path -LiteralPath $QuickshellExecutable).Path
    } else {
        $blockers.Add('The explicitly supplied Quickshell executable does not exist.')
    }
} else {
    $command = Get-Command qsw.exe, qs.exe -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($command) { $runtime = $command.Source }
}
$tools.Add([pscustomobject]@{ name = 'quickshellRuntime'; path = $runtime })

$backendPath = Join-Path $repoRoot $lock.quickshell.path
$backendRevision = $null
$git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1
if ($git -and (Test-Path -LiteralPath (Join-Path $backendPath '.git'))) {
    $backendRevision = & $git.Source -C $backendPath rev-parse HEAD
    if ($LASTEXITCODE -ne 0) { throw 'Could not read the initialized backend revision.' }
    $backendRevision = $backendRevision.Trim()
}
$backendMatches = $backendRevision -eq $lock.quickshell.revision
if (-not $backendMatches) {
    $blockers.Add('The backend is absent or does not match sources.lock.json; initialize the pinned submodule.')
}

$m3shapesPath = Join-Path $repoRoot $lock.m3shapes.path
$m3shapesRevision = $null
if ($git -and (Test-Path -LiteralPath (Join-Path $m3shapesPath '.git'))) {
    $m3shapesRevision = & $git.Source -C $m3shapesPath rev-parse HEAD
    if ($LASTEXITCODE -ne 0) { throw 'Could not read the initialized M3Shapes revision.' }
    $m3shapesRevision = $m3shapesRevision.Trim()
}
$m3shapesMatches = $m3shapesRevision -eq $lock.m3shapes.revision
if (-not $m3shapesMatches) {
    $blockers.Add('M3Shapes is absent or does not match sources.lock.json; initialize the pinned submodule.')
}

$captureSource = $null
try {
    . (Join-Path $repoRoot 'windows\capture\Source.ps1')
    $captureSource = Get-CaelestiaCaptureSource $repoRoot
} catch {
    $blockers.Add("First-party capture source is invalid: $($_.Exception.Message)")
}
$sourceMatches = $backendMatches -and $m3shapesMatches -and $null -ne $captureSource
$toolchain = $null
try {
    if (-not $QtPrefix) { throw 'Supply -QtPrefix and -Cli11Include in the selected VC/SDK environment, or use Build-Prototype.ps1.' }
    $toolchain = Get-CaelestiaActualToolchain -QtPrefix $QtPrefix -Cli11Include $Cli11Include
} catch {
    $blockers.Add($_.Exception.Message)
}

$report = [pscustomobject][ordered]@{
    schemaVersion = 1
    repository = $repoRoot
    platform = [Environment]::OSVersion.VersionString
    source = [pscustomobject]@{
        expectedBackendRevision = $lock.quickshell.revision
        actualBackendRevision = $backendRevision
        expectedM3ShapesRevision = $lock.m3shapes.revision
        actualM3ShapesRevision = $m3shapesRevision
        captureRepresentation = 'in-tree'
        captureSourcePath = $(if ($captureSource) { $captureSource.relativePath } else { $null })
        captureSourceRevision = $(if ($captureSource) { $captureSource.sourceRevision } else { $null })
        captureOriginRevision = $(if ($captureSource) { $captureSource.originRevision } else { $null })
        captureCargoLockSha256 = $(if ($captureSource) { $captureSource.cargoLockSha256 } else { $null })
        matches = $sourceMatches
    }
    tools = @($tools.ToArray())
    toolchain = $toolchain
    stagingManifest = [pscustomobject][ordered]@{
        path = 'windows/shell/sources.json'
        entries = $stagingEntries.Count
        fixtureReferences = @($stagingFixtureEntries | ForEach-Object { $_.Name })
    }
    nativeToolchainReady = $blockers.Count -eq 0
    blockers = @($blockers.ToArray())
    notes = @(
        'This report asserts the supported toolchain versions, not a Caelestia build, Qt module coverage, or runtime behavior.',
        'No software was installed and no desktop, configuration, authentication, or environment settings were changed.',
        'The portable plugin build does not validate the full bar/drawer or Windows service adaptation.'
    )
}
if ($Json) {
    $report | ConvertTo-Json -Depth 5
} else {
    $report | Format-List repository, platform, nativeToolchainReady
    $report.source | Format-List
    $report.stagingManifest | Format-List
    $report.tools | Format-Table -AutoSize
    foreach ($blocker in $report.blockers) { Write-Output "BLOCKER: $blocker" }
    foreach ($note in $report.notes) { Write-Output $note }
}
if ($Strict -and -not $report.nativeToolchainReady) { exit 1 }
