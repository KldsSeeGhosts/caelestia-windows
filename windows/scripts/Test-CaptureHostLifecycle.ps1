[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$BuildRoot,
    [string]$QtPrefix = "$env:LOCALAPPDATA/caelestia-dev/Qt/6.11.2/msvc2022_64",
    [string]$LlvmBin = "$env:LOCALAPPDATA/caelestia-dev/clang+llvm-20.1.8-x86_64-pc-windows-msvc/bin",
    [string]$ToolsBin = "$env:LOCALAPPDATA/caelestia-dev/tools/Scripts",
    [string]$VsRoot = "${env:ProgramFiles(x86)}/Microsoft Visual Studio/2022/BuildTools"
)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path -LiteralPath "$PSScriptRoot/../..").Path
$output = [IO.Path]::GetFullPath($BuildRoot).TrimEnd('\', '/')
if ($output -eq [IO.Path]::GetPathRoot($output) -or $output -eq $repo -or
    $output -eq [Environment]::GetFolderPath('UserProfile')) { throw 'An exclusive fixture output directory is required.' }
$owner = Join-Path $output 'capture-lifecycle-owner.txt'
if (Test-Path -LiteralPath $output) {
    if (-not (Test-Path -LiteralPath $owner) -or (Get-Content -LiteralPath $owner -Raw).Trim() -ne $repo) {
        throw 'Output directory exists without this worktree ownership marker.'
    }
} else {
    New-Item -ItemType Directory -Path $output | Out-Null
    $repo | Set-Content -LiteralPath $owner -Encoding UTF8
}
$logs = Join-Path $output 'logs'
New-Item -ItemType Directory -Force -Path $logs | Out-Null
$env:PATH = "${env:ProgramFiles(x86)}/Microsoft Visual Studio/Installer;$env:PATH"
Import-Module (Join-Path $VsRoot 'Common7/Tools/Microsoft.VisualStudio.DevShell.dll')
Enter-VsDevShell -VsInstallPath $VsRoot -SkipAutomaticLocation `
    -DevCmdArguments '-arch=x64 -host_arch=x64 -vcvars_ver=14.44 -winsdk=10.0.26100.0'
if ($env:VCToolsVersion.TrimEnd('\') -ne '14.44.35207' -or
    $env:WindowsSDKVersion.TrimEnd('\') -ne '10.0.26100.0') { throw 'Unexpected fixture toolchain.' }
$env:PATH = "$ToolsBin;$LlvmBin;$QtPrefix/bin;$env:PATH"
$env:QT_QPA_PLATFORM = 'offscreen'
$env:QT_QUICK_BACKEND = 'software'
$env:QT_PLUGIN_PATH = "$QtPrefix/plugins"
$env:QML_IMPORT_PATH = "$QtPrefix/qml"
$env:QML2_IMPORT_PATH = "$QtPrefix/qml"
$env:QML_DISABLE_DISK_CACHE = '1'
function Run([string]$Name, [string]$Program, [string[]]$Arguments) {
    $Arguments | ConvertTo-Json | Set-Content -LiteralPath "$logs/$Name-command.json"
    & $Program @Arguments 2>&1 | ForEach-Object { "$_" } | Tee-Object -FilePath "$logs/$Name.log"
    if ($LASTEXITCODE -ne 0) { throw "$Name failed with $LASTEXITCODE. See $logs/$Name.log" }
}
Run 'configure' 'cmake' @('-S', "$repo/plugin/src/Caelestia/Windows/test", '-B', "$output/native",
    '-G', 'Ninja', '-DCMAKE_BUILD_TYPE=Release', '-DCMAKE_CXX_COMPILER=clang-cl',
    '-DCMAKE_LINKER_TYPE=MSVC', "-DCMAKE_PREFIX_PATH=$QtPrefix")
Run 'build' 'cmake' @('--build', "$output/native", '--parallel', '2')
Run 'native' "$output/native/capture-host-tests.exe" @('-o', "$logs/native.txt,txt", '-o', "$logs/native.xml,junitxml")
[xml]$results = Get-Content -LiteralPath "$logs/native.xml" -Raw
$suite = $results.testsuite
if ([int]$suite.tests -lt 25 -or [int]$suite.failures -ne 0 -or [int]$suite.errors -ne 0 -or [int]$suite.skipped -ne 0) {
    throw 'Missing, failed or skipped native lifecycle cases.'
}
Run 'node' 'node' @("$repo/windows/tests/GlazierRecorderLogic.test.js")
[ordered]@{
    shell = (& git -C $repo rev-parse HEAD).Trim()
    dirty = [bool](& git -C $repo status --porcelain)
    backend = (& git -C "$repo/windows/deps/quickshell" rev-parse HEAD).Trim()
    glazier = (& git -C "$repo/windows/deps/glazier" rev-parse HEAD).Trim()
    m3shapes = (& git -C "$repo/windows/deps/m3shapes" rev-parse HEAD).Trim()
    qt = (& "$QtPrefix/bin/qtpaths.exe" --qt-version).Trim()
    vcTools = $env:VCToolsVersion
    windowsSdk = $env:WindowsSDKVersion
    nativeTests = [int]$suite.tests
    nativeFailures = [int]$suite.failures
    nativeSkipped = [int]$suite.skipped
    nativeFixtureSha256 = (Get-FileHash -LiteralPath "$output/native/capture-host-tests.exe" -Algorithm SHA256).Hash
    nativeChildSha256 = (Get-FileHash -LiteralPath "$output/native/capture-host-child.exe" -Algorithm SHA256).Hash
    evidence = 'fake native ops + unchanged offscreen QML services + owned hidden Win32 child; not desktop capture/recording'
} | ConvertTo-Json | Set-Content -LiteralPath "$logs/receipt.json"
Get-Content -LiteralPath "$logs/native.txt"
Get-Content -LiteralPath "$logs/receipt.json"
