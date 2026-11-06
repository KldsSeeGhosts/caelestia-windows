[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QtPrefix,
    [Parameter(Mandatory)][string]$LlvmBin,
    [Parameter(Mandatory)][string]$Cli11Include,
    [string]$ToolsBin,
    [string]$BuildRoot,
    [ValidateRange(1, 64)][int]$Jobs = 4,
    # Remap native source paths before distributing the resulting binaries.
    [switch]$PublicRelease,
    [switch]$PluginTests,
    # Also build the backend's standalone native fixtures into
    # <BuildRoot>\quickshell-tests; they are never installed or staged.
    [switch]$Tests,
    # Offscreen fixtures only. Production payloads always bundle Glazier.
    [switch]$SkipGlazier
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Caelestia-Toolchain.ps1')
$toolchainSpec = Get-CaelestiaToolchain
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
if (-not $BuildRoot) { $BuildRoot = Join-Path $repoRoot 'windows\.local\build' }
$BuildRoot = [IO.Path]::GetFullPath($BuildRoot)
$installRoot = Join-Path $BuildRoot 'install'
$logRoot = Join-Path $BuildRoot 'logs'
New-Item -ItemType Directory -Force -Path $BuildRoot, $logRoot | Out-Null

foreach ($required in @("$QtPrefix\bin\qtpaths.exe", "$LlvmBin\clang-cl.exe", "$Cli11Include\CLI\CLI.hpp")) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) {
        throw "Missing prerequisite: $required"
    }
}

# Select exact installed VC/SDK and Rust, never the newest installation's
# default toolset. Only this process's environment is changed.
$vsInstance = Enter-CaelestiaToolchain -QtPrefix $QtPrefix -LlvmBin $LlvmBin -ToolsBin $ToolsBin
$vsRoot = $vsInstance.installationPath
Select-CaelestiaRust
$toolchain = Get-CaelestiaActualToolchain -QtPrefix $QtPrefix -Cli11Include $Cli11Include
$toolchain | Add-Member -NotePropertyName vsInstallationVersion -NotePropertyValue $vsInstance.installationVersion
$toolchain | ConvertTo-Json -Depth 5 |
    Set-Content -LiteralPath (Join-Path $logRoot 'toolchain.json') -Encoding UTF8
$manifestTool = Join-Path $env:WindowsSdkDir "bin\$($env:WindowsSDKVersion.TrimEnd('\'))\x64\mt.exe"
if (-not (Test-Path -LiteralPath $manifestTool)) { throw 'Windows SDK manifest tool is required.' }

$report = & (Join-Path $PSScriptRoot 'Test-Environment.ps1') -QtPrefix $QtPrefix -Cli11Include $Cli11Include -Json -Strict
$report | Set-Content -LiteralPath (Join-Path $logRoot 'environment.json') -Encoding UTF8
if ($LASTEXITCODE -ne 0) { throw 'The prerequisite check failed. See logs/environment.json.' }
if (& git -C "$repoRoot\windows\deps\quickshell" status --porcelain) {
    throw 'The pinned backend has local changes. Backend patches must be committed in an appropriate fork before building.'
}

$lock = Get-Content -LiteralPath (Join-Path $repoRoot 'windows\sources.lock.json') -Raw |
    ConvertFrom-Json
$m3shapesPath = Join-Path $repoRoot $lock.m3shapes.path
if (-not (Test-Path -LiteralPath (Join-Path $m3shapesPath 'CMakeLists.txt'))) {
    throw 'The pinned M3Shapes dependency is absent; initialize windows/deps/m3shapes.'
}
$m3shapesRevision = (& git -C $m3shapesPath rev-parse HEAD).Trim()
if ($m3shapesRevision -ne $lock.m3shapes.revision) {
    throw "M3Shapes is at $m3shapesRevision but sources.lock.json pins $($lock.m3shapes.revision)."
}
if (& git -C $m3shapesPath status --porcelain) {
    throw 'The pinned M3Shapes dependency has local changes. Patch and pin it upstream before building.'
}

# Glazier is built from the pinned submodule, not downloaded as a release. The
# release payload is a single static-ish Rust executable next to qs.exe, so an
# update or rollback carries its matching shell and tool together.
$glazierPath = Join-Path $repoRoot $lock.glazier.path
$glazierRevision = ''
$glazierSha256 = ''
if (-not $SkipGlazier) {
    if (-not (Test-Path -LiteralPath (Join-Path $glazierPath 'Cargo.toml'))) {
        throw 'The pinned Glazier dependency is absent; initialize windows/deps/glazier.'
    }
    $glazierRevision = (& git -C $glazierPath rev-parse HEAD).Trim()
    if ($glazierRevision -ne $lock.glazier.revision) {
        throw "Glazier is at $glazierRevision but sources.lock.json pins $($lock.glazier.revision)."
    }
    if (& git -C $glazierPath status --porcelain) {
        throw 'The pinned Glazier dependency has local changes. Patch and pin it upstream before building.'
    }
    if (-not (Get-Command cargo -CommandType Application -ErrorAction SilentlyContinue)) {
        throw 'Rust Cargo is required to bundle Glazier. Install the Rust toolchain, or pass -SkipGlazier for offscreen tests only.'
    }
}

function Invoke-BuildCommand([string]$Name, [string[]]$CommandArguments) {
    Write-Host "== $Name =="
    $CommandArguments | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $logRoot "$Name-command.json") -Encoding UTF8
    # Windows PowerShell represents native stderr as error records, including
    # harmless CMake warnings. The native exit code is the failure criterion.
    $ErrorActionPreference = 'Continue'
    & cmake @CommandArguments 2>&1 | ForEach-Object { "$_" } |
        Tee-Object -FilePath (Join-Path $logRoot "$Name.log")
    $commandExit = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($commandExit -ne 0) { throw "$Name failed. See $logRoot\$Name.log." }
}

$common = @('-G', 'Ninja', '-DCMAKE_BUILD_TYPE=Release', "-DCMAKE_CXX_COMPILER:FILEPATH=$LlvmBin\clang-cl.exe",
    "-DCMAKE_MAKE_PROGRAM:FILEPATH=$((Get-Command ninja.exe -CommandType Application | Select-Object -First 1).Source)",
    '-DCMAKE_LINKER_TYPE=MSVC', "-DCMAKE_MT:FILEPATH=$manifestTool", "-DCMAKE_PREFIX_PATH=$QtPrefix")
$publicPathMappings = @()
if ($PublicRelease) {
    $profilePath = [Environment]::GetFolderPath('UserProfile')
    $cargoHomePath = if ($env:CARGO_HOME) { $env:CARGO_HOME } else { Join-Path $profilePath '.cargo' }
    # Later, more specific mappings win in both Clang and Rust. Vendor headers
    # compiled into our binaries also need neutral file!/__FILE__ locations.
    $publicPathMappings = @(
        @{ path = $profilePath; public = '/user' },
        @{ path = $cargoHomePath; public = '/cargo' },
        @{ path = $env:RUSTUP_HOME; public = '/rustup' },
        @{ path = $vsRoot; public = '/msvc' },
        @{ path = $env:WindowsSdkDir; public = '/winsdk' },
        @{ path = (Split-Path -Parent $LlvmBin); public = '/llvm' },
        @{ path = $QtPrefix; public = '/qt' },
        @{ path = $Cli11Include; public = '/cli11' },
        @{ path = $repoRoot; public = '/source' },
        @{ path = $BuildRoot; public = '/build' }
    )
    $nativePathFlags = @()
    foreach ($mapping in $publicPathMappings) {
        if (-not $mapping.path) { continue }
        $prefix = [IO.Path]::GetFullPath($mapping.path).TrimEnd('\', '/')
        foreach ($spelling in @($prefix, $prefix.Replace('\', '/')) | Select-Object -Unique) {
            $nativePathFlags += '/clang:-ffile-prefix-map=' + $spelling + '=' + $mapping.public
        }
    }
    # CMake handles option quoting after project() initializes native defaults.
    # Do not put private paths in CMAKE_*_FLAGS: the backend embeds those flags
    # into its diagnostic C++ header. Keep remapping in directory options only.
    if (($nativePathFlags -join '').Contains(']===]')) { throw 'Unsupported public-release path delimiter.' }
    $publicOptions = Join-Path $logRoot 'public-release-options.cmake'
    @($nativePathFlags | ForEach-Object { "add_compile_options([===[$_]===])" }) |
        Set-Content -LiteralPath $publicOptions -Encoding UTF8
    $publicCache = Join-Path $logRoot 'public-release.cmake'
    "set(CMAKE_PROJECT_INCLUDE [===[$publicOptions]===] CACHE FILEPATH `"Public release file paths`" FORCE)" |
        Set-Content -LiteralPath $publicCache -Encoding UTF8
    $common += @('-C', $publicCache)
}
Invoke-BuildCommand 'configure-backend' (@('-S', "$repoRoot\windows\deps\quickshell",
    '-B', "$BuildRoot\quickshell") + $common + @("-DCMAKE_C_COMPILER:FILEPATH=$LlvmBin\clang-cl.exe",
    "-DCLI11_INCLUDE_DIR=$Cli11Include", '-DCRASH_HANDLER=OFF', '-DBUILD_TESTING=OFF', '-DINSTALL_QMLDIR=qml',
    '-DQS_AUTOSTART_NAME=CaelestiaPrototype', '-DQS_AUTOSTART_ARGS=',
    '-DQS_AUTOSTART_DESCRIPTION=Caelestia compatibility prototype'))
Invoke-BuildCommand 'build-backend' @('--build', "$BuildRoot\quickshell", '--target', 'quickshell', '--parallel', "$Jobs")
Invoke-BuildCommand 'build-brightness-probe' @('--build', "$BuildRoot\quickshell", '--target', 'brightness-probe', '--parallel', "$Jobs")
if ($Tests) {
    # Run with: ctest --test-dir <BuildRoot>\quickshell-tests -L '^portable$'
    # (see windows/deps/quickshell/src/windows/test/README.md for the tiers).
    $fixtureSource = "$repoRoot\windows\deps\quickshell\src\windows\test"
    if (-not (Test-Path -LiteralPath "$fixtureSource\CMakeLists.txt")) {
        throw 'The pinned backend has no native fixture project; update windows/deps/quickshell.'
    }
    Invoke-BuildCommand 'configure-backend-tests' (@('-S', $fixtureSource, '-B', "$BuildRoot\quickshell-tests") + $common)
    Invoke-BuildCommand 'build-backend-tests' @('--build', "$BuildRoot\quickshell-tests", '--parallel', "$Jobs")
}
Invoke-BuildCommand 'configure-m3shapes' (@('-S', $m3shapesPath, '-B', "$BuildRoot\m3shapes") + $common +
    @('-DINSTALL_QMLDIR=qml', "-DCMAKE_INSTALL_PREFIX=$installRoot", '-DM3SHAPES_BUILD_EXAMPLES=OFF'))
Invoke-BuildCommand 'build-m3shapes' @('--build', "$BuildRoot\m3shapes", '--parallel', "$Jobs")
Invoke-BuildCommand 'install-m3shapes' @('--install', "$BuildRoot\m3shapes")
if ($SkipGlazier) {
    # Never leave a previous run's tool in a payload that claims to omit it.
    Remove-Item -LiteralPath (Join-Path $installRoot 'glazier.exe') -Force -ErrorAction SilentlyContinue
    Write-Warning 'Skipping the bundled Glazier build (-SkipGlazier); the staged payload is not installable.'
} else {
    Write-Host '== build-glazier =='
    New-Item -ItemType Directory -Force -Path $installRoot | Out-Null
    # Keep Cargo's whole target tree inside the disposable build root, never in
    # the submodule or the user's profile. --locked refuses an unpinned update.
    $cargoArguments = @('build', '--release', '--locked', '--jobs', "$Jobs", '--target', $toolchainSpec.rustTarget, '--manifest-path', (Join-Path $glazierPath 'Cargo.toml'),
        '--target-dir', (Join-Path $BuildRoot 'glazier-target'))
    $cargoArguments | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $logRoot 'build-glazier-command.json') -Encoding UTF8
    $previousEncodedRustFlags = [Environment]::GetEnvironmentVariable('CARGO_ENCODED_RUSTFLAGS', 'Process')
    if ($PublicRelease) {
        # Rust panic/file! strings can retain Cargo's personal registry path.
        # Encoded arguments preserve paths containing spaces. Caller-supplied
        # environment flags retain Cargo's encoded-over-plain precedence.
        $separator = [string][char]0x1f
        $publicRustFlags = @()
        if ($null -ne $previousEncodedRustFlags) {
            if ($previousEncodedRustFlags.Length) { $publicRustFlags = @($previousEncodedRustFlags.Split([char]0x1f)) }
        } elseif ($env:RUSTFLAGS) {
            $publicRustFlags = @($env:RUSTFLAGS -split '\s+' | Where-Object { $_ })
        }
        foreach ($mapping in $publicPathMappings) {
            if (-not $mapping.path) { continue }
            $prefix = [IO.Path]::GetFullPath($mapping.path).TrimEnd('\', '/')
            $spellings = @($prefix, $prefix.Replace('\', '/')) | Select-Object -Unique
            foreach ($spelling in $spellings) {
                $publicRustFlags += "--remap-path-prefix=$spelling=$($mapping.public)"
            }
        }
        [Environment]::SetEnvironmentVariable('CARGO_ENCODED_RUSTFLAGS', ($publicRustFlags -join $separator), 'Process')
    }
    try {
        # Cargo writes progress to stderr; the native exit code is the failure criterion.
        $ErrorActionPreference = 'Continue'
        & cargo @cargoArguments 2>&1 | ForEach-Object { "$_" } |
            Tee-Object -FilePath (Join-Path $logRoot 'build-glazier.log')
        $cargoExit = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = 'Stop'
        if ($PublicRelease) {
            [Environment]::SetEnvironmentVariable('CARGO_ENCODED_RUSTFLAGS', $previousEncodedRustFlags, 'Process')
        }
    }
    if ($cargoExit -ne 0) { throw "build-glazier failed. See $logRoot\build-glazier.log." }
    $glazierExe = Join-Path $BuildRoot "glazier-target\$($toolchainSpec.rustTarget)\release\glazier.exe"
    if (-not (Test-Path -LiteralPath $glazierExe -PathType Leaf)) {
        throw "Glazier built without producing $glazierExe."
    }
    Copy-Item -LiteralPath $glazierExe -Destination (Join-Path $installRoot 'glazier.exe') -Force
    $glazierSha256 = (Get-FileHash -LiteralPath (Join-Path $installRoot 'glazier.exe') -Algorithm SHA256).Hash.ToLowerInvariant()
}
# Resolve the version and revision up front so configure works without a reachable git tag or git metadata.
$ErrorActionPreference = 'Continue'
$sourceVersion = & git -C $repoRoot describe --tags --abbrev=0 2>$null
$describeExit = $LASTEXITCODE
$rawShortRevision = & git -C $repoRoot rev-parse --short HEAD 2>$null
$shortRevExit = $LASTEXITCODE
$rawFullRevision = & git -C $repoRoot rev-parse HEAD 2>$null
$fullRevExit = $LASTEXITCODE
$rawDirty = & git -C $repoRoot status --porcelain 2>$null
$ErrorActionPreference = 'Stop'
if ($describeExit -ne 0 -or -not $sourceVersion) { $sourceVersion = '0.0.0' }
# CMake project(VERSION) accepts numeric components, not prerelease labels.
if ("$sourceVersion".Trim() -match '^v?(\d+\.\d+\.\d+(?:\.\d+)?)(?:[-+].*)?$') {
    $sourceVersion = $Matches[1]
} else { $sourceVersion = '0.0.0' }
$sourceRevision = if ($shortRevExit -eq 0 -and $rawShortRevision) { "$rawShortRevision".Trim() } else { 'unknown' }
if (-not $sourceRevision) { $sourceRevision = 'unknown' }
$fullSourceRevision = if ($fullRevExit -eq 0 -and $rawFullRevision) { "$rawFullRevision".Trim() } else { $sourceRevision }

Invoke-BuildCommand 'configure-plugins' (@('-S', $repoRoot, '-B', "$BuildRoot\caelestia") + $common +
    @('-DCAELESTIA_PORTABLE_UI=ON', '-DENABLE_MODULES=plugin', '-DINSTALL_QMLDIR=qml',
    "-DCMAKE_INSTALL_PREFIX=$installRoot", "-DVERSION=$sourceVersion", "-DGIT_REVISION=$sourceRevision",
    "-DCAELESTIA_WINDOWS_TESTS=$(if ($PluginTests) { 'ON' } else { 'OFF' })"))
Invoke-BuildCommand 'build-plugins' @('--build', "$BuildRoot\caelestia", '--parallel', "$Jobs")
Invoke-BuildCommand 'install-plugins' @('--install', "$BuildRoot\caelestia")

[ordered]@{
    sourceRevision = $fullSourceRevision
    sourceDirty = [bool]$rawDirty
    backendRevision = (& git -C "$repoRoot\windows\deps\quickshell" rev-parse HEAD).Trim()
    m3shapesRevision = $m3shapesRevision
    glazierRevision = $glazierRevision
    glazierSha256 = $glazierSha256
    glazierBundled = -not $SkipGlazier
    publicRelease = [bool]$PublicRelease
    pluginTests = [bool]$PluginTests
    backendTests = [bool]$Tests
    nativeVersion = $sourceVersion
    toolchain = $toolchain
    windowsSdkVersion = $toolchain.windowsSdkVersion
    msvcToolsVersion = $toolchain.vcToolsVersion
    qtVersion = (& "$QtPrefix\bin\qtpaths.exe" --qt-version).Trim()
    qtPrefix = $QtPrefix
    compiler = (& "$LlvmBin\clang-cl.exe" --version | Select-Object -First 1)
    cmake = (& cmake --version | Select-Object -First 1)
    ninja = (& ninja --version)
    windows = [Environment]::OSVersion.VersionString
    builtAtUtc = [DateTime]::UtcNow.ToString('o')
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $logRoot 'build.json') -Encoding UTF8
# Explicit public allowlist. Never upload the private build/environment
# receipts, command arguments, local paths or raw logs as toolchain evidence.
[ordered]@{
    schemaVersion = 1
    toolchain = $toolchain
    sourceRevision = $fullSourceRevision
    sourceDirty = [bool]$rawDirty
    backendRevision = (& git -C "$repoRoot\windows\deps\quickshell" rev-parse HEAD).Trim()
    m3shapesRevision = $m3shapesRevision
    glazierRevision = $glazierRevision
    glazierBundled = -not $SkipGlazier
    glazierSha256 = $glazierSha256
    publicRelease = [bool]$PublicRelease
    builtAtUtc = [DateTime]::UtcNow.ToString('o')
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $logRoot 'toolchain.json') -Encoding UTF8
Write-Host "Built backend, portable plugins and bundled Glazier. Evidence: $logRoot"
