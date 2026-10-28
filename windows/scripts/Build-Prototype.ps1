[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QtPrefix,
    [Parameter(Mandatory)][string]$LlvmBin,
    [Parameter(Mandatory)][string]$Cli11Include,
    [string]$ToolsBin,
    [string]$BuildRoot,
    [ValidateRange(1, 64)][int]$Jobs = 4
)

$ErrorActionPreference = 'Stop'
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

# Enter only this process's VS environment; do not change the user's PATH.
$installer = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer'
$vswhere = Join-Path $installer 'vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere)) { throw 'Visual Studio Build Tools with C++ tools are required.' }
$vsRoot = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vsRoot) { throw 'No Visual Studio installation with the x64 C++ tools was found.' }
$env:PATH = "$installer;$env:PATH"
& (Join-Path $vsRoot 'Common7\Tools\Launch-VsDevShell.ps1') -Arch amd64 -HostArch amd64 -SkipAutomaticLocation
$env:PATH = "$LlvmBin;$QtPrefix\bin;$env:PATH"
if ($ToolsBin) { $env:PATH = "$ToolsBin;$env:PATH" }
$manifestTool = Join-Path $env:WindowsSdkDir "bin\$($env:WindowsSDKVersion.TrimEnd('\'))\x64\mt.exe"
if (-not (Test-Path -LiteralPath $manifestTool)) { throw 'Windows SDK manifest tool is required.' }

$report = & (Join-Path $PSScriptRoot 'Test-Environment.ps1') -QtPrefix $QtPrefix -Json -Strict
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

$common = @('-G', 'Ninja', '-DCMAKE_BUILD_TYPE=Release', '-DCMAKE_CXX_COMPILER=clang-cl',
    '-DCMAKE_LINKER_TYPE=MSVC', "-DCMAKE_MT:FILEPATH=$manifestTool", "-DCMAKE_PREFIX_PATH=$QtPrefix")
Invoke-BuildCommand 'configure-backend' (@('-S', "$repoRoot\windows\deps\quickshell",
    '-B', "$BuildRoot\quickshell") + $common + @('-DCMAKE_C_COMPILER=clang-cl',
    "-DCLI11_INCLUDE_DIR=$Cli11Include", '-DCRASH_HANDLER=OFF', '-DBUILD_TESTING=OFF', '-DINSTALL_QMLDIR=qml',
    '-DQS_AUTOSTART_NAME=CaelestiaPrototype', '-DQS_AUTOSTART_ARGS=',
    '-DQS_AUTOSTART_DESCRIPTION=Caelestia compatibility prototype'))
Invoke-BuildCommand 'build-backend' @('--build', "$BuildRoot\quickshell", '--target', 'quickshell', '--parallel', "$Jobs")
Invoke-BuildCommand 'build-brightness-probe' @('--build', "$BuildRoot\quickshell", '--target', 'brightness-probe', '--parallel', "$Jobs")
Invoke-BuildCommand 'configure-m3shapes' (@('-S', $m3shapesPath, '-B', "$BuildRoot\m3shapes") + $common +
    @('-DINSTALL_QMLDIR=qml', "-DCMAKE_INSTALL_PREFIX=$installRoot", '-DM3SHAPES_BUILD_EXAMPLES=OFF'))
Invoke-BuildCommand 'build-m3shapes' @('--build', "$BuildRoot\m3shapes", '--parallel', "$Jobs")
Invoke-BuildCommand 'install-m3shapes' @('--install', "$BuildRoot\m3shapes")
# Resolve the version and revision up front so configure works without a reachable git tag or git metadata (#114).
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
$sourceVersion = "$sourceVersion".Trim() -replace '^v', ''
$sourceRevision = if ($shortRevExit -eq 0 -and $rawShortRevision) { "$rawShortRevision".Trim() } else { 'unknown' }
if (-not $sourceRevision) { $sourceRevision = 'unknown' }
$fullSourceRevision = if ($fullRevExit -eq 0 -and $rawFullRevision) { "$rawFullRevision".Trim() } else { $sourceRevision }

Invoke-BuildCommand 'configure-plugins' (@('-S', $repoRoot, '-B', "$BuildRoot\caelestia") + $common +
    @('-DCAELESTIA_PORTABLE_UI=ON', '-DENABLE_MODULES=plugin', '-DINSTALL_QMLDIR=qml',
    "-DCMAKE_INSTALL_PREFIX=$installRoot", "-DVERSION=$sourceVersion", "-DGIT_REVISION=$sourceRevision"))
Invoke-BuildCommand 'build-plugins' @('--build', "$BuildRoot\caelestia", '--parallel', "$Jobs")
Invoke-BuildCommand 'install-plugins' @('--install', "$BuildRoot\caelestia")

[ordered]@{
    sourceRevision = $fullSourceRevision
    sourceDirty = [bool]$rawDirty
    backendRevision = (& git -C "$repoRoot\windows\deps\quickshell" rev-parse HEAD).Trim()
    m3shapesRevision = $m3shapesRevision
    windowsSdkVersion = $env:WindowsSDKVersion
    msvcToolsVersion = $env:VCToolsVersion
    qtVersion = (& "$QtPrefix\bin\qtpaths.exe" --qt-version).Trim()
    qtPrefix = $QtPrefix
    compiler = (& "$LlvmBin\clang-cl.exe" --version | Select-Object -First 1)
    cmake = (& cmake --version | Select-Object -First 1)
    ninja = (& ninja --version)
    windows = [Environment]::OSVersion.VersionString
    builtAtUtc = [DateTime]::UtcNow.ToString('o')
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $logRoot 'build.json') -Encoding UTF8
Write-Host "Built backend and portable plugins. Evidence: $logRoot"
