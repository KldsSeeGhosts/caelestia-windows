[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QtPrefix,
    [string]$BuildRoot = 'C:\b-grec'
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$stageRoot = Join-Path ([IO.Path]::GetTempPath()) ('caelestia-glazier-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stageRoot | Out-Null
$stub = Join-Path $stageRoot 'glazier-stub.exe'
Add-Type -Path (Join-Path $repoRoot 'windows\tests\GlazierStub.cs') -OutputAssembly $stub `
    -OutputType WindowsApplication -ReferencedAssemblies System.Web.Extensions
$stage = & "$PSScriptRoot\Stage-ShellPrototype.ps1" -Prototype combined `
    -Destination (Join-Path $stageRoot 'stage') -ProfileRoot (Join-Path $stageRoot 'profile')
Copy-Item -LiteralPath (Join-Path $repoRoot 'windows\tests\GlazierRecorderTest.qml') -Destination (Join-Path $stage 'shell.qml')
New-Item -ItemType Directory -Path (Join-Path $stageRoot 'profile\config'), (Join-Path $stageRoot 'output') | Out-Null
# A temp MP4 must not appear in the original recordings list.
[IO.File]::WriteAllText((Join-Path $stageRoot 'output\.glazier-unpublished.mp4'), 'fixture')
foreach ($scenario in @('normal', 'missing', 'disabled', 'smoke')) {
    $missing = $scenario -eq 'missing'
    $disabled = $scenario -in @('disabled', 'smoke')
    $stateFile = Join-Path $stageRoot 'state.json'
    $beforeWrite = if (Test-Path -LiteralPath $stateFile) { (Get-Item -LiteralPath $stateFile).LastWriteTimeUtc } else { $null }
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = Join-Path $BuildRoot 'quickshell\qs.exe'
    $info.Arguments = '-p "' + (Join-Path $stage 'shell.qml') + '" --no-duplicate'
    $info.WorkingDirectory = $stageRoot
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.EnvironmentVariables['PATH'] = "$QtPrefix\bin;$BuildRoot\install\qml\Caelestia\lib;$BuildRoot\install\qml\M3Shapes;$env:PATH"
    $info.EnvironmentVariables['QT_QPA_PLATFORM'] = 'offscreen'
    $info.EnvironmentVariables['QT_QUICK_BACKEND'] = 'software'
    $info.EnvironmentVariables['QT_FORCE_STDERR_LOGGING'] = '1'
    $info.EnvironmentVariables['QML_IMPORT_PATH'] = "$stage\imports;$BuildRoot\install\qml;$QtPrefix\qml"
    $info.EnvironmentVariables['CAELESTIA_CONFIG_DIR'] = Join-Path $stageRoot 'profile\config'
    $info.EnvironmentVariables['CAELESTIA_COMBINED_LIVE'] = $(if ($scenario -eq 'disabled') { '0' } else { '1' })
    $info.EnvironmentVariables['CAELESTIA_SHELL_SMOKE'] = $(if ($scenario -eq 'smoke') { '1' } else { '0' })
    $info.EnvironmentVariables['CAELESTIA_GLAZIER_EXE'] = $(if ($missing) { Join-Path $stageRoot 'missing.exe' } else { $stub })
    $info.EnvironmentVariables['GLAZIER_STUB_ROOT'] = $stageRoot
    $info.EnvironmentVariables['GLAZIER_TEST_MISSING'] = $(if ($missing) { '1' } else { '0' })
    $info.EnvironmentVariables['GLAZIER_TEST_DISABLED'] = $(if ($disabled) { '1' } else { '0' })
    $process = [Diagnostics.Process]::Start($info)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    $timedOut = -not $process.WaitForExit(35000)
    if ($timedOut) {
        $process.Kill()
        $process.WaitForExit()
    }
    $output = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
    [IO.File]::WriteAllText((Join-Path $stageRoot "run-$scenario.log"), $output)
    $marker = $(if ($missing) { 'GLAZIER_RECORDER_MISSING_PASS' } elseif ($disabled) { 'GLAZIER_RECORDER_DISABLED_PASS' } else { 'GLAZIER_RECORDER_PASS' })
    if ($timedOut -or $process.ExitCode -ne 0 -or $output -notmatch $marker -or
        $output -match 'GLAZIER_RECORDER_FAIL|TypeError|ReferenceError|is not a type|binding loop') {
        $output -split "`n" | Select-Object -Last 22 | Write-Output
        throw "Glazier recorder fixture failed (exit $($process.ExitCode), timeout $timedOut). Stage: $stageRoot"
    }
    if ($disabled -and (Get-Item -LiteralPath $stateFile).LastWriteTimeUtc -ne $beforeWrite) {
        throw "Disabled/smoke recorder invoked the stub: $scenario"
    }
    [regex]::Match($output, "$marker \d+").Value | Write-Output
}
Write-Output "Isolated offscreen logs: $stageRoot"
