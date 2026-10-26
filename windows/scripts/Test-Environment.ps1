[CmdletBinding()]
param(
    [string]$QtPrefix,
    [string]$QuickshellExecutable,
    [switch]$Json,
    [switch]$Strict
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$lock = Get-Content -LiteralPath (Join-Path $repoRoot 'windows\sources.lock.json') -Raw |
    ConvertFrom-Json
if ($lock.schemaVersion -ne 1) {
    throw 'Unsupported Windows source manifest schema.'
}

$blockers = New-Object 'System.Collections.Generic.List[string]'
$tools = New-Object 'System.Collections.Generic.List[object]'
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

$compiler = Get-Command cl.exe, clang-cl.exe -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1
$tools.Add([pscustomobject]@{
    name = 'cxxCompiler'
    path = $(if ($compiler) { $compiler.Source } else { $null })
})
if (-not $compiler) {
    $blockers.Add('No MSVC cl.exe or clang-cl.exe is available in this environment.')
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
$sourceMatches = $backendMatches -and $m3shapesMatches

$report = [pscustomobject][ordered]@{
    schemaVersion = 1
    repository = $repoRoot
    platform = [Environment]::OSVersion.VersionString
    source = [pscustomobject]@{
        expectedBackendRevision = $lock.quickshell.revision
        actualBackendRevision = $backendRevision
        expectedM3ShapesRevision = $lock.m3shapes.revision
        actualM3ShapesRevision = $m3shapesRevision
        matches = $sourceMatches
    }
    tools = @($tools.ToArray())
    nativeToolchainReady = $blockers.Count -eq 0
    blockers = @($blockers.ToArray())
    notes = @(
        'This report does not validate a Caelestia build, Qt module coverage, SDK compatibility, or runtime behavior.',
        'No software was installed and no desktop, configuration, authentication, or environment settings were changed.',
        'The portable plugin build and component probe do not validate the full bar/drawer or Windows service adaptation.'
    )
}
if ($Json) {
    $report | ConvertTo-Json -Depth 5
} else {
    $report | Format-List repository, platform, nativeToolchainReady
    $report.source | Format-List
    $report.tools | Format-Table -AutoSize
    foreach ($blocker in $report.blockers) { Write-Output "BLOCKER: $blocker" }
    foreach ($note in $report.notes) { Write-Output $note }
}
if ($Strict -and -not $report.nativeToolchainReady) { exit 1 }
