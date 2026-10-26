[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QtPrefix,
    [Parameter(Mandatory)][string]$LlvmBin,
    [string]$ToolsBin,
    [string]$BuildRoot
)

# Notification-mirror consent backend fixtures. The WinRT listener, app
# activation and window lookup are faked through the consent seams, so the
# tests never prompt for notification-listener access, activate an app or
# remove a real Windows notification. The mpris/upower status fixtures are
# rebuilt and re-run alongside them as regressions.
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$backend = Join-Path $repoRoot 'windows\deps\quickshell'
if (-not $BuildRoot) { $BuildRoot = Join-Path $repoRoot 'windows\.local\build\notifications-backend-tests' }
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

# Microsoft link.exe avoids LLVM 20's Qt-manifest bug.
Invoke-Recorded 'configure' @('-S', "$backend\src\windows\test", '-B', $BuildRoot, '-G', 'Ninja',
    '-DCMAKE_BUILD_TYPE=Release', '-DCMAKE_CXX_COMPILER=clang-cl', '-DCMAKE_LINKER_TYPE=MSVC',
    "-DCMAKE_MT:FILEPATH=$manifestTool", "-DCMAKE_PREFIX_PATH=$QtPrefix")
Invoke-Recorded 'build' @('--build', $BuildRoot, '--target',
    'notification_mirror_consent_test', 'mpris_status_test', 'upower_status_test', '--parallel', '4')
$tests = @(
    foreach ($target in @('notification_mirror_consent_test', 'mpris_status_test', 'upower_status_test')) {
        $log = Join-Path $BuildRoot "$target.txt"
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = Join-Path $BuildRoot "$target.exe"
        $info.Arguments = '-o "' + $log + '",txt'
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $process = [Diagnostics.Process]::Start($info)
        $timedOut = -not $process.WaitForExit(30000)
        if ($timedOut) {
            $process.Kill()
            $process.WaitForExit()
        }
        $text = $(if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log -Raw } else { '' })
        [ordered]@{
            target = $target
            passed = -not $timedOut -and $process.ExitCode -eq 0 -and $text -match 'Totals: \d+ passed, 0 failed'
            timedOut = $timedOut; exitCode = $process.ExitCode
            command = $info.FileName; arguments = $info.Arguments
            executableSha256 = (Get-FileHash -LiteralPath $info.FileName).Hash
            totals = ([regex]::Match($text, 'Totals: [^\r\n]+')).Value
        }
    }
)
$passed = @($tests | Where-Object { -not $_.passed }).Count -eq 0
$result = [ordered]@{
    passed = $passed
    tests = $tests
    totals = ($tests | ForEach-Object { $_.totals }) -join '; '
    backendRevision = (& git -C $backend rev-parse HEAD).Trim()
    backendBranch = (& git -C $backend rev-parse --abbrev-ref HEAD).Trim()
    backendDirty = [bool](& git -C $backend status --porcelain)
    qtVersion = (& "$QtPrefix\bin\qtpaths.exe" --qt-version).Trim()
    compiler = (& "$LlvmBin\clang-cl.exe" --version | Select-Object -First 1)
    manifestTool = $manifestTool; linker = 'MSVC'
}
$result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$BuildRoot\result.json" -Encoding UTF8
$result | ConvertTo-Json -Depth 5
if (-not $passed) { throw "Notification backend fixtures failed. See the per-target logs in $BuildRoot." }
