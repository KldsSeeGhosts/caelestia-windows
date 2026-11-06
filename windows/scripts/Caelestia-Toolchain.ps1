# Shared by local builds, hosted preparation, prerequisite checks and packaging.
# Dot-sourcing this file never installs tools or changes the environment.
function Get-CaelestiaToolchain {
    $path = Join-Path $PSScriptRoot '..\toolchain.json'
    $spec = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
    if ($spec.schemaVersion -ne 1 -or $spec.id -notmatch '^windows-x64-v[0-9]+$') {
        throw 'Unsupported windows/toolchain.json. Restore the reviewed specification.'
    }
    return $spec
}

function Get-CaelestiaToolchainHash {
    # Normalize newlines so a Windows checkout and a Linux-created archive agree.
    $paths = @('..\toolchain.json', '..\toolchain\python-bootstrap.lock.txt', '..\toolchain\python-tools.lock.txt')
    $text = (@($paths | ForEach-Object {
        (Get-Content -LiteralPath (Join-Path $PSScriptRoot $_) -Raw).Replace("`r`n", "`n")
    }) -join "`n")
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($text)))).Replace('-', '').ToLowerInvariant() }
    finally { $sha.Dispose() }
}

function Assert-CaelestiaToolchainReceipt {
    param([Parameter(Mandatory)]$Receipt, $Spec = (Get-CaelestiaToolchain))
    if ($Receipt.schemaVersion -ne 1 -or $Receipt.contractId -cne $Spec.id -or
        $Receipt.contractSha256 -cne (Get-CaelestiaToolchainHash)) {
        throw 'Toolchain receipt is missing or belongs to another specification. Rebuild with windows/scripts/Build-Prototype.ps1.'
    }
    foreach ($name in @('vcToolsVersion', 'windowsSdkVersion', 'clangVersion', 'clangTarget',
        'rustVersion', 'cargoVersion', 'rustTarget', 'qtVersion', 'cmakeVersion', 'ninjaVersion', 'cli11Version')) {
        if ([string]$Receipt.$name -cne [string]$Spec.$name) {
            throw "Unsupported toolchain $name '$($Receipt.$name)'; required '$($Spec.$name)'. Install the exact prerequisite in windows/NATIVE-BUILD.md and rebuild."
        }
    }
    if ($Receipt.runtimeMinimum -cne $Spec.runtimeMinimum -or
        $Receipt.vcToolsVersion -notmatch '^\d+\.\d+\.\d+$' -or
        [version]$Receipt.vcToolsVersion -gt [version]$Spec.runtimeMinimum) {
        throw 'The build toolset exceeds or disagrees with the reviewed system runtime prerequisite. A runtime upgrade requires explicit qualification.'
    }
}

function Assert-CaelestiaBuildToolchain {
    param([Parameter(Mandatory)]$Build)
    Assert-CaelestiaToolchainReceipt $Build.toolchain
    # Retain the existing top-level fields for build consumers, but do not let
    # an incompatible legacy field evade the release guard.
    foreach ($pair in @(
        @('msvcToolsVersion', 'vcToolsVersion'), @('windowsSdkVersion', 'windowsSdkVersion'),
        @('qtVersion', 'qtVersion'))) {
        if ([string]$Build.($pair[0]) -cne [string]$Build.toolchain.($pair[1])) {
            throw "Build receipt $($pair[0]) disagrees with its toolchain. Rebuild before packaging."
        }
    }
}

function Assert-CaelestiaDownload {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Sha256)
    if ($Sha256 -notmatch '^[a-f0-9]{64}$' -or -not (Test-Path -LiteralPath $Path -PathType Leaf) -or
        (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ine $Sha256) {
        throw "Toolchain download checksum mismatch or missing archive: $(Split-Path -Leaf $Path). Remove that cached archive and rerun Prepare-Toolchain.ps1. Do not bypass integrity checks."
    }
}

function Select-CaelestiaVisualStudio {
    param([Parameter(Mandatory)]$Installations, $Spec = (Get-CaelestiaToolchain))
    # The supplier installation's banner is not the selected VC toolset.
    foreach ($instance in @($Installations | Sort-Object installationVersion, installationPath)) {
        $vc = Join-Path $instance.installationPath "VC\Tools\MSVC\$($Spec.vcToolsVersion)"
        if (Test-Path -LiteralPath "$vc\bin\Hostx64\x64\cl.exe" -PathType Leaf) { return $instance }
    }
    throw "Missing VC tools $($Spec.vcToolsVersion) (x64). In Visual Studio Installer add MSVC v143 VS 2022 C++ x64/x86 tools, version 14.44, component $($Spec.vcComponent). The exact VC/Tools/MSVC/$($Spec.vcToolsVersion) directory is required; the latest VS banner is not a substitute."
}

function Enter-CaelestiaToolchain {
    param([Parameter(Mandatory)][string]$QtPrefix, [Parameter(Mandatory)][string]$LlvmBin, [string]$ToolsBin)
    $spec = Get-CaelestiaToolchain
    if ($env:OS -ne 'Windows_NT' -or -not [Environment]::Is64BitProcess) { throw 'The supported toolchain requires native x64 Windows PowerShell.' }
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) { throw 'Install Visual Studio C++ Build Tools and the exact prerequisites in windows/NATIVE-BUILD.md.' }
    $instances = & $vswhere -all -products '*' -requires $spec.vcComponent -format json | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) { throw 'vswhere could not enumerate C++ Build Tools. Repair the Visual Studio Installer.' }
    $instance = Select-CaelestiaVisualStudio $instances $spec
    $vcRoot = Join-Path $instance.installationPath "VC\Tools\MSVC\$($spec.vcToolsVersion)"
    foreach ($file in @('bin\Hostx64\x64\link.exe', 'include\vcruntime.h', 'lib\x64\msvcrt.lib', 'lib\x64\vcruntime.lib')) {
        if (-not (Test-Path -LiteralPath (Join-Path $vcRoot $file) -PathType Leaf)) {
            throw "Incomplete VC tools $($spec.vcToolsVersion) x64 ($file). Repair the exact MSVC v143 optional component in Visual Studio Installer."
        }
    }
    $sdkRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10'
    foreach ($file in @("Include\$($spec.windowsSdkVersion)\um\Windows.h",
        "Lib\$($spec.windowsSdkVersion)\um\x64\kernel32.lib", "bin\$($spec.windowsSdkVersion)\x64\mt.exe")) {
        if (-not (Test-Path -LiteralPath (Join-Path $sdkRoot $file) -PathType Leaf)) {
            throw "Missing Windows SDK $($spec.windowsSdkVersion) x64 ($file). Install component Microsoft.VisualStudio.Component.Windows11SDK.26100; a newer SDK alone does not satisfy this contract."
        }
    }
    # Import just this process's selected environment. Launch-VsDevShell.ps1
    # does not accept toolset/SDK selectors on all supported VS installations.
    $devModule = Join-Path $instance.installationPath 'Common7\Tools\Microsoft.VisualStudio.DevShell.dll'
    $env:PATH = "$(Split-Path -Parent $vswhere);$env:PATH"
    Import-Module -Name $devModule -ErrorAction Stop
    Enter-VsDevShell -VsInstallPath $instance.installationPath -SkipAutomaticLocation -SkipExistingEnvironmentVariables `
        -DevCmdArguments "-arch=x64 -host_arch=x64 -vcvars_ver=$($spec.vcToolsVersion) -winsdk=$($spec.windowsSdkVersion)" | Out-Null
    if ($env:VCToolsVersion.TrimEnd('\') -cne $spec.vcToolsVersion -or
        $env:WindowsSDKVersion.TrimEnd('\') -cne $spec.windowsSdkVersion -or
        $env:VSCMD_ARG_TGT_ARCH -ne 'x64' -or $env:VSCMD_ARG_HOST_ARCH -ne 'x64') {
        throw "Visual Studio did not select VC $($spec.vcToolsVersion) and SDK $($spec.windowsSdkVersion). Repair these exact optional components; no compilation was started."
    }
    $env:PATH = "$LlvmBin;$QtPrefix\bin;$env:PATH"
    if ($ToolsBin) { $env:PATH = "$ToolsBin;$env:PATH" }
    return $instance
}

function Get-CaelestiaToolOutput {
    param([string]$Name, [string[]]$Arguments)
    $command = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $command) { throw "Missing tool $Name. Run Prepare-Toolchain.ps1 or install the exact prerequisites in windows/NATIVE-BUILD.md." }
    $output = @(& $command.Source @Arguments)
    if ($LASTEXITCODE -ne 0) { throw "$Name could not report its version. Repair the prerequisite before compiling." }
    return ($output -join "`n").Trim()
}

function Get-CaelestiaActualToolchain {
    param([Parameter(Mandatory)][string]$QtPrefix, [string]$Cli11Include)
    $spec = Get-CaelestiaToolchain
    $clang = Get-CaelestiaToolOutput 'clang-cl.exe' @('--version')
    $rust = Get-CaelestiaToolOutput 'rustc.exe' @('-vV')
    $cargo = Get-CaelestiaToolOutput 'cargo.exe' @('--version')
    $cmake = Get-CaelestiaToolOutput 'cmake.exe' @('--version')
    $ninja = Get-CaelestiaToolOutput 'ninja.exe' @('--version')
    $qt = Get-CaelestiaToolOutput "$QtPrefix\bin\qtpaths.exe" @('--qt-version')
    $rustTarget = [regex]::Match($rust, '(?m)^host: (.+)$').Groups[1].Value.Trim()
    # Cargo is invoked with --target explicitly, and must have that stdlib.
    $targetLib = Get-CaelestiaToolOutput 'rustc.exe' @('--print', 'target-libdir', '--target', $spec.rustTarget)
    if (-not (Test-Path -LiteralPath $targetLib -PathType Container) -or
        -not @(Get-ChildItem -LiteralPath $targetLib -Filter 'libstd-*.rlib' -File).Count) {
        throw "Missing Rust $($spec.rustVersion) target $($spec.rustTarget). Run rustup target add --toolchain $($spec.rustVersion) $($spec.rustTarget)."
    }
    if (-not $Cli11Include) { throw 'Supply -Cli11Include for the exact CLI11 headers when validating the toolchain.' }
    $cliHeader = Join-Path $Cli11Include 'CLI\Version.hpp'
    if (-not (Test-Path -LiteralPath $cliHeader)) { throw 'Missing CLI11 Version.hpp. Install the hash-verified CLI11 archive in windows/toolchain.json.' }
    $cli = [regex]::Match((Get-Content -LiteralPath $cliHeader -Raw), '#define CLI11_VERSION "([^"]+)"').Groups[1].Value
    $vcVersion = [string]$env:VCToolsVersion
    $sdkVersion = [string]$env:WindowsSDKVersion
    $vcCompiler = if ($env:VCToolsInstallDir) { Join-Path $env:VCToolsInstallDir 'bin\Hostx64\x64\cl.exe' } else { '' }
    $receipt = [pscustomobject][ordered]@{
        schemaVersion = 1
        contractId = $spec.id
        contractSha256 = Get-CaelestiaToolchainHash
        runtimeMinimum = $spec.runtimeMinimum
        vcToolsVersion = $vcVersion.TrimEnd('\')
        # Servicing binary version is distinct from VC/Tools/MSVC directory.
        vcCompilerFileVersion = $(if (Test-Path -LiteralPath $vcCompiler -PathType Leaf) { (Get-Item -LiteralPath $vcCompiler).VersionInfo.FileVersion } else { '' })
        windowsSdkVersion = $sdkVersion.TrimEnd('\')
        clangVersion = [regex]::Match($clang, '(?m)^clang version ([0-9.]+)').Groups[1].Value
        clangTarget = [regex]::Match($clang, '(?m)^Target: (.+)$').Groups[1].Value.Trim()
        rustVersion = [regex]::Match($rust, '(?m)^release: (.+)$').Groups[1].Value.Trim()
        rustTarget = $rustTarget
        rustCommit = [regex]::Match($rust, '(?m)^commit-hash: (.+)$').Groups[1].Value.Trim()
        cargoVersion = [regex]::Match($cargo, '^cargo ([0-9.]+)').Groups[1].Value
        qtVersion = $qt
        cmakeVersion = [regex]::Match($cmake, '^cmake version ([0-9.]+)').Groups[1].Value
        ninjaVersion = $ninja
        cli11Version = $cli
    }
    Assert-CaelestiaToolchainReceipt $receipt $spec
    return $receipt
}

function Select-CaelestiaRust {
    # Resolve installed compilers without an implicit rustup download, override,
    # or default change. A preinstalled alias is usable only after its actual
    # compiler and Cargo versions have passed the exact contract.
    $spec = Get-CaelestiaToolchain
    $rustup = Get-Command rustup.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $rustup) { throw "Install rustup and Rust $($spec.rustVersion) with target $($spec.rustTarget), as documented in windows/NATIVE-BUILD.md." }
    $installed = @(& $rustup.Source toolchain list)
    if ($LASTEXITCODE -ne 0) { throw 'Cannot enumerate installed Rust toolchains. No authentication or settings changes were attempted.' }
    foreach ($entry in $installed) {
        $name = ($entry -split '\s+')[0]
        $rust = @(& $rustup.Source run $name rustc --version)
        $cargo = @(& $rustup.Source run $name cargo --version)
        if (($rust -join '') -notmatch ('^rustc ' + [regex]::Escape($spec.rustVersion) + ' ') -or
            ($cargo -join '') -notmatch ('^cargo ' + [regex]::Escape($spec.cargoVersion) + ' ')) { continue }
        $path = (& $rustup.Source which --toolchain $name rustc).Trim()
        if ($LASTEXITCODE -ne 0) { continue }
        $bin = Split-Path -Parent $path
        $env:RUSTUP_TOOLCHAIN = Split-Path -Parent $bin
        $env:PATH = "$bin;$env:PATH"
        # Prevent Cargo from picking a caller-supplied different rustc.
        $env:RUSTC = $path
        $env:CARGO_BUILD_TARGET = $spec.rustTarget
        return
    }
    throw "Missing supported Rust/Cargo $($spec.rustVersion). Run: rustup toolchain install $($spec.rustVersion)-$($spec.rustTarget) --profile minimal --target $($spec.rustTarget). The build never installs or updates Rust automatically."
}
