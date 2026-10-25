[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QtPrefix,
    [Parameter(Mandatory)][string]$LlvmBin,
    [string]$ToolsBin,
    [string]$BuildRoot
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$backend = Join-Path $repoRoot 'windows\deps\quickshell'
if (-not $BuildRoot) { $BuildRoot = Join-Path $repoRoot 'windows\.local\build\media-backend-tests' }
$BuildRoot = [IO.Path]::GetFullPath($BuildRoot)
New-Item -ItemType Directory -Force -Path $BuildRoot | Out-Null
$installer = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer'
$vsRoot = & "$installer\vswhere.exe" -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vsRoot) { throw 'Visual Studio x64 C++ tools are required.' }
$env:PATH = "$installer;$env:PATH"
& "$vsRoot\Common7\Tools\Launch-VsDevShell.ps1" -Arch amd64 -HostArch amd64 -SkipAutomaticLocation
$env:PATH = "$LlvmBin;$QtPrefix\bin;$env:PATH"
if ($ToolsBin) { $env:PATH = "$ToolsBin;$env:PATH" }
$manifestTool = Join-Path $env:WindowsSdkDir "bin\$($env:WindowsSDKVersion.TrimEnd('\'))\x64\mt.exe"
if (-not (Test-Path -LiteralPath $manifestTool)) { throw 'Windows SDK manifest tool is required.' }

function Invoke-Recorded([string]$Name, [string[]]$CommandArguments) {
    $CommandArguments | ConvertTo-Json | Set-Content -LiteralPath "$BuildRoot\$Name-command.json" -Encoding UTF8
    $ErrorActionPreference = 'Continue'
    & cmake @CommandArguments 2>&1 | ForEach-Object { "$_" } |
        Tee-Object -FilePath "$BuildRoot\$Name.log" | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "$Name failed." }
}

# Lifecycle status fixtures. No GSMTC worker, hardware read or playback
# write is performed. Microsoft link.exe avoids LLVM 20's Qt-manifest bug.
Invoke-Recorded 'configure' @('-S', "$backend\src\windows\test", '-B', $BuildRoot, '-G', 'Ninja',
    '-DCMAKE_BUILD_TYPE=Release', '-DCMAKE_CXX_COMPILER=clang-cl', '-DCMAKE_LINKER_TYPE=MSVC',
    "-DCMAKE_MT:FILEPATH=$manifestTool", "-DCMAKE_PREFIX_PATH=$QtPrefix")
Invoke-Recorded 'build' @('--build', $BuildRoot, '--target', 'mpris_status_test', '--parallel', '4')
$info = New-Object Diagnostics.ProcessStartInfo
$info.FileName = Join-Path $BuildRoot 'mpris_status_test.exe'
$info.Arguments = '-o "' + "$BuildRoot\fixtures.txt" + '",txt'
$info.UseShellExecute = $false
$info.CreateNoWindow = $true
$process = [Diagnostics.Process]::Start($info)
$timedOut = -not $process.WaitForExit(15000)
if ($timedOut) {
    $process.Kill()
    $process.WaitForExit()
}
$text = $(if (Test-Path -LiteralPath "$BuildRoot\fixtures.txt") { Get-Content -LiteralPath "$BuildRoot\fixtures.txt" -Raw } else { '' })
$passed = -not $timedOut -and $process.ExitCode -eq 0 -and $text -match 'Totals: \d+ passed, 0 failed'
$result = [ordered]@{
    passed = $passed; timedOut = $timedOut; exitCode = $process.ExitCode
    backendRevision = (& git -C $backend rev-parse HEAD).Trim()
    backendDirty = [bool](& git -C $backend status --porcelain)
    qtVersion = (& "$QtPrefix\bin\qtpaths.exe" --qt-version).Trim()
    compiler = (& "$LlvmBin\clang-cl.exe" --version | Select-Object -First 1)
    manifestTool = $manifestTool; linker = 'MSVC'
    command = $info.FileName; arguments = $info.Arguments
    executableSha256 = (Get-FileHash -LiteralPath $info.FileName).Hash
    totals = ([regex]::Match($text, 'Totals: [^\r\n]+')).Value
}
$result | ConvertTo-Json | Set-Content -LiteralPath "$BuildRoot\result.json" -Encoding UTF8
$result | ConvertTo-Json
if (-not $passed) { throw "Native media status fixtures failed. See $BuildRoot\fixtures.txt." }
