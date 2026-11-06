[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourceRoot,
    [Parameter(Mandatory)][string]$QtPrefix,
    [Parameter(Mandatory)][string]$BuildRoot,
    [string]$PayloadRoot
)
$ErrorActionPreference = 'Stop'
$BuildRoot = [IO.Path]::GetFullPath($BuildRoot)
if (Test-Path -LiteralPath $BuildRoot) { throw 'Native probe output must be a new external directory. Reuse without rebuilding through the paired runner.' }
foreach ($root in @($SourceRoot, $QtPrefix, $PayloadRoot, (Join-Path $PSScriptRoot '..\..\..'))) {
    if (-not $root) { continue }
    $resolved = [IO.Path]::GetFullPath($root).TrimEnd('\')
    if ($BuildRoot -eq $resolved -or $BuildRoot.StartsWith($resolved + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Native probe output must not be inside a source, Qt or measured payload root.'
    }
}
if (@(& git -C "$SourceRoot\windows\deps\quickshell" status --porcelain).Count -ne 0 -or $LASTEXITCODE -ne 0) {
    throw 'The measured backend must be a clean checked-out revision.'
}
(Get-Process -Id $PID).PriorityClass = 'BelowNormal'
Add-Type -Name BenchBuildErrorMode -Namespace W -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint SetErrorMode(uint m);'
[W.BenchBuildErrorMode]::SetErrorMode(0x8003) | Out-Null
$installer = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer'
$vsRoot = & "$installer\vswhere.exe" -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
$env:PATH = "$installer;$env:PATH"
& "$vsRoot\Common7\Tools\Launch-VsDevShell.ps1" -Arch amd64 -HostArch amd64 -SkipAutomaticLocation | Out-Null
$toolPaths = @()
if ($PayloadRoot -and (Test-Path -LiteralPath "$PayloadRoot\quickshell\CMakeCache.txt")) {
    $cache = [IO.File]::ReadAllLines("$PayloadRoot\quickshell\CMakeCache.txt")
    foreach ($key in @('CMAKE_CXX_COMPILER', 'CMAKE_CXX_COMPILER_AR', 'CMAKE_MAKE_PROGRAM', 'CMAKE_COMMAND')) {
        $line = $cache | Where-Object { $_ -match ('^' + $key + ':[^=]+=') } | Select-Object -First 1
        if ($line) {
            $file = $line.Substring($line.IndexOf('=') + 1)
            if (Test-Path -LiteralPath $file -PathType Leaf) { $toolPaths += Split-Path -Parent $file }
        }
    }
}
$env:PATH = ((@($toolPaths) + @("$QtPrefix\bin", $env:PATH)) -join ';')
foreach ($tool in @('cmake', 'ninja', 'clang-cl')) {
    if (-not (Get-Command $tool -CommandType Application -ErrorAction SilentlyContinue)) {
        throw "$tool is required. Supply a Build-Prototype payload root or put its toolchain on PATH."
    }
}
$mt = Join-Path $env:WindowsSdkDir "bin\$($env:WindowsSDKVersion.TrimEnd('\'))\x64\mt.exe"
& cmake -S "$PSScriptRoot\..\native" -B $BuildRoot -G Ninja -DCMAKE_BUILD_TYPE=Release `
    -DCMAKE_CXX_COMPILER=clang-cl -DCMAKE_LINKER_TYPE=MSVC "-DCMAKE_MT:FILEPATH=$mt" `
    "-DCMAKE_PREFIX_PATH=$QtPrefix" "-DBACKEND_ROOT=$SourceRoot\windows\deps\quickshell"
if ($LASTEXITCODE) { throw 'Benchmark configuration failed.' }
& cmake --build $BuildRoot --parallel 2
if ($LASTEXITCODE) { throw 'Benchmark compilation failed.' }
# Match the backend fixtures' plain asInvoker manifest.
& $mt -nologo -manifest "$SourceRoot\windows\deps\quickshell\src\windows\test\test-as-invoker.manifest" "-outputresource:$BuildRoot\native-bench.exe;#1"
if ($LASTEXITCODE) { throw 'Benchmark manifest embedding failed.' }
$cacheLines = [IO.File]::ReadAllLines("$BuildRoot\CMakeCache.txt")
function Get-ActualBuildTool([string]$Key, [switch]$FileVersion) {
    $line = @($cacheLines | Where-Object { $_ -match ('^' + $Key + ':[^=]+=') })
    if ($line.Count -ne 1) { throw "Missing actual configured tool: $Key" }
    $path = $line[0].Substring($line[0].IndexOf('=') + 1)
    $path = (Resolve-Path -LiteralPath $path).Path
    if ($FileVersion) { $version = (Get-Item -LiteralPath $path).VersionInfo.FileVersion }
    else {
        $version = (@(& $path --version 2>&1) -join "`n").Trim()
        if ($LASTEXITCODE) { throw "Cannot identify configured tool: $Key" }
    }
    if (-not $version) { throw "Configured tool has no actual version identity: $Key" }
    return [ordered]@{path=$path; sha256=(Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant(); version=$version}
}
[ordered]@{
    schemaVersion=2
    privacy='PRIVATE-local-evidence; never upload raw receipts automatically'
    backendRevision=(& git -C "$SourceRoot\windows\deps\quickshell" rev-parse HEAD).Trim()
    probeSourceSha256=(Get-FileHash "$PSScriptRoot\..\native\main.cpp").Hash.ToLowerInvariant()
    cmakeSha256=(Get-FileHash "$PSScriptRoot\..\native\CMakeLists.txt").Hash.ToLowerInvariant()
    executableSha256=(Get-FileHash "$BuildRoot\native-bench.exe").Hash.ToLowerInvariant()
    toolchain=[ordered]@{
        compiler=(Get-ActualBuildTool 'CMAKE_CXX_COMPILER')
        linker=(Get-ActualBuildTool 'CMAKE_LINKER' -FileVersion)
        cmake=(Get-ActualBuildTool 'CMAKE_COMMAND')
        ninja=(Get-ActualBuildTool 'CMAKE_MAKE_PROGRAM')
    }
} | ConvertTo-Json -Depth 8 | Set-Content "$BuildRoot\probe-build.json" -Encoding UTF8
