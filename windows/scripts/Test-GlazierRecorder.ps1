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
$shellPath = Join-Path $stage 'shell.qml'
# Keep the stage's profile routing when replacing its entry point. Environment
# variables alone do not override Quickshell's DataDir/StateDir/CacheDir.
$pragmas = @([regex]::Matches([IO.File]::ReadAllText($shellPath),
    '(?m)^//@ pragma (?:DataDir|StateDir|CacheDir) [^\r\n]+') | ForEach-Object { $_.Value })
if ($pragmas.Count -ne 3) { throw 'Expected all three staged profile-directory pragmas.' }
$testQml = [IO.File]::ReadAllText((Join-Path $repoRoot 'windows\tests\GlazierRecorderTest.qml'))
[IO.File]::WriteAllText($shellPath, (($pragmas -join "`n") + "`n" + $testQml), (New-Object Text.UTF8Encoding($false)))
New-Item -ItemType Directory -Path (Join-Path $stageRoot 'profile\config'), (Join-Path $stageRoot 'output') | Out-Null
# A temp MP4 must not appear in the original recordings list.
[IO.File]::WriteAllText((Join-Path $stageRoot 'output\.glazier-unpublished.mp4'), 'fixture')
$ownershipFile = Join-Path $stageRoot 'profile\state\caelestia\recordings.json'
# Inert binds take the three Glazier chords so offscreen runs never register a
# physical hotkey through the legacy-profile merge.
$smokeKeybinds = Join-Path $stageRoot 'smoke-keybinds.json'
[IO.File]::WriteAllText($smokeKeybinds,
    '{"binds":[{"keys":"PrintScreen","action":"native","name":"smoke-printscreen"},' +
    '{"keys":"Win+Shift+S","action":"native","name":"smoke-win-shift-s"},' +
    '{"keys":"Win+Shift+R","action":"native","name":"smoke-win-shift-r"}]}',
    (New-Object Text.UTF8Encoding($false)))
foreach ($scenario in @('normal', 'bundled', 'cold-start', 'start-timeout', 'store-missing', 'store-corrupt',
    'store-write', 'store-restart', 'missing', 'bundled-missing', 'disabled', 'smoke', 'layout')) {
    $missing = $scenario -in @('missing', 'bundled-missing')
    $bundled = $scenario -eq 'bundled'
    $layout = $scenario -eq 'layout'
    $disabled = $scenario -in @('disabled', 'smoke')
    $stateFile = Join-Path $stageRoot 'state.json'
    if ($scenario -notin @('store-restart', 'missing', 'bundled-missing', 'disabled', 'smoke')) {
        # Only this run's synthetic stub/profile state is reset. Restart reuses
        # committed ownership and the host journal from the preceding process.
        Remove-Item -LiteralPath $stateFile, $ownershipFile -Force -ErrorAction SilentlyContinue
    }
    $bundledExe = Join-Path $stageRoot 'glazier.exe'
    if ($bundled) {
        Copy-Item $stub $bundledExe -Force
    } else {
        Remove-Item -LiteralPath $bundledExe -Force -ErrorAction SilentlyContinue
    }
    if ($scenario -eq 'store-corrupt') {
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $ownershipFile) | Out-Null
        [IO.File]::WriteAllText($ownershipFile, '{synthetic corrupt JSON')
    }
    if ($scenario -eq 'store-write') {
        foreach ($name in @('fixture-0.mp4', 'fixture-500.mp4', 'fixture-unreported.mp4')) {
            [IO.File]::WriteAllText((Join-Path $stageRoot "output\$name"), 'synthetic fixture')
        }
    }
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
    $info.EnvironmentVariables['CAELESTIA_WINDOWS_KEYBINDS'] = $smokeKeybinds
    $info.EnvironmentVariables['CAELESTIA_COMBINED_LIVE'] = $(if ($scenario -eq 'disabled') { '0' } else { '1' })
    $info.EnvironmentVariables['CAELESTIA_SHELL_SMOKE'] = $(if ($scenario -eq 'smoke') { '1' } else { '0' })
    $info.EnvironmentVariables['CAELESTIA_GLAZIER_EXE'] = $(if ($bundled) { '' } elseif ($missing -or $layout) { Join-Path $stageRoot 'missing.exe' } else { $stub })
    $info.EnvironmentVariables['GLAZIER_STUB_ROOT'] = $stageRoot
    $info.EnvironmentVariables['GLAZIER_BUNDLED_EXE'] = $bundledExe
    $info.EnvironmentVariables['GLAZIER_TEST_MISSING'] = $(if ($missing) { '1' } else { '0' })
    $info.EnvironmentVariables['GLAZIER_TEST_DISABLED'] = $(if ($disabled) { '1' } else { '0' })
    $info.EnvironmentVariables['GLAZIER_TEST_SCENARIO'] = $scenario
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
    $marker = $(if ($layout) { 'GLAZIER_RECORDER_LAYOUT_PASS' }
        elseif ($bundled) { 'GLAZIER_RECORDER_BUNDLED_PASS' }
        elseif ($missing) { 'GLAZIER_RECORDER_MISSING_PASS' }
        elseif ($disabled) { 'GLAZIER_RECORDER_DISABLED_PASS' }
        elseif ($scenario.StartsWith('store-')) { 'GLAZIER_RECORDER_STORE_PASS' }
        elseif ($scenario -in @('cold-start', 'start-timeout')) { 'GLAZIER_RECORDER_START_FAILURE_PASS' }
        else { 'GLAZIER_RECORDER_PASS' })
    if ($timedOut -or $process.ExitCode -ne 0 -or $output -notmatch $marker -or
        $output -match 'GLAZIER_RECORDER_FAIL|TypeError|ReferenceError|is not a type|binding loop') {
        $output -split "`n" | Select-Object -Last 22 | Write-Output
        throw "Glazier recorder fixture failed (exit $($process.ExitCode), timeout $timedOut). Stage: $stageRoot"
    }
    if ($disabled -and (Get-Item -LiteralPath $stateFile).LastWriteTimeUtc -ne $beforeWrite) {
        throw "Disabled/smoke recorder invoked the stub: $scenario"
    }
    if ($scenario.StartsWith('store-')) {
        # WinPS 5.1 emits a parsed JSON array as one pipeline item. Enumerate
        # the assigned value so this count checks records, not the wrapper.
        $saved = Get-Content -LiteralPath $ownershipFile -Raw | ConvertFrom-Json
        $saved = @($saved)
        $expectedCount = if ($scenario -in @('store-write', 'store-restart')) { 500 } else { 1 }
        if ($saved.Count -ne $expectedCount) {
            throw "Unexpected persisted ownership count in synthetic $scenario fixture."
        }
    }
    [regex]::Match($output, "$marker \d+").Value | Write-Output
}
Write-Output "Isolated offscreen logs: $stageRoot"
