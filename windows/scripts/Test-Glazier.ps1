[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QtPrefix,
    [Parameter(Mandatory)][string]$BuildRoot
)
# Isolated profiles and stubs only. Never invoke the installed Glazier.
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$run = Join-Path ([IO.Path]::GetTempPath()) ("caelestia-glazier-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $run | Out-Null
$qs = Join-Path $BuildRoot 'quickshell\qs.exe'
$qmlRoot = Join-Path $BuildRoot 'install\qml'
$stub = Join-Path $run 'stub.exe'
Add-Type -Path "$repo\windows\glazier\GlazierStub.cs" -OutputAssembly $stub -OutputType WindowsApplication
foreach ($mode in @('config', 'config-only', 'default', 'fallback', 'missing')) {
    $root = Join-Path $run $mode
    $profile = Join-Path $root 'profile'
    $local = Join-Path $root 'local'
    $default = Join-Path $local 'Programs\Glazier\glazier.exe'
    $configured = Join-Path $root 'custom path\glazier.exe'
    foreach ($dir in @("$profile\config", "$profile\state", "$profile\runtime", "$profile\cache", "$profile\data")) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }
    if ($mode -notin @('missing', 'config-only')) {
        New-Item -ItemType Directory -Force -Path (Split-Path $default) | Out-Null
        Copy-Item $stub $default
    }
    if ($mode -in @('config', 'config-only')) {
        New-Item -ItemType Directory -Force -Path (Split-Path $configured) | Out-Null
        Copy-Item $stub $configured
    }
    if ($mode -in @('config', 'config-only', 'fallback')) {
        [IO.File]::WriteAllText("$profile\config\glazier.json",
            (@{ executable = $configured } | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding($false)))
    }
    $expected = if ($mode -in @('config', 'config-only')) { $configured } elseif ($mode -eq 'missing') { '' } else { $default }
    $stage = & "$PSScriptRoot\Stage-ShellPrototype.ps1" -Destination "$root\stage" -ProfileRoot $profile -Prototype shell-live
    Copy-Item "$repo\windows\glazier\GlazierSmoke.qml" "$stage\glazier-smoke.qml"
    $info = New-Object Diagnostics.ProcessStartInfo
    $info.FileName = $qs
    $info.Arguments = '--no-color --path "' + "$stage\glazier-smoke.qml" + '"'
    $info.WorkingDirectory = $root
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    foreach ($name in @($info.EnvironmentVariables.Keys | Where-Object { $_ -like 'CAELESTIA_*' -or $_ -like 'QS_WINDOWS_*' })) {
        $info.EnvironmentVariables.Remove($name)
    }
    $info.EnvironmentVariables['PATH'] = "$QtPrefix\bin;$qmlRoot\Caelestia\lib;$qmlRoot\M3Shapes;$env:PATH"
    $info.EnvironmentVariables['QML_IMPORT_PATH'] = "$stage\imports;$qmlRoot;$QtPrefix\qml"
    $info.EnvironmentVariables['QML2_IMPORT_PATH'] = "$stage\imports;$qmlRoot;$QtPrefix\qml"
    $info.EnvironmentVariables['QT_QPA_PLATFORM'] = 'offscreen'
    $info.EnvironmentVariables['LOCALAPPDATA'] = $local
    $info.EnvironmentVariables['CAELESTIA_CONFIG_DIR'] = "$profile\config"
    $info.EnvironmentVariables['GLAZIER_EXPECTED_PATH'] = $expected
    $info.EnvironmentVariables['GLAZIER_STUB_OUTPUT'] = "$root\invocation.txt"
    $process = [Diagnostics.Process]::Start($info)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    if (-not $process.WaitForExit(20000)) { $process.Kill(); throw "$mode timed out" }
    $text = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
    if ($process.ExitCode -ne 0 -or -not $text.Contains('GLAZIER_TEST_PASS')) {
        throw "$mode failed: $text"
    }
    $invocation = "$root\invocation.txt"
    if ($mode -eq 'missing') {
        if (Test-Path $invocation) { throw 'Missing Glazier launched a process.' }
    } else {
        if (-not (Test-Path $invocation)) { throw "$mode did not launch the stub." }
        $lines = @(Get-Content $invocation)
        if ($lines.Count -ne 2 -or $lines[0] -ne $expected -or $lines[1] -ne '--capture') {
            throw "$mode launched the wrong command."
        }
    }
    Write-Host "$mode passed"
}
Write-Host "Glazier offscreen tests passed. Temp files: $run"
