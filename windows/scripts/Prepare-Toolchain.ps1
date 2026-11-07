#requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ToolRoot,
    [string]$Python = 'python',
    # Explicit provisioning only. Builds/checks never install or update Rust.
    [switch]$InstallRust
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Caelestia-Toolchain.ps1')
Initialize-CaelestiaToolchainModules
$spec = Get-CaelestiaToolchain
$ToolRoot = [IO.Path]::GetFullPath($ToolRoot)
$repoRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\..')).TrimEnd('\')
if ($ToolRoot -eq $repoRoot -or $ToolRoot.StartsWith($repoRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
    throw 'ToolRoot must be outside the source checkout.'
}
$downloads = Join-Path $ToolRoot 'downloads'
New-Item -ItemType Directory -Force -Path $ToolRoot, $downloads | Out-Null

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
    & $Python -m venv (Join-Path $ToolRoot 'tools')
    if ($LASTEXITCODE -ne 0) { throw 'Python tool environment creation failed.' }
    $venvPython = Join-Path $ToolRoot 'tools\Scripts\python.exe'
    foreach ($lock in @('python-bootstrap.lock.txt', 'python-tools.lock.txt')) {
        & $venvPython -m pip install --disable-pip-version-check --only-binary=:all: --require-hashes `
            -r (Join-Path $PSScriptRoot "..\toolchain\$lock")
        if ($LASTEXITCODE -ne 0) { throw "Hash-locked Python provisioning failed ($lock). Use Python 3.12 x64 and the committed public inputs." }
    }
    $aqtArchive = Get-VerifiedToolchainArchive $spec.downloads.aqt
    & $venvPython -m pip install --disable-pip-version-check --no-deps --no-build-isolation $aqtArchive
    if ($LASTEXITCODE -ne 0) { throw 'Verified aqt installation failed.' }

    $qtPrefix = Join-Path $ToolRoot $spec.qtDirectory
    $qtDownloads = Join-Path $downloads 'qt'
    New-Item -ItemType Directory -Force -Path $qtDownloads | Out-Null
    if (-not (Test-Path -LiteralPath "$qtPrefix\bin\qtpaths.exe" -PathType Leaf)) {
        # aqt verifies upstream SHA-256 before extraction. Retain the bytes
        # and check the committed hashes as well, before any compilation.
        & $venvPython -m aqt install-qt windows desktop $spec.qtVersion $spec.qtArchitecture `
            -O (Join-Path $ToolRoot 'Qt') --modules @($spec.qtModules) --archives @($spec.qtArchives) `
            --keep --archive-dest $qtDownloads
        if ($LASTEXITCODE -ne 0) { throw 'Qt provisioning failed; do not disable aqt checksum verification.' }
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
    if (-not (Test-Path -LiteralPath (Join-Path $ToolRoot "$($spec.llvmDirectory)\bin\clang-cl.exe"))) {
        Write-Host 'Extracting verified LLVM archive.'
        & "$env:SystemRoot\System32\tar.exe" -xf $llvm -C $ToolRoot
        if ($LASTEXITCODE -ne 0) { throw 'Verified LLVM extraction failed.' }
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
        & rustup.exe toolchain install "$($spec.rustVersion)-$($spec.rustTarget)" --profile minimal --target $spec.rustTarget
        if ($LASTEXITCODE -ne 0) { throw 'Pinned Rust installation failed. Check public access without changing credentials.' }
    }
    $instance = Enter-CaelestiaToolchain -QtPrefix $qtPrefix `
        -LlvmBin (Join-Path $ToolRoot "$($spec.llvmDirectory)\bin") -ToolsBin (Join-Path $ToolRoot 'tools\Scripts')
    Select-CaelestiaRust
    $receipt = Get-CaelestiaActualToolchain -QtPrefix $qtPrefix -Cli11Include (Join-Path $ToolRoot $spec.cli11Directory)
    $receipt | Add-Member -NotePropertyName vsInstallationVersion -NotePropertyValue $instance.installationVersion
    $receipt | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $ToolRoot 'toolchain.json') -Encoding UTF8
    Write-Host 'Supported toolchain prepared and asserted. toolchain.json contains only public version/hash fields.'
} finally {
    Pop-Location
}
