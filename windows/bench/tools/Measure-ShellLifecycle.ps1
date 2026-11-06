[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QtPrefix,
    [Parameter(Mandatory)][string]$BuildRoot,
    [Parameter(Mandatory)][string]$SourceRoot,
    [string]$ConfigRoot,
    [Parameter(Mandatory)][string]$RunRoot,
    [ValidateSet('None', 'Startup', 'Reload', 'Update')][string]$Plant = 'None',
    [ValidateRange(0, 100)][double]$PlantPercent = 25,
    [string]$PlantReference
)
$ErrorActionPreference = 'Stop'
if (-not $ConfigRoot) { $ConfigRoot = $SourceRoot }
Add-Type -Name LifecycleErrorMode -Namespace W -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint SetErrorMode(uint m);'
[W.LifecycleErrorMode]::SetErrorMode(0x8003) | Out-Null
. "$PSScriptRoot\..\..\scripts\Caelestia-InstallCommon.ps1"
if (Test-Path -LiteralPath $RunRoot) { throw 'RunRoot must be new.' }
New-Item -ItemType Directory -Path $RunRoot | Out-Null
$prefix = Join-Path $RunRoot 'prefix'
$profile = Join-Path $RunRoot 'profile'
$values = [ordered]@{}
$activationExtraValidationMs = 0.0
$tooling = Join-Path $RunRoot 'tooling\windows\scripts'
New-Item -ItemType Directory -Path $tooling -Force | Out-Null
# Use each side's actual packaging and activation implementation. Using the
# current install script for both sides would hide installer regressions.
# The overlay changes destinations/instrumentation only, never the work.
$tracked = @(& git -C $SourceRoot ls-files windows/scripts)
foreach ($relative in $tracked) {
    $relativeScript = $relative.Substring('windows/scripts/'.Length)
    $target = Join-Path $tooling $relativeScript
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $target) | Out-Null
    Copy-Item -LiteralPath (Join-Path $SourceRoot $relative) -Destination $target
}
$installer = Join-Path $tooling 'Install-Caelestia.ps1'
$text = [IO.File]::ReadAllText($installer)
$sourceLiteral = "'" + $SourceRoot.Replace("'", "''") + "'"
$rootPattern = '(?m)^\$repoRoot = \(Resolve-Path[^\r\n]+'
if ([regex]::Matches($text, $rootPattern).Count -ne 1) { throw 'Unknown installer root resolution; cannot safely isolate it.' }
$text = [regex]::Replace($text, $rootPattern, ('$repoRoot = ' + $sourceLiteral))
$supportsSource = $text -match '\[string\]\$SourceRoot'
$supportsTimings = $text -match '\[string\]\$TimingFile'
$supportsNoIntegration = $text -match '\[switch\]\$NoIntegration'
if (-not $supportsNoIntegration) {
    throw 'Disposable lifecycle measurements require a real -NoIntegration installer. No HKCU/shortcut fallback is permitted.'
}
if (-not $supportsSource) {
    # The parent independently proves native-input/pin compatibility. Older
    # installers predate QML-only reuse and reject a different shell HEAD.
    $guard = '$sourceRevision -ne $buildInfo.sourceRevision'
    if (($text.Split(@($guard), [StringSplitOptions]::None).Count - 1) -ne 1) { throw 'Unknown legacy source guard.' }
    $text = $text.Replace($guard, '$false <# native compatibility verified by paired runner #>')
}
if (-not $supportsNoIntegration) {
    $versionsText = [IO.File]::ReadAllText((Join-Path $tooling 'Caelestia-Versions.ps1'))
    if ($versionsText -notmatch '\[string\]\$Shortcut' -or $versionsText -notmatch '\[string\]\$RunName') {
        throw 'Legacy integration cannot be redirected safely.'
    }
    $integration = '(?m)^(\s*Complete-CaelestiaInstallIntegration [^\r\n]+)'
    if ([regex]::Matches($text, $integration).Count -ne 1) { throw 'Unknown integration path; refusing an unisolated install.' }
    $text = [regex]::Replace($text, $integration, ('$1 -Shortcut "' + "$RunRoot\isolated-shortcut.lnk" + '" -RunName CaelestiaBenchmarkIsolated'))
}
if (-not $supportsTimings) {
    $compileCall = '& (Get-WindowsPowerShellPath) -NoProfile -NonInteractive -Command $compile'
    if (($text.Split(@($compileCall), [StringSplitOptions]::None).Count - 1) -ne 1) {
        throw 'Unknown legacy supervisor compilation boundary.'
    }
    $text = $text.Replace($compileCall, ('$benchmarkCompile = [Diagnostics.Stopwatch]::StartNew()' + "`n" +
        $compileCall + "`n" + '$benchmarkCompileSeconds = $benchmarkCompile.Elapsed.TotalSeconds'))
    $assembly = '(?m)^(\s*Write-Output \(''Payload assembled[^\r\n]+)'
    $selection = '(?m)^(\s*)(\$runtimePrefix = Install-CaelestiaVersion [^\r\n]+)'
    if ([regex]::Matches($text, $assembly).Count -ne 1 -or [regex]::Matches($text, $selection).Count -ne 1) {
        throw 'Unknown legacy timing boundaries.'
    }
    $text = [regex]::Replace($text, $assembly, ('$benchmarkAssembly = $preparation.Elapsed.TotalSeconds' + "`n" + '$1'))
    $timingLiteral = "'" + "$RunRoot\legacy-timing.json".Replace("'", "''") + "'"
    $text = [regex]::Replace($text, $selection, ('$1$benchmarkSelection = [Diagnostics.Stopwatch]::StartNew()' + "`n" +
        '$1$2' + "`n" + '$1[ordered]@{payloadAssemblySeconds=$benchmarkAssembly; versionSelectionSeconds=$benchmarkSelection.Elapsed.TotalSeconds; compileSupervisorSeconds=$benchmarkCompileSeconds; supervisorCacheHit=$false} | ConvertTo-Json | Set-Content -Encoding UTF8 -LiteralPath ' + $timingLiteral))
}
if ($Plant -eq 'Update') {
    $assemblyPoint = '(?m)^(\s*)(Write-CaelestiaProfileOwner [^\r\n]+)'
    if ([regex]::Matches($text, $assemblyPoint).Count -ne 1) { throw 'Unknown payload completion boundary for the update plant.' }
    $text = [regex]::Replace($text, $assemblyPoint,
        ('$1for ($benchmarkHash = 0; $benchmarkHash -lt 256; $benchmarkHash++) { $null = Get-FileHash -LiteralPath "$payload\qs.exe" }' + "`n" + '$1$2'))
}
[IO.File]::WriteAllText($installer, $text, [Text.UTF8Encoding]::new($false))
# The stage helper's source map remains the measured checkout's map.
$stageForwarder = @'
param([string]$Destination, [string]$ProfileRoot, [string]$Prototype = 'shell-live')
& '__STAGE__' -Destination $Destination -ProfileRoot $ProfileRoot -Prototype $Prototype
'@
$stageForwarder = $stageForwarder.Replace('__STAGE__', (Join-Path $SourceRoot 'windows\scripts\Stage-ShellPrototype.ps1').Replace("'", "''"))
[IO.File]::WriteAllText((Join-Path $tooling 'Stage-ShellPrototype.ps1'), $stageForwarder, [Text.UTF8Encoding]::new($false))
$installArguments = @{
    QtPrefix=$QtPrefix; BuildRoot=$BuildRoot; Prefix=$prefix; ProfileRoot=$profile; SkipSchemeRuntime=$true
}
if ($supportsSource) { $installArguments.SourceRoot=$SourceRoot }
if ($supportsNoIntegration) { $installArguments.NoIntegration=$true }
$clock = [Diagnostics.Stopwatch]::StartNew()
if ($supportsTimings) { $installArguments.TimingFile="$RunRoot\seed-timing.json" }
& $installer @installArguments *> "$RunRoot\seed-install.log"
$seedTimingPath = if ($supportsTimings) { "$RunRoot\seed-timing.json" } else { "$RunRoot\legacy-timing.json" }
$seedTimings = Get-Content $seedTimingPath -Raw | ConvertFrom-Json
$clock.Restart()
if ($supportsTimings) { $installArguments.TimingFile="$RunRoot\install-timing.json" }
& $installer @installArguments *> "$RunRoot\install.log"
$installWall = $clock.Elapsed.TotalMilliseconds
$timingPath = if ($supportsTimings) { "$RunRoot\install-timing.json" } else { "$RunRoot\legacy-timing.json" }
$timings = Get-Content $timingPath -Raw | ConvertFrom-Json
$values.payloadAssemblyMs = 1000 * $timings.payloadAssemblySeconds
$runtime = Resolve-CaelestiaRuntimePrefix $prefix
$stage = Join-Path $runtime 'shell'
foreach ($dir in @('config', 'state', 'runtime', 'cache', 'data')) {
    New-Item -ItemType Directory -Force -Path "$profile\$dir" | Out-Null
}
$config = Get-Content "$ConfigRoot\windows\shell\shell.json" -Raw | ConvertFrom-Json
$config.background.enabled = $false
$config.windows.clipboard.enabled = $false
$config.session.commands = @{}
$config | ConvertTo-Json -Depth 32 | Set-Content "$profile\config\shell.json" -Encoding UTF8
Copy-Item "$ConfigRoot\windows\shell\windows.json" "$profile\config\windows.json"
'{"binds":[{"keys":"PrintScreen","action":"native","name":"bench"},{"keys":"Win+Shift+S","action":"native","name":"bench"},{"keys":"Win+Shift+R","action":"native","name":"bench"}]}' |
    Set-Content "$profile\config\keybinds.json" -Encoding UTF8
'{"enabled":false}' | Set-Content "$profile\config\quota.json" -Encoding UTF8
# Smoke gates native writes. Disable only its automatic panel test schedule.
# Plants delay real readiness/reload work in disposable QML, not result values.
$shellPath = Join-Path $stage 'shell.qml'
$shell = [IO.File]::ReadAllText($shellPath)
$shell = $shell.Replace('running: root.smoke', 'running: false')
if ($Plant -eq 'Startup') {
    $shell = $shell.Replace('Component.onCompleted: {', 'Component.onCompleted: { const until = Date.now() + 400; while (Date.now() < until) {}')
}
if ($Plant -eq 'Reload') {
    if (-not $PlantReference) { throw 'A percentage reload plant requires the paired A reference.' }
    if (($shell.Split(@('Quickshell.reload(false)'), [StringSplitOptions]::None).Count - 1) -ne 1) {
        throw 'Unknown reload boundary; cannot verify a percentage reload plant.'
    }
    $reference = Get-Content -LiteralPath $PlantReference -Raw | ConvertFrom-Json
    $reloadExtraMs = [Math]::Round($reference.qmlReloadToReadyMs * $PlantPercent / 100, 3)
    # Deliberate regression work, not a production delay or edited result.
    $shell = $shell.Replace('Quickshell.reload(false)', ('{ const until = Date.now() + ' + $reloadExtraMs.ToString([Globalization.CultureInfo]::InvariantCulture) + '; while (Date.now() < until) {} Quickshell.reload(false); }'))
}
[IO.File]::WriteAllText($shellPath, $shell, [Text.UTF8Encoding]::new($false))
$info = [Diagnostics.ProcessStartInfo]::new()
$info.FileName = Join-Path $runtime 'qs.exe'
$info.Arguments = '--no-color --log-times --path "' + $shellPath + '"'
$info.WorkingDirectory = $stage
$info.UseShellExecute = $false
$info.CreateNoWindow = $true
$info.RedirectStandardOutput = $true
$info.RedirectStandardError = $true
foreach ($name in @($info.EnvironmentVariables.Keys | Where-Object { $_ -match '^(CAELESTIA_|QS_|QSG_|QT_|QML_|XDG_)' })) {
    $info.EnvironmentVariables.Remove($name)
}
$environment = @{
    PATH="$runtime;$runtime\qml\Caelestia\lib;$runtime\qml\M3Shapes;$env:PATH"
    QML_IMPORT_PATH="$stage\imports;$runtime\qml"
    QML2_IMPORT_PATH="$stage\imports;$runtime\qml"
    QML_DISK_CACHE_PATH="$profile\cache"
    QT_QPA_PLATFORM='offscreen'; QT_QUICK_BACKEND='software'; QSG_RENDER_LOOP='basic'
    QT_QPA_PLATFORM_PLUGIN_PATH="$QtPrefix\plugins\platforms"
    QT_LOGGING_RULES='quickshell.startup.debug=true;quickshell.windows.tracker.debug=false;quickshell.windows.inputmask.debug=false'
    QS_RUNTIME_DIR="$profile\runtime"; QS_WINDOWS_TRAY_HOOK='0'; QS_WINDOWS_BLUR='0'
    CAELESTIA_PROFILE_ROOT=$profile; CAELESTIA_WINDOWS_KEYBINDS="$profile\config\keybinds.json"
    CAELESTIA_SHELL_SMOKE='1'; CAELESTIA_SHELL_LIVE='0'; CAELESTIA_SHELL_SESSION_MODE='Disabled'
    CAELESTIA_WINDOWS_TILING='off'; CAELESTIA_WINDOWS_SESSION_ACTIONS='0'
}
foreach ($service in @('AUDIO', 'BATTERY', 'BLUETOOTH', 'BRIGHTNESS', 'MEDIA', 'NETWORK', 'APPS', 'HYPR', 'TRAY', 'SESSION', 'NOTIFICATIONS', 'BACKGROUND', 'POWER_PROFILES')) {
    $environment["CAELESTIA_WINDOWS_$service"] = '0'
}
foreach ($dir in @('CONFIG', 'STATE', 'RUNTIME')) { $environment["CAELESTIA_${dir}_DIR"] = "$profile\$($dir.ToLowerInvariant())" }
foreach ($dir in @('CONFIG', 'STATE', 'DATA', 'CACHE')) { $environment["XDG_${dir}_HOME"] = "$profile\$($dir.ToLowerInvariant())" }
foreach ($key in $environment.Keys) { $info.EnvironmentVariables[$key] = $environment[$key] }
$savedRuntime = $env:QS_RUNTIME_DIR
$env:QS_RUNTIME_DIR = "$profile\runtime"
$process = $null
try {
    # Additional real verification work before activation's first ready frame.
    if ($Plant -eq 'Update') {
        $clock.Restart()
        for ($i = 0; $i -lt 256; $i++) {
            $null = Get-FileHash -LiteralPath (Join-Path $runtime 'qs.exe')
        }
        $activationExtraValidationMs = $clock.Elapsed.TotalMilliseconds
    }
    $clock.Restart()
    $process = [Diagnostics.Process]::Start($info)
    $stdout = $process.StandardOutput.ReadToEndAsync()
    $stderr = $process.StandardError.ReadToEndAsync()
    Wait-CaelestiaReady $runtime -TimeoutSeconds 10
    Write-Output 'Lifecycle: cold ready'
    $values.coldStartToReadyMs = $clock.Elapsed.TotalMilliseconds
    $initial = Invoke-CaelestiaIpc $runtime state | ConvertFrom-Json
    $clock.Restart()
    & (Join-Path $runtime 'Start-Caelestia.ps1') -Prefix $runtime -Command Restart | Out-Null
    Write-Output 'Lifecycle: reload ready'
    $values.qmlReloadToReadyMs = $clock.Elapsed.TotalMilliseconds
    $final = Invoke-CaelestiaIpc $runtime state | ConvertFrom-Json
    if (-not $final.lifecycle.ready -or $initial.lifecycle.generation -eq $final.lifecycle.generation) {
        throw 'Reload did not produce a new ready generation.'
    }
    $values.isolatedActivationMs = 1000 * $timings.versionSelectionSeconds + $values.coldStartToReadyMs + $activationExtraValidationMs
    $null = Invoke-CaelestiaIpc $runtime quit
    Write-Output 'Lifecycle: quit acknowledged'
    if (-not $process.WaitForExit(5000)) { throw 'Isolated shell did not exit.' }
    if ($process.ExitCode -ne 0) { throw "Isolated shell failed during shutdown (exit $($process.ExitCode))." }
    [IO.File]::WriteAllText("$RunRoot\stdout.log", $stdout.GetAwaiter().GetResult())
    [IO.File]::WriteAllText("$RunRoot\stderr.log", $stderr.GetAwaiter().GetResult())
    Write-Output 'Lifecycle: logs collected'
    # Get-Content strings carry provider NoteProperties in Windows PowerShell.
    # Strip those before JSON serialization, which otherwise walks drive trees.
    $startupPhases = @([IO.File]::ReadAllLines("$RunRoot\stdout.log") + [IO.File]::ReadAllLines("$RunRoot\stderr.log") |
        Where-Object { $_ -match 'quickshell.startup' })
    [ordered]@{
        values=$values; installWallMs=$installWall; installPhases=$timings; seedInstallPhases=$seedTimings
        plant=$Plant; plantPercent=$PlantPercent; reloadExtraMs=$reloadExtraMs
        activationExtraValidationMs=$activationExtraValidationMs; activationValidationHashes=$(if ($Plant -eq 'Update') { 256 } else { 0 })
        assemblyValidationHashes=$(if ($Plant -eq 'Update') { 256 } else { 0 })
        installerSourceSha256=(Get-FileHash "$SourceRoot\windows\scripts\Install-Caelestia.ps1").Hash
        isolatedInstallerSha256=(Get-FileHash $installer).Hash
        installerArguments=$installArguments
        initialGeneration=$initial.lifecycle.generation; finalGeneration=$final.lifecycle.generation
        lifecycleReady=$final.lifecycle.ready
        exitCode=$process.ExitCode
        activationScope='version publication/selection plus offscreen process-to-ready; excludes live stop, task scheduler and integration'
        startupPhases=$startupPhases
    } | ConvertTo-Json -Depth 12 | Set-Content "$RunRoot\trial.json" -Encoding UTF8
    Write-Output 'Lifecycle: result written'
} finally {
    if ($process) {
        if (-not $process.HasExited) { $process.Kill(); $process.WaitForExit(5000) | Out-Null }
        [IO.File]::WriteAllText("$RunRoot\stdout.log", $stdout.GetAwaiter().GetResult())
        [IO.File]::WriteAllText("$RunRoot\stderr.log", $stderr.GetAwaiter().GetResult())
        $process.Dispose()
    }
    if ($null -eq $savedRuntime) { Remove-Item Env:\QS_RUNTIME_DIR -ErrorAction SilentlyContinue }
    else { $env:QS_RUNTIME_DIR = $savedRuntime }
}
