[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QtPrefix,
    [Parameter(Mandatory)][string]$BuildRoot,
    [switch]$Preflight,
    [string]$ExpectedRuntimeHash
)
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$BuildRoot = (Resolve-Path -LiteralPath $BuildRoot).Path
$QtPrefix = (Resolve-Path -LiteralPath $QtPrefix).Path
$qmlRoot = Join-Path $BuildRoot 'install\qml'
$executable = Join-Path $BuildRoot 'quickshell\qs.exe'
if (Test-Path -LiteralPath "$BuildRoot\quickshell\qt.conf") {
    throw 'Headless checks require the undeployed build executable, not a runtime with deployed qt.conf.'
}
$buildInfo = Get-Content -LiteralPath "$BuildRoot\logs\build.json" -Raw | ConvertFrom-Json
$sourceRevision = (& git -C $repoRoot rev-parse HEAD).Trim()
$sourceDirty = [bool](& git -C $repoRoot status --porcelain)
# The native artifact also depends on the two pinned QML/native submodules.
# Compare them so sourceMatchesBuild cannot claim provenance from the root
# revision alone while a submodule points somewhere else.
$backendRevision = (& git -C "$repoRoot\windows\deps\quickshell" rev-parse HEAD).Trim()
$m3shapesRevision = (& git -C "$repoRoot\windows\deps\m3shapes" rev-parse HEAD).Trim()
if (-not $backendRevision -or -not $m3shapesRevision) {
    throw 'Running-app checks require initialized backend and M3Shapes submodules.'
}
foreach ($required in @($executable, "$QtPrefix\bin\Qt6Core.dll",
    "$QtPrefix\plugins\platforms\qoffscreen.dll", "$qmlRoot\Caelestia\Config\qmldir",
    "$qmlRoot\Caelestia\Windows\qmldir", "$qmlRoot\M3Shapes\qmldir")) {
    if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Missing headless prerequisite: $required" }
}
if ($QtPrefix -ne ([IO.Path]::GetFullPath([string]$buildInfo.qtPrefix)).TrimEnd('\')) {
    throw 'QtPrefix differs from the artifact build metadata.'
}
$qtCore = (Get-Item -LiteralPath "$QtPrefix\bin\Qt6Core.dll").VersionInfo.ProductVersion
$offscreen = (Get-Item -LiteralPath "$QtPrefix\plugins\platforms\qoffscreen.dll").VersionInfo.ProductVersion
if ($qtCore -ne $offscreen -or -not $qtCore.StartsWith([string]$buildInfo.qtVersion)) {
    throw 'The offscreen plugin, Qt runtime and build metadata must match.'
}
$runtimeHash = (Get-FileHash -LiteralPath $executable -Algorithm SHA256).Hash
if (($ExpectedRuntimeHash -and $runtimeHash -ne $ExpectedRuntimeHash) -or
    ($buildInfo.executableSha256 -and $runtimeHash -ne $buildInfo.executableSha256)) {
    throw 'Native executable checksum differs from the authorized artifact.'
}
$run = Join-Path ([IO.Path]::GetTempPath()) ('caelestia-running-apps-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $run | Out-Null
$profile = Join-Path $run 'profile'
$stage = & "$PSScriptRoot\Stage-ShellPrototype.ps1" -Destination "$run\stage" -ProfileRoot $profile -Prototype shell-live
$testName = if ($Preflight) { 'RunningAppsEnvironmentTest.qml' } else { 'RunningAppsTest.qml' }
$header = @("//@ pragma DataDir $profile\data", "//@ pragma StateDir $profile\state", "//@ pragma CacheDir $profile\cache")
# Path pragmas isolate Quickshell storage only. Qt bootstrap and every control
# gate are supplied through ProcessStartInfo before Process.Start, as in Test-Nexus.
[IO.File]::WriteAllText("$stage\running-apps-test.qml",
    (($header -join "`n") + "`n" + [IO.File]::ReadAllText("$repoRoot\windows\tests\$testName")),
    [Text.UTF8Encoding]::new($false))
foreach ($directory in @('config', 'state', 'runtime', 'cache', 'data', 'tmp', 'home\AppData\Roaming', 'home\AppData\Local')) {
    New-Item -ItemType Directory -Force -Path (Join-Path $profile $directory) | Out-Null
}
$info = New-Object Diagnostics.ProcessStartInfo
$info.FileName = $executable
$info.Arguments = '--no-color --log-times --path "' + "$stage\running-apps-test.qml" + '"'
$info.WorkingDirectory = $run
$info.UseShellExecute = $false
$info.CreateNoWindow = $true
$info.RedirectStandardOutput = $true
$info.RedirectStandardError = $true
foreach ($variable in @($info.EnvironmentVariables.Keys | Where-Object {
    $_ -like 'CAELESTIA_*' -or $_ -like 'QS_WINDOWS_*' -or $_ -in @('QT_PLUGIN_PATH', 'QT_QPA_PLATFORM_PLUGIN_PATH')
})) {
    $info.EnvironmentVariables.Remove($variable)
}
$info.EnvironmentVariables['PATH'] = "$QtPrefix\bin;$qmlRoot\Caelestia\lib;$qmlRoot\M3Shapes;$env:PATH"
$info.EnvironmentVariables['QML_IMPORT_PATH'] = "$stage\imports;$qmlRoot;$QtPrefix\qml"
$info.EnvironmentVariables['QML2_IMPORT_PATH'] = "$stage\imports;$qmlRoot;$QtPrefix\qml"
foreach ($name in @('TEMP', 'TMP')) { $info.EnvironmentVariables[$name] = "$profile\tmp" }
$info.EnvironmentVariables['USERPROFILE'] = "$profile\home"
$info.EnvironmentVariables['HOME'] = "$profile\home"
$info.EnvironmentVariables['APPDATA'] = "$profile\home\AppData\Roaming"
$info.EnvironmentVariables['LOCALAPPDATA'] = "$profile\home\AppData\Local"
$info.EnvironmentVariables['CAELESTIA_CONFIG_DIR'] = "$profile\config"
$info.EnvironmentVariables['CAELESTIA_PROFILE_ROOT'] = $profile
$info.EnvironmentVariables['CAELESTIA_STATE_DIR'] = "$profile\state"
$info.EnvironmentVariables['CAELESTIA_CACHE_DIR'] = "$profile\cache"
$info.EnvironmentVariables['CAELESTIA_RUNTIME_DIR'] = "$profile\runtime"
$info.EnvironmentVariables['XDG_CONFIG_HOME'] = "$profile\config"
$info.EnvironmentVariables['XDG_STATE_HOME'] = "$profile\state"
$info.EnvironmentVariables['XDG_CACHE_HOME'] = "$profile\cache"
$info.EnvironmentVariables['XDG_DATA_HOME'] = "$profile\data"
$info.EnvironmentVariables['QML_DISK_CACHE_PATH'] = "$profile\cache"
$info.EnvironmentVariables['QT_LOGGING_RULES'] = 'quickshell.windows.*.debug=false;quickshell.windows.*.info=false'
$info.EnvironmentVariables['QT_QPA_PLATFORM'] = 'offscreen'
$info.EnvironmentVariables['QT_PLUGIN_PATH'] = "$QtPrefix\plugins"
$info.EnvironmentVariables['QS_WINDOWS_TRAY_HOOK'] = '0'
$info.EnvironmentVariables['QS_WINDOWS_BLUR'] = '0'
$info.EnvironmentVariables['QSG_RHI_BACKEND'] = 'd3d11'
$staleGates = @($info.EnvironmentVariables.Keys | Where-Object {
    $_ -like 'CAELESTIA_WINDOWS_*' -or $_ -in @('CAELESTIA_COMBINED_LIVE', 'CAELESTIA_WINDOWS_TILING')
})
if ($staleGates.Count -or $info.EnvironmentVariables['QS_WINDOWS_TRAY_HOOK'] -ne '0' -or
    $info.EnvironmentVariables['QT_QPA_PLATFORM'] -ne 'offscreen') {
    throw 'Native controls, tiler and tray gates must be reset before Qt starts.'
}
$process = [Diagnostics.Process]::Start($info)
$stdout = $process.StandardOutput.ReadToEndAsync()
$stderr = $process.StandardError.ReadToEndAsync()
$timedOut = -not $process.WaitForExit(20000)
if ($timedOut) { $process.Kill(); $process.WaitForExit() }
# Always drain and retain both streams, including a timeout/bootstrap failure.
$stdoutText = $stdout.GetAwaiter().GetResult()
$stderrText = $stderr.GetAwaiter().GetResult()
[IO.File]::WriteAllText("$run\stdout.log", $stdoutText)
[IO.File]::WriteAllText("$run\stderr.log", $stderrText)
$output = $stdoutText + $stderrText
Write-Output $output
$marker = if ($Preflight) { 'CAELESTIA_RUNNING_APPS_ENV_PASS' } else { 'CAELESTIA_RUNNING_APPS_PASS [1-9][0-9]*' }
$assertionMatch = [regex]::Match($output, 'CAELESTIA_RUNNING_APPS_PASS ([0-9]+)')
$bootstrapFailure = $output -match 'qt\.qpa\.plugin|no Qt platform plugin|Qt platform plugin could|FATAL|CRITICAL'
$result = [ordered]@{
    preflight = $Preflight.IsPresent
    sourceRevision = $sourceRevision
    sourceDirty = $sourceDirty
    buildSourceRevision = $buildInfo.sourceRevision
    buildSourceDirty = [bool]$buildInfo.sourceDirty
    backendRevision = $backendRevision
    buildBackendRevision = $buildInfo.backendRevision
    m3shapesRevision = $m3shapesRevision
    buildM3ShapesRevision = $buildInfo.m3shapesRevision
    # Provenance only. QML is staged from the checkout, so a false value does
    # not mean the fixture ran stale QML; it means the native artifact cannot be
    # claimed to have been built from this exact clean revision.
    sourceMatchesBuild = ($buildInfo.sourceRevision -eq $sourceRevision -and
        -not $sourceDirty -and -not $buildInfo.sourceDirty -and
        $buildInfo.backendRevision -eq $backendRevision -and
        $buildInfo.m3shapesRevision -eq $m3shapesRevision)
    fixture = $testName
    assertions = if ($assertionMatch.Success) { [int]$assertionMatch.Groups[1].Value } else { 0 }
    executable = $executable
    executableSha256 = $runtimeHash
    qtVersion = $qtCore
    offscreenVersion = $offscreen
    nativeControlsReset = $true
    platform = $info.EnvironmentVariables['QT_QPA_PLATFORM']
    pluginPath = $info.EnvironmentVariables['QT_PLUGIN_PATH']
    importPath = $info.EnvironmentVariables['QML_IMPORT_PATH']
    timedOut = $timedOut
    bootstrapFailure = $bootstrapFailure
    exitCode = $process.ExitCode
    stdout = "$run\stdout.log"
    stderr = "$run\stderr.log"
    evidenceDirectory = $run
}
$result | ConvertTo-Json | Set-Content -LiteralPath "$run\result.json" -Encoding UTF8
$result | ConvertTo-Json
if ($bootstrapFailure) { throw "Qt bootstrap failed. STOP, do not retry: $run" }
if ($timedOut -or $process.ExitCode -ne 0 -or $output -notmatch $marker -or
    $output -match 'CAELESTIA_RUNNING_APPS_FAIL|TypeError|ReferenceError|binding loop|Cannot assign|is not a type|is not available') {
    throw "Running-app fixture failed. Disposable run: $run"
}
