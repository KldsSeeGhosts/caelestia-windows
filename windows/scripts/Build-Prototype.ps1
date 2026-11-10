[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QtPrefix,
    [Parameter(Mandatory)][string]$LlvmBin,
    [Parameter(Mandatory)][string]$Cli11Include,
    [string]$ToolsBin,
    [string]$BuildRoot,
    # Optional accelerator. An empty value also clears a reused CMake cache.
    [string]$CompilerLauncher,
    # Opt-in Rust cache, separate from C/C++ objects. Requires CompilerLauncher.
    [string]$RustCacheDirectory,
    # Integration-only canonical checkout, outside this shell repository.
    [string]$BackendRoot,
    [ValidatePattern('^[a-f0-9]{40}$')][string]$CandidateBackendRevision,
    [ValidateRange(1, 64)][int]$Jobs = 4,
    # Remap native source paths before distributing the resulting binaries.
    [switch]$PublicRelease,
    [switch]$PluginTests,
    # Also build the backend's standalone native fixtures into
    # <BuildRoot>\quickshell-tests; they are never installed or staged.
    [switch]$Tests,
    # Offscreen fixtures only. Production payloads always bundle capture.
    [Alias('SkipGlazier')][switch]$SkipCapture
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Caelestia-Toolchain.ps1')
Initialize-CaelestiaToolchainModules
$toolchainSpec = Get-CaelestiaToolchain
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
. (Join-Path $repoRoot 'windows\capture\Source.ps1')
$backendMode = 'pinned'
if ([bool]$BackendRoot -ne [bool]$CandidateBackendRevision) {
    throw 'BackendRoot and CandidateBackendRevision must be supplied together.'
}
$backendPath = Join-Path $repoRoot 'windows\deps\quickshell'
if ($BackendRoot) {
    $backendPath = (Resolve-Path -LiteralPath $BackendRoot).Path
    if ($backendPath -eq $repoRoot -or $backendPath.StartsWith($repoRoot + '\', [StringComparison]::OrdinalIgnoreCase) -or
        $repoRoot.StartsWith($backendPath + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Candidate backend must be a separate clone outside the shell checkout.'
    }
    $backendTop = & git -C $backendPath rev-parse --show-toplevel
    if ($LASTEXITCODE -ne 0 -or [IO.Path]::GetFullPath($backendTop) -ne $backendPath) { throw 'Invalid candidate source root.' }
    $backendOrigin = & git -C $backendPath remote get-url origin
    if ($LASTEXITCODE -ne 0 -or "$backendOrigin".Trim().TrimEnd('/') -notin @(
        'https://github.com/KldsSeeGhosts/caelestia-quickshell-windows',
        'https://github.com/KldsSeeGhosts/caelestia-quickshell-windows.git')) { throw 'Candidate backend repository mismatch.' }
    $actualBackend = & git -C $backendPath rev-parse HEAD
    if ($LASTEXITCODE -ne 0 -or $actualBackend -cne $CandidateBackendRevision) { throw 'Candidate backend resolved SHA mismatch.' }
    $backendMode = 'candidate'
}
$backendDirt = & git -C $backendPath status --porcelain --untracked-files=all
if ($LASTEXITCODE -ne 0 -or $backendDirt) { throw 'Backend source must be a clean exact checkout.' }
$gitlink = & git -C $repoRoot ls-tree HEAD -- windows/deps/quickshell
if ($LASTEXITCODE -ne 0 -or "$gitlink" -notmatch '^160000 commit ([a-f0-9]{40})\s') { throw 'Backend gitlink is missing.' }
$pinnedBackendRevision = $Matches[1]
$sourceLock = Get-Content -LiteralPath "$repoRoot\windows\sources.lock.json" -Raw | ConvertFrom-Json
if ($pinnedBackendRevision -cne $sourceLock.quickshell.revision) { throw 'Backend gitlink and source lock disagree.' }
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

# First-party source is part of this shell revision, not a separate checkout.
$captureSource = Get-CaelestiaCaptureSource $repoRoot
$captureSha256 = ''
$cargoPath = ''
if (-not $SkipCapture) {
    # Resolve once: the background Cargo job must start the same executable.
    $cargoPath = (Get-Command cargo -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1).Source
    if (-not $cargoPath) {
        throw 'Rust Cargo is required to bundle Caelestia capture. Use -SkipCapture for offscreen tests only.'
    }
}

function Invoke-BuildCommand([string]$Name, [string[]]$CommandArguments) {
    Write-Host "== $Name =="
    $CommandArguments | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $logRoot "$Name-command.json") -Encoding UTF8
    # Windows PowerShell represents native stderr as error records, including
    # harmless CMake warnings. The native exit code is the failure criterion.
    $ErrorActionPreference = 'Continue'
    $commandClock = [Diagnostics.Stopwatch]::StartNew()
    & cmake @CommandArguments 2>&1 | ForEach-Object { "$_" } |
        Tee-Object -FilePath (Join-Path $logRoot "$Name.log")
    $commandExit = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    # Like capture timing, retain only duration and exit status, not arguments.
    [ordered]@{
        durationSeconds = [Math]::Round($commandClock.Elapsed.TotalSeconds, 6)
        exitCode = $commandExit
    } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $logRoot "$Name-timing.json") -Encoding UTF8
    if ($commandExit -ne 0) { throw "$Name failed. See $logRoot\$Name.log." }
}

# A background job starts in the user's Documents folder. Each chain returns
# to the caller's directory, where Cargo and CMake ran in the serial build.
$callerDirectory = (Get-Location -PSProvider FileSystem).ProviderPath
# Components consume each other's outputs in chains. Chains share no build
# directory, so they can run at the same time; each chain still runs its own
# components strictly in order. A chain runs in a job because one PowerShell
# pipeline can only wait on one native command at a time.
$buildStreamScript = {
    param([string]$Definition, [object[]]$Components, [string]$logRoot, [string]$WorkingDirectory)
    $ErrorActionPreference = 'Stop'
    Set-Location -LiteralPath $WorkingDirectory
    # Reuse the foreground runner verbatim, so the command record, log, timing
    # file and failure message cannot drift between a foreground and a
    # background chain.
    . ([scriptblock]::Create($Definition))
    foreach ($component in $Components) {
        try {
            Invoke-BuildCommand ([string]$component.name) ([string[]]@($component.arguments)) | Out-Null
        } catch {
            # The runner already wrote the component's artifacts; report only
            # its message to the calling stream.
            return ([pscustomobject][ordered]@{ name = [string]$component.name; message = "$_" })
        }
    }
    return
}

function Start-BuildStream([string]$Name, [object[]]$Components) {
    $definition = "function Invoke-BuildCommand { $((Get-Command -Name Invoke-BuildCommand).Definition) }"
    return [pscustomobject]@{
        name = $Name
        joined = $false
        job = Start-Job -Name $Name -ScriptBlock $buildStreamScript -ArgumentList $definition, $Components, $logRoot, $callerDirectory
    }
}

function Wait-BuildStream($Stream) {
    # The stream replays its component labels into this console and returns its
    # first failed component. Component output stays in its own log file.
    $received = @(Receive-Job -Job $Stream.job -Wait -AutoRemoveJob)
    if ($Stream.job.State -ne 'Completed') {
        throw "Build stream $($Stream.name) did not complete ($($Stream.job.State)). See $logRoot."
    }
    foreach ($item in $received) {
        if ($null -ne $item -and $null -ne $item.PSObject.Properties['message']) { return $item }
    }
    return $null
}

# Cargo writes progress to stderr; the native exit code is the failure criterion.
$captureScript = {
    param([string]$CargoPath, [string[]]$Arguments, [string]$logRoot, [string]$WorkingDirectory)
    $ErrorActionPreference = 'Stop'
    Set-Location -LiteralPath $WorkingDirectory
    $captureClock = [Diagnostics.Stopwatch]::StartNew()
    $cargoExit = $null
    try {
        $ErrorActionPreference = 'Continue'
        & $CargoPath @Arguments 2>&1 | ForEach-Object { "$_" } |
            Tee-Object -FilePath (Join-Path $logRoot 'build-capture.log') | Out-Null
        $cargoExit = $LASTEXITCODE
    } finally {
        [ordered]@{
            durationSeconds = [Math]::Round($captureClock.Elapsed.TotalSeconds, 6)
            exitCode = $cargoExit
        } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $logRoot 'build-capture-timing.json') -Encoding UTF8
    }
}

if ($CompilerLauncher -and (-not [IO.Path]::IsPathRooted($CompilerLauncher) -or
    -not (Test-Path -LiteralPath $CompilerLauncher -PathType Leaf))) {
    throw 'CompilerLauncher must name an existing absolute executable path.'
}
if ($RustCacheDirectory -and (-not $CompilerLauncher -or -not [IO.Path]::IsPathRooted($RustCacheDirectory))) {
    throw 'RustCacheDirectory requires an absolute path and CompilerLauncher.'
}
$common = @('-G', 'Ninja', '-DCMAKE_BUILD_TYPE=Release',
    "-DCMAKE_C_COMPILER_LAUNCHER:FILEPATH=$CompilerLauncher",
    "-DCMAKE_CXX_COMPILER_LAUNCHER:FILEPATH=$CompilerLauncher",
    "-DCMAKE_CXX_COMPILER:FILEPATH=$LlvmBin\clang-cl.exe",
    "-DCMAKE_MAKE_PROGRAM:FILEPATH=$((Get-Command ninja.exe -CommandType Application | Select-Object -First 1).Source)",
    "-DCMAKE_LINKER:FILEPATH=$env:VCToolsInstallDir\bin\Hostx64\x64\link.exe",
    '-DCMAKE_LINKER_TYPE=MSVC', "-DCMAKE_MT:FILEPATH=$manifestTool", "-DCMAKE_PREFIX_PATH=$QtPrefix")
# sccache cannot cache MSVC-style precompiled-header compiles (/Yc, /Fp): with
# PCH on, about 409 of 590 production compiles stayed uncacheable. With the
# launcher, disable PCH everywhere (CMake-wide, plus the backend's own NO_PCH
# switch) so every compile is cacheable. Without it, PCH stays as before.
# Precompiled headers change compile speed only, not the translated program.
$pchSwitch = if ($CompilerLauncher) { 'ON' } else { 'OFF' }
$common += @("-DCMAKE_DISABLE_PRECOMPILE_HEADERS=$pchSwitch", "-DNO_PCH=$pchSwitch")
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
        @{ path = $backendPath; public = '/backend' },
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
# Version and revision are read before compiling because the plugin
# configuration records them. The dirty flag is still read after the build, so
# build.json keeps describing the state the build ended in.
. (Join-Path $PSScriptRoot 'Caelestia-SemVer.ps1')
$versionPath = Join-Path $repoRoot 'windows\release\version.json'
$sourceVersion = (Read-CaelestiaVersion $versionPath).version
$versionFileSha256 = (Get-FileHash -LiteralPath $versionPath -Algorithm SHA256).Hash.ToLowerInvariant()
$ErrorActionPreference = 'Continue'
$rawShortRevision = & git -C $repoRoot rev-parse --short HEAD 2>$null
$shortRevExit = $LASTEXITCODE
$rawFullRevision = & git -C $repoRoot rev-parse HEAD 2>$null
$fullRevExit = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
$sourceRevision = if ($shortRevExit -eq 0 -and $rawShortRevision) { "$rawShortRevision".Trim() } else { 'unknown' }
if (-not $sourceRevision) { $sourceRevision = 'unknown' }
$fullSourceRevision = if ($fullRevExit -eq 0 -and $rawFullRevision) { "$rawFullRevision".Trim() } else { $sourceRevision }

# Dependency order, unchanged from the serial build:
#   configure-backend -> build-backend -> build-brightness-probe [-> backend fixtures]
#       (these share the quickshell Ninja tree, so they stay one serial chain)
#   configure-m3shapes -> build-m3shapes -> install-m3shapes
#   build-capture (Cargo; consumes only windows/capture and the toolchain)
#   configure-plugins -> build-plugins -> install-plugins
#   supervisor compilation -> native inventory (needs qs.exe and each install)
# No chain consumes another chain's output and each writes its own build
# directory, so the three chains run at the same time. Components inside a
# chain keep their order.
$m3shapesConfigure = @('-S', $m3shapesPath, '-B', "$BuildRoot\m3shapes") + $common +
    @('-DINSTALL_QMLDIR=qml', "-DCMAKE_INSTALL_PREFIX=$installRoot", '-DM3SHAPES_BUILD_EXAMPLES=OFF')
$pluginConfigure = @('-S', $repoRoot, '-B', "$BuildRoot\caelestia") + $common +
    @('-DCAELESTIA_PORTABLE_UI=ON', '-DENABLE_MODULES=plugin', '-DINSTALL_QMLDIR=qml',
    "-DCMAKE_INSTALL_PREFIX=$installRoot", "-DVERSION=$sourceVersion", "-DGIT_REVISION=$sourceRevision",
    "-DCAELESTIA_WINDOWS_TESTS=$(if ($PluginTests) { 'ON' } else { 'OFF' })")
# One -Jobs budget covers every chain that runs at the same time. Hosted CI
# sizes -Jobs from the processor count and the memory one compile needs, so
# three chains that each used the whole budget would triple peak memory on a
# cold build. The backend keeps the largest share. When the budget is smaller
# than the number of chains, the chains run one after another, each with the
# whole budget, as the serial build did.
$chainCount = if ($SkipCapture) { 2 } else { 3 }
$overlapChains = $Jobs -ge $chainCount
if ($overlapChains) {
    $moduleJobs = [Math]::Max(1, [int][Math]::Floor($Jobs / 4))
    $captureJobs = if ($SkipCapture) { 0 } else { $moduleJobs }
    $backendJobs = $Jobs - $moduleJobs - $captureJobs
} else {
    $moduleJobs = $captureJobs = $backendJobs = $Jobs
}
# A stream that would have failed earlier in the serial build reports first.
$serialComponentOrder = @('configure-m3shapes', 'build-m3shapes', 'install-m3shapes',
    'build-capture', 'configure-plugins', 'build-plugins', 'install-plugins')

# Every started job is registered here at once, so the cleanup below also
# covers a failure between two launches.
$streams = [Collections.Generic.List[object]]::new()
$failures = @()
function Complete-BuildStream($Stream) {
    if ($Stream.joined) { return }
    $Stream.joined = $true
    if ($Stream.name -cne 'build-capture') {
        $failure = Wait-BuildStream $Stream
        if ($failure) { $script:failures += $failure }
        return
    }
    [void]@(Receive-Job -Job $Stream.job -Wait -AutoRemoveJob)
    # Read the exit status back from the artifact, exactly as the serial build
    # recorded it.
    $captureExit = $null
    $captureTimingPath = Join-Path $logRoot 'build-capture-timing.json'
    if (Test-Path -LiteralPath $captureTimingPath -PathType Leaf) {
        $captureExit = (Get-Content -LiteralPath $captureTimingPath -Raw | ConvertFrom-Json).exitCode
    }
    if ($captureExit -ne 0) {
        $script:failures += [pscustomobject]@{ name = 'build-capture'
            message = "build-capture failed. See $logRoot\build-capture.log." }
    }
}
function Assert-NoBuildStreamFailure {
    $firstFailure = $null
    foreach ($failure in $script:failures) {
        if ($null -eq $firstFailure -or
            [array]::IndexOf($serialComponentOrder, $failure.name) -lt
            [array]::IndexOf($serialComponentOrder, $firstFailure.name)) { $firstFailure = $failure }
    }
    if ($firstFailure) { throw $firstFailure.message }
}
try {
    $moduleStream = Start-BuildStream 'module-chains' @(
        [pscustomobject]@{ name = 'configure-m3shapes'; arguments = $m3shapesConfigure }
        [pscustomobject]@{ name = 'build-m3shapes'; arguments = @('--build', "$BuildRoot\m3shapes", '--parallel', "$moduleJobs") }
        [pscustomobject]@{ name = 'install-m3shapes'; arguments = @('--install', "$BuildRoot\m3shapes") }
        [pscustomobject]@{ name = 'configure-plugins'; arguments = $pluginConfigure }
        [pscustomobject]@{ name = 'build-plugins'; arguments = @('--build', "$BuildRoot\caelestia", '--parallel', "$moduleJobs") }
        [pscustomobject]@{ name = 'install-plugins'; arguments = @('--install', "$BuildRoot\caelestia") }
    )
    $streams.Add($moduleStream)
    if (-not $overlapChains) { Complete-BuildStream $moduleStream; Assert-NoBuildStreamFailure }

    $captureStream = $null
    if ($SkipCapture) {
        # Never leave a previous run's tool in a payload that claims to omit it.
        Remove-Item -LiteralPath (Join-Path $installRoot 'caelestia-capture.exe') -Force -ErrorAction SilentlyContinue
        Write-Warning 'Skipping Caelestia capture (-SkipCapture); the staged payload is not installable.'
    } else {
        Write-Host '== build-capture =='
        New-Item -ItemType Directory -Force -Path $installRoot | Out-Null
        # Keep Cargo's whole target tree inside the disposable build root, never in
        # the source or the user's profile. --locked refuses an unpinned update.
        $cargoArguments = @('build', '--release', '--locked', '--jobs', "$captureJobs", '--target', $toolchainSpec.rustTarget, '--manifest-path', (Join-Path $captureSource.path 'Cargo.toml'),
            '--target-dir', (Join-Path $BuildRoot 'capture-target'))
        $cargoArguments | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $logRoot 'build-capture-command.json') -Encoding UTF8
        $previousEncodedRustFlags = [Environment]::GetEnvironmentVariable('CARGO_ENCODED_RUSTFLAGS', 'Process')
        $rustCacheEnvironment = @{}
        if ($RustCacheDirectory) {
            foreach ($name in @('RUSTC_WRAPPER', 'CARGO_INCREMENTAL', 'SCCACHE_DIR', 'SCCACHE_SERVER_PORT')) {
                $rustCacheEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
            }
            $env:RUSTC_WRAPPER = $CompilerLauncher
            $env:CARGO_INCREMENTAL = '0'
            $env:SCCACHE_DIR = $RustCacheDirectory
            # Separate server: a running sccache server keeps its original cache dir.
            $env:SCCACHE_SERVER_PORT = '4227'
        }
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
            # The job starts with this process's environment, so the selected Rust
            # toolchain, the remapped flags and the sccache wrapper reach Cargo
            # unchanged. Restore this process immediately after the launch; no
            # other child inherits the Rust cache settings.
            $captureStream = [pscustomobject]@{
                name = 'build-capture'
                joined = $false
                job = Start-Job -Name 'build-capture' -ScriptBlock $captureScript -ArgumentList $cargoPath, $cargoArguments, $logRoot, $callerDirectory
            }
            $streams.Add($captureStream)
        } finally {
            foreach ($name in $rustCacheEnvironment.Keys) {
                [Environment]::SetEnvironmentVariable($name, $rustCacheEnvironment[$name], 'Process')
            }
            if ($PublicRelease) {
                [Environment]::SetEnvironmentVariable('CARGO_ENCODED_RUSTFLAGS', $previousEncodedRustFlags, 'Process')
            }
        }
    }
    if ($captureStream -and -not $overlapChains) { Complete-BuildStream $captureStream; Assert-NoBuildStreamFailure }

    Invoke-BuildCommand 'configure-backend' (@('-S', $backendPath,
        '-B', "$BuildRoot\quickshell") + $common + @("-DCMAKE_C_COMPILER:FILEPATH=$LlvmBin\clang-cl.exe",
        "-DCLI11_INCLUDE_DIR=$Cli11Include", '-DCRASH_HANDLER=OFF', '-DBUILD_TESTING=OFF', '-DINSTALL_QMLDIR=qml',
        '-DQS_AUTOSTART_NAME=CaelestiaPrototype', '-DQS_AUTOSTART_ARGS=',
        '-DQS_AUTOSTART_DESCRIPTION=Caelestia compatibility prototype'))
    Invoke-BuildCommand 'build-backend' @('--build', "$BuildRoot\quickshell", '--target', 'quickshell', '--parallel', "$backendJobs")
    Invoke-BuildCommand 'build-brightness-probe' @('--build', "$BuildRoot\quickshell", '--target', 'brightness-probe', '--parallel', "$backendJobs")
    if ($Tests) {
        # Run with: ctest --test-dir <BuildRoot>\quickshell-tests -L '^portable$'
        # (see windows/deps/quickshell/src/windows/test/README.md for the tiers).
        $fixtureSource = Join-Path $backendPath 'src\windows\test'
        if (-not (Test-Path -LiteralPath "$fixtureSource\CMakeLists.txt")) {
            throw 'The pinned backend has no native fixture project; update windows/deps/quickshell.'
        }
        Invoke-BuildCommand 'configure-backend-tests' (@('-S', $fixtureSource, '-B', "$BuildRoot\quickshell-tests") + $common)
        Invoke-BuildCommand 'build-backend-tests' @('--build', "$BuildRoot\quickshell-tests", '--parallel', "$backendJobs")
    }

    # Join every chain before touching the payload. A component that would
    # have run earlier in the serial build reports its failure first.
    foreach ($stream in $streams) { Complete-BuildStream $stream }
    Assert-NoBuildStreamFailure
    if ($captureStream) {
        $captureExe = Join-Path $BuildRoot "capture-target\$($toolchainSpec.rustTarget)\release\caelestia-capture.exe"
        if (-not (Test-Path -LiteralPath $captureExe -PathType Leaf)) {
            throw "Capture built without producing $captureExe."
        }
        Copy-Item -LiteralPath $captureExe -Destination (Join-Path $installRoot 'caelestia-capture.exe') -Force
        $captureSha256 = (Get-FileHash -LiteralPath (Join-Path $installRoot 'caelestia-capture.exe') -Algorithm SHA256).Hash.ToLowerInvariant()
    }
} finally {
    # A failed stream must never leave a compiler, Cargo or sccache client
    # running behind this script.
    foreach ($stream in $streams) {
        Stop-Job -Job $stream.job -ErrorAction SilentlyContinue
        Remove-Job -Job $stream.job -Force -ErrorAction SilentlyContinue
    }
}

# Old payload names must never survive a rebuild in this owned output.
Remove-Item -LiteralPath (Join-Path $installRoot 'glazier.exe') -Force -ErrorAction SilentlyContinue
# Git is provenance only, and the dirty flag still describes the state the
# build ended in, as it did when every component ran serially.
$ErrorActionPreference = 'Continue'
$rawDirty = & git -C $repoRoot status --porcelain 2>$null
$ErrorActionPreference = 'Stop'

# Build the managed supervisor once, before the production gates. Release
# assembly must copy these tested bytes, not compile another payload.
$supervisorSource = Join-Path $PSScriptRoot 'DesktopTakeover.cs'
$supervisorAssembly = Join-Path $installRoot 'DesktopTakeover.dll'
$supervisorMetadata = Join-Path $installRoot 'DesktopTakeover.build.json'
$supervisorSourceHash = (Get-FileHash -LiteralPath $supervisorSource).Hash
$supervisorReady = $false
if ((Test-Path -LiteralPath $supervisorMetadata) -and (Test-Path -LiteralPath $supervisorAssembly)) {
    $priorSupervisor = Get-Content -LiteralPath $supervisorMetadata -Raw | ConvertFrom-Json
    $supervisorReady = $priorSupervisor.sourceSha256 -eq $supervisorSourceHash -and
        $priorSupervisor.clrVersion -eq [Environment]::Version.ToString() -and
        $priorSupervisor.assemblySha256 -eq (Get-FileHash -LiteralPath $supervisorAssembly).Hash
}
if (-not $supervisorReady) {
    if (Test-Path -LiteralPath $supervisorAssembly) { Remove-Item -LiteralPath $supervisorAssembly }
    $compileSupervisor = "Add-Type -Path '" + $supervisorSource.Replace("'", "''") +
        "' -OutputAssembly '" + $supervisorAssembly.Replace("'", "''") +
        "' -ReferencedAssemblies System.Windows.Forms,System.Web.Extensions -ErrorAction Stop"
    & "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -Command $compileSupervisor
    if ($LASTEXITCODE -ne 0) { throw 'Production supervisor compilation failed.' }
}
$supervisor = [ordered]@{
    sourceSha256 = $supervisorSourceHash
    assemblySha256 = (Get-FileHash -LiteralPath $supervisorAssembly).Hash
    clrVersion = [Environment]::Version.ToString()
}
$supervisor | ConvertTo-Json | Set-Content -LiteralPath $supervisorMetadata -Encoding UTF8
# Metadata-only reflection never constructs a supervisor or invokes Win32.
$supervisorReflection = [Reflection.Assembly]::ReflectionOnlyLoadFrom($supervisorAssembly)
if (-not $supervisorReflection.GetType('Caelestia.Takeover.SupervisorSafety', $false)) {
    throw 'Production supervisor ABI verification failed.'
}
$nativeFiles = @((Get-Item -LiteralPath "$BuildRoot\quickshell\qs.exe"),
    (Get-Item -LiteralPath $supervisorAssembly))
if (-not $SkipCapture) { $nativeFiles += Get-Item -LiteralPath "$installRoot\caelestia-capture.exe" }
$nativeFiles += @(Get-ChildItem -LiteralPath "$installRoot\qml" -File -Recurse)
$nativeInputs = @($nativeFiles | Sort-Object FullName | ForEach-Object {
    [ordered]@{
        path = $_.FullName.Substring($BuildRoot.TrimEnd('\').Length + 1).Replace('\', '/')
        sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
    }
})

[ordered]@{
    sourceRevision = $fullSourceRevision
    sourceDirty = [bool]$rawDirty
    backendRevision = (& git -C $backendPath rev-parse HEAD).Trim()
    backendMode = $backendMode
    pinnedBackendRevision = $pinnedBackendRevision
    lockBackendRevision = $sourceLock.quickshell.revision
    m3shapesRevision = $m3shapesRevision
    captureSourcePath = $captureSource.relativePath
    captureSourceRevision = $fullSourceRevision
    captureOriginRevision = $captureSource.originRevision
    captureCargoLockSha256 = $captureSource.cargoLockSha256
    captureExecutable = $captureSource.executable
    captureSha256 = $captureSha256
    captureBundled = -not $SkipCapture
    # Compatibility aliases, not the revision of maintained capture source.
    glazierRevision = $captureSource.originRevision
    glazierSha256 = $captureSha256
    glazierBundled = -not $SkipCapture
    publicRelease = [bool]$PublicRelease
    pluginTests = [bool]$PluginTests
    backendTests = [bool]$Tests
    nativeVersion = $sourceVersion
    versionFileSha256 = $versionFileSha256
    supervisor = $supervisor
    nativeInputs = $nativeInputs
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
    backendRevision = (& git -C $backendPath rev-parse HEAD).Trim()
    backendMode = $backendMode
    pinnedBackendRevision = $pinnedBackendRevision
    lockBackendRevision = $sourceLock.quickshell.revision
    m3shapesRevision = $m3shapesRevision
    captureSourcePath = $captureSource.relativePath
    captureSourceRevision = $fullSourceRevision
    captureOriginRevision = $captureSource.originRevision
    captureCargoLockSha256 = $captureSource.cargoLockSha256
    captureExecutable = $captureSource.executable
    captureBundled = -not $SkipCapture
    captureSha256 = $captureSha256
    glazierRevision = $captureSource.originRevision
    glazierBundled = -not $SkipCapture
    glazierSha256 = $captureSha256
    publicRelease = [bool]$PublicRelease
    builtAtUtc = [DateTime]::UtcNow.ToString('o')
} | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $logRoot 'toolchain.json') -Encoding UTF8
Write-Host "Built backend, portable plugins and Caelestia capture. Evidence: $logRoot"
