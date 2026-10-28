[CmdletBinding()]
param(
    [string]$Prefix,
    [ValidateSet('Start', 'State', 'Quit', 'Restart')][string]$Command = 'Start',
    [switch]$Smoke,
    [ValidateRange(0, 15)][int]$ScreenIndex,
    [ValidateSet('Disabled', 'Observe', 'Interactive')][string]$TilingMode = 'Disabled',
    [string]$TilingIncluded = '',
    [string]$TilingExcluded = '',
    [switch]$SkipSchemeRuntime,
    [switch]$Wait
)

. (Join-Path $PSScriptRoot 'Caelestia-InstallCommon.ps1')
if (-not $Prefix) {
    $Prefix = if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'install.json')) { $PSScriptRoot } else { Join-Path $env:LOCALAPPDATA 'Programs\caelestia-windows' }
}
$Prefix = Resolve-CaelestiaDirectory $Prefix
$record = Read-CaelestiaInstall $Prefix
$profile = Resolve-CaelestiaDirectory $record.profile
$stage = Join-Path $Prefix 'shell'
$exe = Join-Path $Prefix 'qs.exe'
if ($Smoke -and $Command -ne 'Start') { throw '-Smoke requires -Command Start.' }
if ($PSBoundParameters.ContainsKey('ScreenIndex') -and -not $Smoke) { throw '-ScreenIndex requires -Smoke.' }

if ($Command -eq 'Start') {
    # Automatically claim only an empty profile; pre-populated directories
    # without an existing marker are never auto-marked exclusive.
    if (-not (Read-CaelestiaProfileOwner $profile) -and (Test-CaelestiaProfileEmpty $profile)) {
        Write-CaelestiaProfileOwner $profile $Prefix $(if ($record.installId) { [string]$record.installId } else { [guid]::NewGuid().ToString('N') }) $true
    }
    foreach ($dir in @('config', 'state', 'cache', 'data', 'runtime', 'logs')) {
        New-Item -ItemType Directory -Force -Path (Join-Path $profile $dir) | Out-Null
    }
    # Seed once; updates and restarts preserve user edits.
    foreach ($name in @('shell.json', 'keybinds.json', 'windows.json')) {
        $target = Join-Path $profile "config\$name"
        if (-not (Test-Path -LiteralPath $target)) {
            Copy-Item -LiteralPath (Join-Path $Prefix "defaults\$name") -Destination $target
        }
    }
}

$schemeRuntime = $null
if ($Command -eq 'Start' -and -not $SkipSchemeRuntime) {
    $schemeRuntime = & (Join-Path $PSScriptRoot 'Install-SchemeRuntime.ps1') -ProfileRoot $profile |
        Select-Object -Last 1 | ConvertFrom-Json
}
$schemeAvailable = $null -ne $schemeRuntime -and $schemeRuntime.available -eq $true
$wePython = if ($schemeAvailable) { [string]$schemeRuntime.python } elseif ($Command -eq 'Start') {
    $pythonLauncher = Get-Command py.exe -ErrorAction SilentlyContinue
    if ($pythonLauncher) { & $pythonLauncher.Source -3 -c 'import sys; print(sys.executable)' }
}

$info = New-Object Diagnostics.ProcessStartInfo
$info.FileName = $exe
$info.WorkingDirectory = $Prefix
$info.UseShellExecute = $false
$info.CreateNoWindow = $true
# Preserve the user's launch environment in normal use. Smoke deliberately
# excludes developer PATH entries to check the deployed runtime independently.
$info.EnvironmentVariables['PATH'] = $(if ($Smoke) { "$Prefix;$env:SystemRoot\System32;$env:SystemRoot" } else { "$Prefix;$env:PATH" })
$info.EnvironmentVariables['QML_IMPORT_PATH'] = "$stage\imports;$Prefix\qml"
$info.EnvironmentVariables['QML2_IMPORT_PATH'] = "$stage\imports;$Prefix\qml"
$info.EnvironmentVariables['QT_PLUGIN_PATH'] = Join-Path $Prefix 'plugins'
$info.EnvironmentVariables['QT_QPA_PLATFORM_PLUGIN_PATH'] = Join-Path $Prefix 'plugins\platforms'
$info.EnvironmentVariables['QML_DISK_CACHE_PATH'] = Join-Path $profile 'cache\qml'
$info.EnvironmentVariables['CAELESTIA_CONFIG_DIR'] = Join-Path $profile 'config'
$info.EnvironmentVariables['CAELESTIA_STATE_DIR'] = Join-Path $profile 'state'
$info.EnvironmentVariables['CAELESTIA_BANNER_HELPER'] = Join-Path $PSScriptRoot 'Banner-Suppression.ps1'
$info.EnvironmentVariables['CAELESTIA_RUNTIME_DIR'] = Join-Path $profile 'runtime'
$info.EnvironmentVariables['CAELESTIA_PROFILE_ROOT'] = $profile
foreach ($directory in @('config', 'state', 'data', 'cache')) {
    $info.EnvironmentVariables["XDG_$($directory.ToUpperInvariant())_HOME"] = Join-Path $profile $directory
}
$info.EnvironmentVariables['CAELESTIA_SCHEME_PYTHON'] = $(if ($schemeAvailable) { [string]$schemeRuntime.python } else { '' })
$info.EnvironmentVariables['CAELESTIA_SCHEME_HELPER'] = $(if ($schemeAvailable) { [string]$schemeRuntime.helper } else { '' })
$info.EnvironmentVariables['CAELESTIA_WE_PYTHON'] = [string]$wePython
$info.EnvironmentVariables['CAELESTIA_ACCOUNT_PICTURE'] = $(if ($Command -eq 'Start') {
    & (Join-Path $PSScriptRoot 'Get-AccountPicture.ps1') -CacheRoot (Join-Path $profile 'cache')
} else { '' })
$info.EnvironmentVariables['QS_WINDOWS_BLUR'] = '0'
$info.EnvironmentVariables['QSG_RHI_BACKEND'] = 'd3d11'
$info.EnvironmentVariables['QT_LOGGING_RULES'] = 'quickshell.windows.tracker.debug=false;quickshell.windows.inputmask.debug=false'
$info.EnvironmentVariables['CAELESTIA_SHELL_LIVE'] = '1'
$info.EnvironmentVariables['CAELESTIA_COMBINED_LIVE'] = $(if ($Smoke) { '0' } else { '1' })
$info.EnvironmentVariables['CAELESTIA_SHELL_SMOKE'] = $(if ($Smoke) { '1' } else { '0' })
$info.EnvironmentVariables['CAELESTIA_SHELL_SCREEN'] = $(if ($PSBoundParameters.ContainsKey('ScreenIndex')) { "$ScreenIndex" } else { '' })
foreach ($slice in @('AUDIO', 'BATTERY', 'BLUETOOTH', 'BRIGHTNESS', 'MEDIA', 'NETWORK', 'APPS', 'TRAY', 'NOTIFICATIONS', 'SESSION', 'POWER_PROFILES')) {
    $info.EnvironmentVariables["CAELESTIA_WINDOWS_$slice"] = '1'
}
$liveValue = $(if ($Smoke) { '0' } else { '1' })
foreach ($gate in @('AUDIO_CONTROLS', 'BLUETOOTH_CONTROLS', 'BRIGHTNESS_CONTROLS', 'MEDIA_CONTROLS', 'NETWORK_CONTROLS', 'APP_LAUNCH', 'TRAY_ACTIVATION', 'POWER_PROFILE_WRITES', 'SESSION_ACTIONS', 'NOTIFICATION_MIRROR', 'NOTIFICATION_MIRROR_DISMISS', 'NOTIFICATION_APP_OPEN')) {
    $info.EnvironmentVariables["CAELESTIA_WINDOWS_$gate"] = $liveValue
}
# The hook only feeds the bar's tray entry; leave it off while that entry is
# disabled or removed in the profile's shell.json.
$trayHook = $liveValue
try {
    $shellConfig = Get-Content -LiteralPath (Join-Path $profile 'config\shell.json') -Raw -ErrorAction Stop | ConvertFrom-Json
    if ($null -ne $shellConfig.bar -and $null -ne $shellConfig.bar.entries) {
        $trayEntry = @($shellConfig.bar.entries | Where-Object { $_.id -eq 'tray' }) | Select-Object -First 1
        if (-not $trayEntry -or $trayEntry.enabled -eq $false) { $trayHook = '0' }
    }
} catch { }
$info.EnvironmentVariables['QS_WINDOWS_TRAY_HOOK'] = $trayHook
$info.EnvironmentVariables['CAELESTIA_WINDOWS_BRIGHTNESS_SOFTWARE'] = '0'
$info.EnvironmentVariables['CAELESTIA_SHELL_SESSION'] = '1'
$info.EnvironmentVariables['CAELESTIA_SHELL_SESSION_MODE'] = 'Observe'
$info.EnvironmentVariables['CAELESTIA_TRAY_FIXTURE'] = '0'
$info.EnvironmentVariables['CAELESTIA_WINDOWS_HYPR'] = '1'
$info.EnvironmentVariables['CAELESTIA_WINDOWS_HYPR_DISPATCH'] = $liveValue
$info.EnvironmentVariables['CAELESTIA_WINDOWS_BACKGROUND'] = '1'
$info.EnvironmentVariables['CAELESTIA_WINDOWS_DESKTOP_ICONS'] = 'Behind'
$tiling = $env:CAELESTIA_WINDOWS_TILING
if ($PSBoundParameters.ContainsKey('TilingMode')) {
    $tiling = $TilingMode.ToLowerInvariant()
    if ($tiling -eq 'disabled') { $tiling = 'off' }
}
if ($Smoke) { $tiling = 'off' }
$info.EnvironmentVariables['CAELESTIA_WINDOWS_TILING'] = [string]$tiling
$info.EnvironmentVariables['CAELESTIA_WINDOWS_TILING_OVERRIDE'] = $(if ($Smoke -or $PSBoundParameters.ContainsKey('TilingMode')) { '1' } else { '0' })
foreach ($field in @('Included', 'Excluded')) {
    $variable = 'CAELESTIA_WINDOWS_TILING_' + $field.ToUpperInvariant()
    $explicit = $PSBoundParameters.ContainsKey("Tiling$field")
    $value = $(if ($explicit) { Get-Variable -Name "Tiling$field" -ValueOnly } else { [Environment]::GetEnvironmentVariable($variable) })
    $info.EnvironmentVariables[$variable] = [string]$value
    $info.EnvironmentVariables[$variable + '_OVERRIDE'] = $(if ($explicit) { '1' } else { '0' })
}
# Smoke registers no physical shortcuts, leaving other desktop instances alone.
if ($Smoke) {
    $emptyKeys = Join-Path $profile 'runtime\smoke-keybinds.json'
    '{"binds":[]}' | Set-Content -LiteralPath $emptyKeys -Encoding UTF8
    $info.EnvironmentVariables['CAELESTIA_WINDOWS_KEYBINDS'] = $emptyKeys
}
# Do not inherit synthetic DPI or QPA settings from development/probe sessions,
# or Electron's run-as-node flags from an Electron host (they break Electron apps the shell launches).
foreach ($name in @('QT_SCALE_FACTOR', 'QT_SCREEN_SCALE_FACTORS', 'QT_FONT_DPI', 'QT_ENABLE_HIGHDPI_SCALING', 'QT_QPA_PLATFORM', 'ELECTRON_RUN_AS_NODE', 'ELECTRON_NO_ASAR')) {
    $info.EnvironmentVariables.Remove($name)
    [Environment]::SetEnvironmentVariable($name, $null, 'Process')
}

if ($Command -ne 'Start') {
    $info.Arguments = 'ipc --path "' + (Join-Path $stage 'shell.qml') + '" call shell ' + $Command.ToLowerInvariant()
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $output = ''
    $ipcFailure = $null
    try {
        $process = [Diagnostics.Process]::Start($info)
        $outTask = $process.StandardOutput.ReadToEndAsync()
        $errTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(10000)) { $process.Kill(); throw 'Shell IPC timed out.' }
        $output = $outTask.GetAwaiter().GetResult()
        $errors = $errTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw "Shell IPC failed: $output $errors" }
    } catch {
        # Quit must still reach a supervisor that is starting or in restart
        # backoff, when no shell exists to answer IPC.
        if ($Command -ne 'Quit') { throw }
        $ipcFailure = $_.Exception.Message
    }
    if ($Command -eq 'Quit') {
        # Let the supervisor restore its owned AppBars/taskbar before uninstall.
        # 60 s covers its bounded banner recovery (45 s) and desktop restore.
        $bound = 60000
        $supervisors = @(Get-CaelestiaSupervisors $profile)
        foreach ($supervisor in $supervisors) {
            $deadline = [DateTime]::UtcNow.AddMilliseconds($bound)
            # Startup is not interruptible until banner recovery finishes.
            while ($supervisor.Phase -eq 'starting' -and [DateTime]::UtcNow -lt $deadline -and -not $supervisor.Process.HasExited) {
                Start-Sleep -Milliseconds 250
                try { $supervisor.Phase = [string](Get-Content -LiteralPath $supervisor.StatusPath -Raw | ConvertFrom-Json).phase } catch { }
            }
            if ($supervisor.Process.HasExited) { continue }
            if ($ipcFailure -or $supervisor.Phase -ne 'running') {
                # No shell answered, so ask the supervisor itself to stop.
                if (-not ('Caelestia.Takeover.Native' -as [type])) {
                    Add-Type -Path (Join-Path $PSScriptRoot 'DesktopTakeover.cs') -ReferencedAssemblies System.Windows.Forms, System.Web.Extensions
                }
                [Caelestia.Takeover.Supervisor]::RecoverActive()
            }
            if (-not $supervisor.Process.WaitForExit([Math]::Max(1000, [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds))) {
                throw "Desktop supervisor has not finished restoring: $($supervisor.StatusPath)"
            }
        }
        if (-not $supervisors.Count) {
            if ($ipcFailure) { Write-Verbose "No running shell to quit: $ipcFailure" }
            $unrestored = Get-CaelestiaUnrestoredSnapshot $profile
            if ($unrestored) {
                & (Join-Path $PSScriptRoot 'Restore-Desktop.ps1') -SnapshotPath $unrestored.FullName | Out-Null
                Move-Item -LiteralPath $unrestored.FullName -Destination ($unrestored.FullName + '.adopted') -Force
            }
        }
        & (Join-Path $PSScriptRoot 'Banner-Suppression.ps1') -StateDirectory (Join-Path $profile 'state') -Command Restore
    }
    Write-Output $output
    return
}

$info.Arguments = '--no-duplicate --no-color --log-times --path "' + (Join-Path $stage 'shell.qml') + '"'
$stdoutPath = Join-Path $profile 'logs\shell.stdout.log'
$stderrPath = Join-Path $profile 'logs\shell.stderr.log'
foreach ($path in @($stdoutPath, $stderrPath)) { [IO.File]::WriteAllText($path, '') }
$supervisorConfig = Join-Path $profile 'config\windows.json'
$supervised = $null
if ($Smoke) {
    # A temporary install's read-only smoke can coexist with the live desktop
    # supervisor. Never acquire its takeover mutex or signal global recovery.
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.EnvironmentVariables['QS_DISABLE_CRASH_HANDLER'] = '1'
    $process = [Diagnostics.Process]::Start($info)
    $outTask = $process.StandardOutput.ReadToEndAsync()
    $errTask = $process.StandardError.ReadToEndAsync()
    Write-Output "Started Caelestia smoke PID $($process.Id). Profile: $profile"
} else {
    $supervised = & (Join-Path $PSScriptRoot 'Start-DesktopShell.ps1') -StartInfo $info `
        -StateDirectory (Join-Path $profile ('runtime\supervisor-' + [guid]::NewGuid().ToString('N'))) `
        -ConfigPath $supervisorConfig -StdoutPath $stdoutPath -StderrPath $stderrPath
    $process = $supervised.Watchdog
    Write-Output "Started supervised Caelestia. Profile: $profile; status: $($supervised.StatusPath)"
}
if (-not $Smoke -and -not $Wait) { return }
$timedOut = $false
if ($Smoke) {
    $timedOut = -not $process.WaitForExit(60000)
    if ($timedOut) { $process.Kill(); $process.WaitForExit() }
    [IO.File]::WriteAllText($stdoutPath, $outTask.GetAwaiter().GetResult())
    [IO.File]::WriteAllText($stderrPath, $errTask.GetAwaiter().GetResult())
    if (-not ('Caelestia.Takeover.Native' -as [type])) {
        Add-Type -Path (Join-Path $PSScriptRoot 'DesktopTakeover.cs') -ReferencedAssemblies System.Windows.Forms, System.Web.Extensions
    }
    # ABM_REMOVE only for this exited child, including a crash/timeout. Do not
    # restore global work-area snapshots or taskbars belonging to the live shell.
    [Caelestia.Takeover.Native]::RemoveStaleAppBars($process.Id) | Out-Null
} else { $process.WaitForExit() }
if ($timedOut) {
    throw "Caelestia smoke timed out awaiting IPC quit. See $profile\logs."
}
$output = [IO.File]::ReadAllText($stdoutPath)
$errors = [IO.File]::ReadAllText($stderrPath)
Write-Output "$output`n$errors"
$diagnostics = "$output`n$errors" -match '(?m)^(?:\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3})?\s*(WARN(?:ING)?|ERROR|FATAL|CRIT(?:ICAL)?)\b'
if ($process.ExitCode -ne 0 -or ($Smoke -and ($diagnostics -or -not $output.Contains('CAELESTIA_SHELL_LIVE_PASS')))) {
    throw "Caelestia failed (exit $($process.ExitCode)). See $profile\logs."
}
