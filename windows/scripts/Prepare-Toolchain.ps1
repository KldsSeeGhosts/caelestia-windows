#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ToolRoot,
    [string]$Python = 'python',
    # Explicit provisioning only. Builds/checks never install or update Rust.
    [switch]$InstallRust,
    # Exact-key, trusted-main cache only. Verify all files with the uncached
    # setup-python interpreter before executing anything in the restored venv.
    [switch]$ReusePreparedPython
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Caelestia-Toolchain.ps1')
Initialize-CaelestiaToolchainModules
# Enter-CaelestiaToolchain later prepends tools\Scripts to PATH. Keep using the
# original interpreter for verification and recording, not the venv's python.
$Python = (Get-Command $Python -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$spec = Get-CaelestiaToolchain
$ToolRoot = [IO.Path]::GetFullPath($ToolRoot)
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')).TrimEnd('\')
if ($ToolRoot -eq $repoRoot -or $ToolRoot.StartsWith($repoRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'ToolRoot must be outside the source checkout.'
}
$downloads = Join-Path $ToolRoot 'downloads'
New-Item -ItemType Directory -Force -Path $ToolRoot, $downloads | Out-Null
$timingRoot = Join-Path $ToolRoot 'logs'
New-Item -ItemType Directory -Force -Path $timingRoot | Out-Null
$timings = New-Object 'System.Collections.Generic.List[object]'
$prepareClock = [Diagnostics.Stopwatch]::StartNew()
function Save-ToolchainTiming([string]$Phase, $Clock, $ExitCode, [string]$Outcome = '') {
    if (-not $Outcome) { $Outcome = if ($ExitCode -eq 0) { 'success' } else { 'failure' } }
    $timings.Add([ordered]@{
        phase = $Phase; durationSeconds = [Math]::Round($Clock.Elapsed.TotalSeconds, 6)
        exitCode = $ExitCode; outcome = $Outcome
    })
    # Labels and numbers only. Never retain commands, paths or exception text.
    [ordered]@{ schemaVersion = 1; phases = @($timings.ToArray()) } |
        ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $timingRoot 'prepare-timing.json') -Encoding UTF8
}

function Get-VerifiedToolchainArchive($Download) {
    $path = Join-Path $downloads $Download.file
    $timer = [Diagnostics.Stopwatch]::StartNew()
    Write-Host "Checking pinned archive: $($Download.file)"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Write-Host "Downloading pinned archive: $($Download.file) (600s per attempt, at most 2 retries)"
        & curl.exe -L --fail --silent --show-error --connect-timeout 30 --max-time 600 `
            --retry 2 --retry-delay 2 $Download.url -o $path
        if ($LASTEXITCODE -ne 0) { throw "Download failed: $($Download.file). Check public network access; do not add credentials." }
    }
    Assert-CaelestiaDownload $path $Download.sha256
    Write-Host ("Verified pinned archive: {0} ({1:N2}s)" -f $Download.file, $timer.Elapsed.TotalSeconds)
    return $path
}

Push-Location -LiteralPath $ToolRoot
try {
    $pythonVersion = @(& $Python -c "import sys,struct; print(str(sys.version_info.major)+'.'+str(sys.version_info.minor)+'-'+str(struct.calcsize('P')*8))")
    if ($LASTEXITCODE -ne 0 -or ($pythonVersion -join '') -ne "$($spec.pythonVersion)-64") {
        throw "Tool provisioning requires Python $($spec.pythonVersion) x64. Supply -Python <python.exe>."
    }
    $env:PYTHONDONTWRITEBYTECODE = '1'
    $environment = Join-Path $ToolRoot 'tools'
    $preparedVerifier = Join-Path $PSScriptRoot '..\toolchain\prepared_python.py'
    $prepared = $false
    if ($ReusePreparedPython) {
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $state = & $Python -I -B $preparedVerifier verify --environment $environment
        Save-ToolchainTiming 'verify-python-environment' $clock $LASTEXITCODE
        if ($LASTEXITCODE -ne 0 -or $state -notin @('hit', 'miss')) { throw 'Prepared Python verification failed.' }
        $prepared = $state -eq 'hit'
    }
    $venvPython = Join-Path $ToolRoot 'tools\Scripts\python.exe'
    # Keep archive verification even when the prepared environment is restored.
    $aqtArchive = Get-VerifiedToolchainArchive $spec.downloads.aqt
    if (-not $prepared) {
        $clock = [Diagnostics.Stopwatch]::StartNew()
        & $Python -m venv $environment
        Save-ToolchainTiming 'venv' $clock $LASTEXITCODE
        if ($LASTEXITCODE -ne 0) { throw 'Python tool environment creation failed.' }
        foreach ($lock in @('python-bootstrap.lock.txt', 'python-tools.lock.txt')) {
            $clock = [Diagnostics.Stopwatch]::StartNew()
            & $venvPython -m pip install --disable-pip-version-check --only-binary=:all: --require-hashes `
                -r (Join-Path $PSScriptRoot "..\toolchain\$lock")
            Save-ToolchainTiming "pip-$lock" $clock $LASTEXITCODE
            if ($LASTEXITCODE -ne 0) { throw "Hash-locked Python provisioning failed ($lock). Use Python 3.12 x64 and the committed public inputs." }
        }
        $clock = [Diagnostics.Stopwatch]::StartNew()
        & $venvPython -m pip install --disable-pip-version-check --no-deps --no-build-isolation $aqtArchive
        Save-ToolchainTiming 'pip-aqt' $clock $LASTEXITCODE
        if ($LASTEXITCODE -ne 0) { throw 'Verified aqt installation failed.' }
    } else {
        Write-Host 'Verified every prepared Python environment file and pinned input.'
        Save-ToolchainTiming 'venv' ([Diagnostics.Stopwatch]::new()) $null 'skipped'
        foreach ($lock in @('python-bootstrap.lock.txt', 'python-tools.lock.txt')) {
            Save-ToolchainTiming "pip-$lock" ([Diagnostics.Stopwatch]::new()) $null 'skipped'
        }
        Save-ToolchainTiming 'pip-aqt' ([Diagnostics.Stopwatch]::new()) $null 'skipped'
    }

    $qtPrefix = Join-Path $ToolRoot $spec.qtDirectory
    $qtDownloads = Join-Path $downloads 'qt'
    New-Item -ItemType Directory -Force -Path $qtDownloads | Out-Null
    if (-not (Test-Path -LiteralPath "$qtPrefix\bin\qtpaths.exe" -PathType Leaf)) {
        # aqt verifies upstream SHA-256 before extraction. Retain the bytes
        # and check the committed hashes as well, before any compilation.
        $clock = [Diagnostics.Stopwatch]::StartNew()
        & $venvPython -m aqt install-qt windows desktop $spec.qtVersion $spec.qtArchitecture `
            -O (Join-Path $ToolRoot 'Qt') --modules @($spec.qtModules) --archives @($spec.qtArchives) `
            --keep --archive-dest $qtDownloads
        Save-ToolchainTiming 'aqt-install-qt' $clock $LASTEXITCODE
        if ($LASTEXITCODE -ne 0) { throw 'Qt provisioning failed; do not disable aqt checksum verification.' }
    } else {
        Save-ToolchainTiming 'aqt-install-qt' ([Diagnostics.Stopwatch]::new()) $null 'skipped'
    }
    foreach ($archive in $spec.qtDownloads) {
        $file = "$($archive.module)-Windows-Windows_11_24H2-MSVC2022-Windows-Windows_11_24H2-X86_64.7z"
        # Existing installations may have discarded their archives. Fetch
        # and verify them too, instead of treating a version string as a hash.
        $null = Get-VerifiedToolchainArchive ([pscustomobject]@{
            file = "qt\$file"
            url = "$($spec.qtRepository)/$($archive.component)/$($spec.qtPackageVersion)$file"
            sha256 = $archive.sha256
        })
    }
    foreach ($file in @('bin\qtpaths.exe', 'bin\windeployqt.exe', 'bin\Qt6Quick.dll', 'bin\Qt6Svg.dll',
        'bin\Qt6ShaderTools.dll', 'plugins\imageformats\qjpeg.dll')) {
        if (-not (Test-Path -LiteralPath (Join-Path $qtPrefix $file) -PathType Leaf)) { throw "Incomplete Qt prerequisite: $file. Reprovision a fresh ToolRoot." }
    }
    $llvm = Get-VerifiedToolchainArchive $spec.downloads.llvm
    $llvmResources = "$($spec.llvmDirectory)/lib/clang/$($spec.clangVersion.Split('.')[0])/include/stddef.h"
    $llvmMarkerPath = Join-Path $ToolRoot "$($spec.llvmDirectory)/.caelestia-extraction.json"
    $llvmMarker = $null
    if (Test-Path -LiteralPath $llvmMarkerPath -PathType Leaf) {
        try { $llvmMarker = Get-Content -LiteralPath $llvmMarkerPath -Raw | ConvertFrom-Json } catch { $llvmMarker = $null }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $ToolRoot "$($spec.llvmDirectory)/bin/clang-cl.exe")) -or
        -not (Test-Path -LiteralPath (Join-Path $ToolRoot $llvmResources)) -or
        $null -eq $llvmMarker -or $llvmMarker.schemaVersion -ne 1 -or
        $llvmMarker.archiveSha256 -cne $spec.downloads.llvm.sha256 -or $llvmMarker.directory -cne $spec.llvmDirectory) {
        # The project consumes the compiler/tools and its built-in headers and
        # runtimes, not the LLVM development libraries or API headers. Avoid
        # materializing that unused SDK from the same hash-verified archive.
        Write-Host 'Extracting compiler binaries and resource headers from verified LLVM archive.'
        $llvmExtractor = Join-Path $PSScriptRoot '..\toolchain\extract_llvm.py'
        & $venvPython -I -B $llvmExtractor --archive $llvm --destination $ToolRoot `
            --directory $spec.llvmDirectory --sha256 $spec.downloads.llvm.sha256 `
            --clang-major $spec.clangVersion.Split('.')[0]
        if ($LASTEXITCODE -ne 0) { throw 'Verified LLVM extraction failed.' }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $ToolRoot $llvmResources))) {
        throw 'Incomplete LLVM compiler resource headers. Reprovision a fresh ToolRoot.'
    }
    $cli = Get-VerifiedToolchainArchive $spec.downloads.cli11
    if (-not (Test-Path -LiteralPath (Join-Path $ToolRoot "$($spec.cli11Directory)\CLI\CLI.hpp"))) {
        Write-Host 'Extracting verified CLI11 archive.'
        Expand-Archive -LiteralPath $cli -DestinationPath (Join-Path $ToolRoot 'deps') -Force
    }
    if ($InstallRust) {
        $null = Get-VerifiedToolchainArchive $spec.rustManifest
        Write-Host 'Installing the pinned Rust toolchain.'
        # rustup verifies component hashes from this exact public manifest.
        $clock = [Diagnostics.Stopwatch]::StartNew()
        & rustup.exe toolchain install "$($spec.rustVersion)-$($spec.rustTarget)" --profile minimal --target $spec.rustTarget
        Save-ToolchainTiming 'rust-install' $clock $LASTEXITCODE
        if ($LASTEXITCODE -ne 0) { throw 'Pinned Rust installation failed. Check public access without changing credentials.' }
    } else {
        Save-ToolchainTiming 'rust-install' ([Diagnostics.Stopwatch]::new()) $null 'skipped'
    }
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $assertionOutcome = 'failure'
    try {
        $instance = Enter-CaelestiaToolchain -QtPrefix $qtPrefix `
            -LlvmBin (Join-Path $ToolRoot "$($spec.llvmDirectory)\bin") -ToolsBin (Join-Path $ToolRoot 'tools\Scripts')
        Select-CaelestiaRust
        $receipt = Get-CaelestiaActualToolchain -QtPrefix $qtPrefix -Cli11Include (Join-Path $ToolRoot $spec.cli11Directory)
        $receipt | Add-Member -NotePropertyName vsInstallationVersion -NotePropertyValue $instance.installationVersion
        $receipt | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $ToolRoot 'toolchain.json') -Encoding UTF8
        $assertionOutcome = 'success'
    } finally {
        Save-ToolchainTiming 'final-assertions' $clock $null $assertionOutcome
    }
    if ($ReusePreparedPython -and -not $prepared) {
        $clock = [Diagnostics.Stopwatch]::StartNew()
        & $Python -I -B $preparedVerifier record --environment $environment
        Save-ToolchainTiming 'record-python-environment' $clock $LASTEXITCODE
        if ($LASTEXITCODE -ne 0) { throw 'Prepared Python inventory creation failed.' }
    }
    Write-Host 'Supported toolchain prepared and asserted. toolchain.json contains only public version/hash fields.'
} finally {
    Save-ToolchainTiming 'total' $prepareClock $null 'elapsed'
    Pop-Location
}
