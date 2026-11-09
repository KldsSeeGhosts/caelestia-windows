#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ShellRoot,
    [Parameter(Mandatory)][string]$BuildRoot,
    [Parameter(Mandatory)][string]$ToolRoot,
    [Parameter(Mandatory)][string]$OutputDirectory,
    # Optional same-run public data, prepared without release eligibility.
    # Context and source identity are checked; bytes must match the same-run index.
    [string]$PreparedSources,
    [string]$Python = 'python',
    # Only disposable CI source/build diagnostics may be echoed. Logs never
    # enter the public candidate directory or its release assets.
    [switch]$EchoDiagnostics
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\scripts\Caelestia-Toolchain.ps1')
Initialize-CaelestiaToolchainModules
. "$PSScriptRoot\..\scripts\Caelestia-InstallCommon.ps1"
. "$PSScriptRoot\..\scripts\Caelestia-Update.ps1"
foreach ($name in @('ShellRoot', 'BuildRoot', 'ToolRoot', 'OutputDirectory')) {
    Set-Variable -Name $name -Value (Resolve-CaelestiaDirectory (Get-Variable -Name $name -ValueOnly))
}
if ($PreparedSources) { $PreparedSources = Resolve-CaelestiaDirectory $PreparedSources }
if ($ShellRoot -ne (Resolve-Path "$PSScriptRoot\..\..").Path) { throw 'Use the candidate checkout entrypoint.' }
foreach ($root in @($ShellRoot, $BuildRoot, $ToolRoot, $PreparedSources) | Where-Object { $_ }) {
    if ($OutputDirectory -eq $root -or $OutputDirectory.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase) -or
        $root.StartsWith($OutputDirectory + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Candidate output overlaps an input.' }
}
if (Test-Path -LiteralPath $OutputDirectory) { throw 'Candidate assembly requires fresh output.' }
$identity = & $Python -I -B "$PSScriptRoot\nexus_assembly.py" identity --shell $ShellRoot --build $BuildRoot
if ($LASTEXITCODE -ne 0 -or -not (Test-CaelestiaDevVersion "$identity")) { throw 'Exact-main production identity refused before assembly.' }
# Assembly does not claim test eligibility. Sealing verifies final evidence
# and byte equality before it creates the unchanged candidate.json.
[IO.Directory]::CreateDirectory($OutputDirectory) | Out-Null
$privateLogs = Join-Path $OutputDirectory 'private'
[IO.Directory]::CreateDirectory($privateLogs) | Out-Null
$ps = Get-WindowsPowerShellPath
$candidateRunner = Join-Path $PSScriptRoot 'nexus_process.py'
function Invoke-CandidateCommand([string]$Name, [string]$Executable, [string[]]$Arguments, [int]$TimeoutSeconds) {
    $log = Join-Path $privateLogs "$Name.log"
    $exitCode = 1
    $runnerArguments = @('-I', '-B', $candidateRunner, '--name', $Name, '--log', $log, '--timeout', "$TimeoutSeconds")
    if ($EchoDiagnostics) { $runnerArguments += '--echo' }
    $runnerArguments += @('--', $Executable) + $Arguments
    $preference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $global:LASTEXITCODE = 1
        & $Python @runnerArguments 2>&1 | ForEach-Object { "$_" }
        $exitCode = $LASTEXITCODE
    } finally { $ErrorActionPreference = $preference }
    if ($exitCode -ne 0) {
        throw "Candidate gate failed: $Name (exit=$exitCode). Private diagnostic log: $log. Not a release artifact."
    }
}
function Invoke-CandidateGate([string]$Name, [string]$Script, [string[]]$Arguments, [int]$TimeoutSeconds = 900) {
    Invoke-CandidateCommand $Name $ps (@('-NoProfile', '-NonInteractive', '-File', $Script) + $Arguments) $TimeoutSeconds
}
# Self-contained public Git bundles require full histories. Fetches remain
# anonymous/read-only source acquisition on the isolated hosted runner.
function Complete-CandidateHistory([string]$Root, [string]$Name) {
    $root = $Root
    $shallow = & git -C $root rev-parse --is-shallow-repository
    if ($LASTEXITCODE -ne 0) { throw 'Cannot inspect candidate source history.' }
    if ($shallow -eq 'true') {
        $revision = & git -C $root rev-parse HEAD
        if ($LASTEXITCODE -ne 0 -or $revision -cnotmatch '^[a-f0-9]{40}$') { throw 'Cannot identify source history.' }
        # Fetch only this exact public commit's ancestry, not unrelated
        # branches/tags or recursive dependency histories. Bundles still
        # require complete history and standalone verification.
        Invoke-CandidateCommand ('history-' + $Name) 'git' @(
            '-c', 'credential.helper=', '-c', 'core.hooksPath=NUL', '-C', $root,
            'fetch', '--unshallow', '--no-tags', '--recurse-submodules=no', 'origin', $revision) 300
    }
}
if (-not $PreparedSources) {
    foreach ($project in @(@{ name = 'shell'; root = $ShellRoot },
        @{ name = 'backend'; root = "$ShellRoot\windows\deps\quickshell" },
        @{ name = 'm3shapes'; root = "$ShellRoot\windows\deps\m3shapes" })) {
        Complete-CandidateHistory $project.root $project.name
    }
}
$scripts = Join-Path $ShellRoot 'windows\scripts'
$assets = Join-Path $OutputDirectory 'sources'
$spec = Get-Content "$ShellRoot\windows\toolchain.json" -Raw | ConvertFrom-Json
$qt = Join-Path $ToolRoot $spec.qtDirectory
if ($PreparedSources) {
    Invoke-CandidateCommand 'sources' $Python @('-I', '-B', "$PSScriptRoot\nexus_sources.py", 'materialize',
        '--shell', $ShellRoot, '--transfer', $PreparedSources, '--output', $assets) 1800
} else {
    Invoke-CandidateGate 'sources' "$scripts\Prepare-CaelestiaSourceAssets.ps1" @(
        '-SourceRoot', $ShellRoot, '-SourceRevision', $env:GITHUB_SHA, '-OutputDirectory', $assets,
        '-CacheDirectory', (Join-Path $OutputDirectory 'source-cache')) 1800
}
$assembly = Join-Path $OutputDirectory 'assembly'
Invoke-CandidateGate 'assembly' "$scripts\New-CaelestiaRelease.ps1" @(
    '-BuildRoot', $BuildRoot, '-ReleaseId', "$identity", '-OutputDirectory', $assembly,
    '-SupplementalNoticesRoot', (Join-Path $assets 'notices'), '-QtPrefix', $qt)
$rootName = "caelestia-windows-$identity-windows-x64"
$bundle = Join-Path $assembly $rootName
$manifestHash = (Get-FileHash "$bundle\release.json").Hash.ToLowerInvariant()
$inventoryHash = (Get-FileHash "$assets\component-inventory.json").Hash.ToLowerInvariant()
$coverage = Join-Path $OutputDirectory 'coverage'
$zip = Join-Path $assembly ($rootName + '.zip')
Add-Type -AssemblyName System.IO.Compression.FileSystem
$archive = [IO.Compression.ZipFile]::OpenRead($zip)
try {
    $entries = $archive.Entries.Count
    $unpacked = [long](($archive.Entries | Measure-Object Length -Sum).Sum)
} finally { $archive.Dispose() }
$extracted = Expand-CaelestiaUpdate $zip (Join-Path $OutputDirectory 'verify-extracted') $rootName $entries $unpacked
$gateRows = @(
    @{ name = 'coverage'; script = "$scripts\Prepare-CaelestiaSourceAssets.ps1"; timeout = 300; arguments = @(
        '-AssetsRoot', $assets, '-BundleRoot', $bundle, '-ExpectedInventorySha256', $inventoryHash,
        '-ExpectedManifestSha256', $manifestHash, '-CoverageOutputDirectory', $coverage) },
    @{ name = 'license-lifecycle'; script = "$scripts\Test-InstallLicenses.ps1"; timeout = 600; arguments = @(
        '-BuildRoot', $BuildRoot, '-QtPrefix', $qt, '-NoIntegration') },
    @{ name = 'verify-original-zip'; script = "$scripts\Install-CaelestiaRelease.ps1"; timeout = 300; arguments = @(
        '-BundleRoot', $extracted, '-VerifyOnly', '-ExpectedManifestSha256', $manifestHash) }
)
$plan = @($gateRows | ForEach-Object { @{
    name = $_.name; timeout = $_.timeout; echo = [bool]$EchoDiagnostics
    log = (Join-Path $privateLogs ($_.name + '.log'))
    command = @($ps, '-NoProfile', '-NonInteractive', '-File', $_.script) + $_.arguments
} })
$planPath = Join-Path $privateLogs 'parallel-gates.json'
$plan | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $planPath -Encoding UTF8
& $Python -I -B "$PSScriptRoot\nexus_assembly.py" gates --plan $planPath
if ($LASTEXITCODE -ne 0) { throw 'Independent assembly gates failed.' }
# VerifyOnly is data-only on Server 2022. No Windows 11 install/graphics or
# hardware claim is made. No production OS guard bypass is present.
$out = Join-Path $OutputDirectory 'out'
[IO.Directory]::CreateDirectory($out) | Out-Null
Copy-Item -LiteralPath $zip -Destination $out
Copy-Item -LiteralPath "$assets\project-source.zip", "$assets\supplier-source.zip" -Destination $out
Copy-Item -LiteralPath "$coverage\component-inventory.json" -Destination $out
Copy-Item -LiteralPath "$assets\component-inventory.json" -Destination "$out\source-assets-inventory.json"
[IO.File]::WriteAllText("$out\manifest.sha256", ($manifestHash + "  release.json`n"), [Text.Encoding]::ASCII)
$manifest = Read-CaelestiaStrictJsonFile "$bundle\release.json" 16777216 -AllowUtf8Bom
$release = [ordered]@{
    displayVersion = "$identity"; buildVersion = "$identity"; releaseId = "$identity"; tag = "v$identity"
    sourceRevision = $env:GITHUB_SHA; backendRevision = $manifest.backendRevision
    bundle = [ordered]@{
        name = "$rootName.zip"; root = $rootName
        url = "https://github.com/KldsSeeGhosts/caelestia-windows/releases/download/v$identity/$rootName.zip"
        size = (Get-Item -LiteralPath $zip).Length; sha256 = (Get-FileHash $zip).Hash.ToLowerInvariant()
        entries = $entries; unpackedSize = $unpacked
    }
    manifestSha256 = $manifestHash; profileSchema = 1; minimumUpdaterSchema = 1
    notesUrl = "https://github.com/KldsSeeGhosts/caelestia-windows/releases/tag/v$identity"
    provenance = @{
        runId = $env:GITHUB_RUN_ID; runAttempt = $env:GITHUB_RUN_ATTEMPT
    }
}
$files = @(Get-ChildItem -LiteralPath $out -File | Sort-Object Name | ForEach-Object {
    @{ name = $_.Name; size = $_.Length; sha256 = (Get-FileHash -LiteralPath $_.FullName).Hash.ToLowerInvariant() }
})
$native = Get-Content -LiteralPath "$BuildRoot\logs\build.json" -Raw | ConvertFrom-Json
Write-CaelestiaJsonAtomic "$out\unsealed.json" @{
    schema = 'caelestia-nexus-unsealed'; version = 1; repository = 'KldsSeeGhosts/caelestia-windows'
    event = 'push'; ref = 'refs/heads/main'; workflow = '.github/workflows/windows-build.yml'
    sourceRevision = $env:GITHUB_SHA; runId = $env:GITHUB_RUN_ID; runAttempt = $env:GITHUB_RUN_ATTEMPT
    runNumber = $env:GITHUB_RUN_NUMBER; release = $release; assets = $files
    nativeInputs = $native.nativeInputs; nativeToolchain = $native.toolchain; nativeSupervisor = $native.supervisor
    gates = @('sources', 'assembly', 'coverage', 'license-lifecycle', 'verify-original-zip', 'independent-payload')
    qualification = 'component-offscreen-and-data-only-not-windows11-acceptance'
}
Invoke-CandidateGate 'independent-payload' "$PSScriptRoot\Test-NexusCandidatePayload.ps1" @(
    '-CandidateDirectory', $out, '-OutputDirectory', (Join-Path $OutputDirectory 'independent-payload'),
    '-SourceDataRoot', $ShellRoot, '-AssetsRoot', $assets, '-Unsealed', '-NativeBuildRoot', $BuildRoot) 600
Write-Output "NEXUS_ASSEMBLY_PASS $identity; unsealed until exact-tested evidence passes; no native recompilation."
