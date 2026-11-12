[CmdletBinding()]
param(
    [string]$Prefix,
    [ValidateSet('Start', 'State', 'Quit', 'Restart', 'Settings', 'NotifyTest', 'AutostartStatus')][string]$Command = 'Start',
    # Quit only. Removes this installation's own HKCU Run entry before the
    # shell and supervisor hand the desktop back. The shell cannot wait for
    # that work after it exits, so its detached launcher passes this switch.
    [switch]$DisableAutostart,
    [switch]$Smoke,
    [ValidateRange(0, 15)][int]$ScreenIndex,
    [ValidateSet('Disabled', 'Observe', 'Interactive')][string]$TilingMode = 'Disabled',
    [string]$TilingIncluded = '',
    [string]$TilingExcluded = '',
    [switch]$SkipSchemeRuntime,
    # Activation only consumes a runtime the installer prepared before the
    # handoff; it must never run pip inside the readiness budget.
    [switch]$PreparedSchemeRuntime,
    [switch]$Wait
)

if ($Smoke -and $Command -ne 'Start') { throw '-Smoke requires -Command Start.' }
if ($PSBoundParameters.ContainsKey('ScreenIndex') -and -not $Smoke) { throw '-ScreenIndex requires -Smoke.' }
if ($DisableAutostart -and $Command -ne 'Quit') { throw '-DisableAutostart requires -Command Quit.' }

# Send through Windows, not notifySend()/QML. The existing WinRT listener will
# mirror this like any other app only if the user has already allowed mirroring.
# Does not read the profile or alter consent, settings or shell lifecycle.
if ($Command -eq 'NotifyTest') {
    if ($env:OS -ne 'Windows_NT') { throw 'NotifyTest requires an interactive Windows desktop.' }
    # PowerShell 7 has no built-in WinRT projection. Use inbox Windows PowerShell
    # without loading the user's PowerShell profile or changing execution policy.
    if ($PSVersionTable.PSEdition -eq 'Core') {
        & (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoLogo -NoProfile -NonInteractive -File $PSCommandPath -Command NotifyTest
        if ($LASTEXITCODE -ne 0) { throw 'Windows PowerShell could not submit the test toast.' }
        return
    }
    $ErrorActionPreference = 'Stop'
    $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
    $null = [Windows.UI.Notifications.ToastNotification, Windows.UI.Notifications, ContentType = WindowsRuntime]
    $null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
    # Reuse the inbox PowerShell shortcut's AUMID, as in Microsoft's Intune
    # toast example. Do not register a new identity or enable a disabled sender.
    # https://learn.microsoft.com/en-us/intune/device-management/tools/ref-remediation-scripts
    $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
    $notifier = [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId)
    if ($notifier.Setting.ToString() -ne 'Enabled') {
        throw 'Windows notifications for Windows PowerShell are disabled or unavailable. No settings were changed.'
    }
    $xml = [Windows.Data.Xml.Dom.XmlDocument]::new()
    $xml.LoadXml(@'
<toast><visual><binding template="ToastGeneric"><text>Caelestia test notification</text><text>This is a test notification. No user data is included.</text></binding></visual></toast>
'@)
    $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
    $notifier.Show($toast)
    Write-Output 'Test toast submitted to Windows as Windows PowerShell. Delivery is not confirmed; check the popup and notification history. Caelestia mirroring requires existing consent and opt-in.'
    return
}

. (Join-Path $PSScriptRoot 'Caelestia-InstallCommon.ps1')
if (-not $Prefix) {
    $Prefix = if (Test-Path -LiteralPath (Join-Path $PSScriptRoot 'install.json')) { $PSScriptRoot } else { Join-Path $env:LOCALAPPDATA 'Programs\caelestia-windows' }
}
$Prefix = Resolve-CaelestiaDirectory $Prefix
$record = Read-CaelestiaInstall $Prefix
# The autostart entry is owned by the stable prefix, never by a version
# payload. Answer and remove it before the versioned-route below can replace
# $Prefix with versions\<id> and hash the wrong Run name.
if ($Command -eq 'AutostartStatus') {
    [ordered]@{ schema = 1; enabled = (Test-CaelestiaAutostart $Prefix) } |
        ConvertTo-Json -Compress
    return
}
$autostartFailure = ''
if ($Command -eq 'Quit' -and $DisableAutostart) {
    # The user asked to leave Caelestia, so a failed Run-entry removal must not
    # cancel Quit or desktop restoration. Report it after the shell exits, then
    # fail the launcher call so the caller cannot mistake the choice as applied.
    $autostartFailure = Disable-CaelestiaAutostartForQuit $Prefix
}
# Repository callers can still target the stable root. Route before building
# a ProcessStartInfo so leftover legacy qs.exe files are never launched.
if ($record.version -eq 2) {
    $runtime = Resolve-CaelestiaRuntimePrefix $Prefix -Running:($Command -ne 'Start')
    if ($Command -eq 'Settings') {
        if ($Smoke) { throw '-Smoke requires -Command Start.' }
        $null = Invoke-CaelestiaIpc $runtime settings
        return
    }
    $arguments = @{}
    foreach ($key in $PSBoundParameters.Keys) {
        # The stable root already consumed this switch; the runtime prefix must
        # not compute a different, hashed Run name.
        if ($key -eq 'DisableAutostart') { continue }
        $arguments[$key] = $PSBoundParameters[$key]
    }
    $arguments.Prefix = $runtime
    try {
        & (Join-Path $runtime 'Start-Caelestia.ps1') @arguments
    } finally {
        # The versioned Quit has finished and the desktop is restored. The shell
        # has exited, so this launcher owns the visible report before it fails.
        if ($autostartFailure) { Show-CaelestiaHandoffDialog $autostartFailure }
    }
    # The stable root owns the Run entry. Re-raise its removal failure after the
    # versioned launcher has finished Quit and desktop restoration.
    if ($autostartFailure) { throw $autostartFailure }
    return
}
$installRoot = if ($record.installRoot) { [string]$record.installRoot } else { $Prefix }
$profile = Resolve-CaelestiaDirectory $record.profile
$stage = Join-Path $Prefix 'shell'
$exe = Join-Path $Prefix 'qs.exe'

# A healthy owner refreshes its status every tick. Only a stale owner of this
# profile is eligible for bounded recovery during Start.
if ($Command -eq 'Start' -and -not $Smoke) {
    Repair-CaelestiaStaleSupervisors $profile
}

# A normal restart is a transactional in-process reload: Quickshell retains
# existing windows until the new graph loads. Never quit/reinstall for this.
if ($Command -in @('State', 'Restart', 'Settings')) {
    if ($Command -eq 'State') { Invoke-CaelestiaIpc $Prefix state; return }
    if ($Command -eq 'Settings') { $null = Invoke-CaelestiaIpc $Prefix settings; return }
    $reloadClock = [Diagnostics.Stopwatch]::StartNew()
    $previous = (Invoke-CaelestiaIpc $Prefix restart).Trim()
    Write-Verbose ('Reload IPC acknowledged after {0:N3}s.' -f $reloadClock.Elapsed.TotalSeconds)
    # New shells return the retired generation with the restart acknowledgement,
    # saving a separate preflight IPC round trip. Old shells return no value.
    Wait-CaelestiaReady $Prefix -PreviousGeneration $previous -LegacyReady:([string]::IsNullOrEmpty($previous))
    Write-Verbose ('New generation rendered after {0:N3}s.' -f $reloadClock.Elapsed.TotalSeconds)
    Write-Output 'Caelestia reloaded in place.'
    return
}

if ($Command -eq 'Start') {
    # Automatically claim only an empty profile; pre-populated directories
    # without an existing marker are never auto-marked exclusive.
    if (-not (Read-CaelestiaProfileOwner $profile) -and (Test-CaelestiaProfileEmpty $profile)) {
        Write-CaelestiaProfileOwner $profile $installRoot $(if ($record.installId) { [string]$record.installId } else { [guid]::NewGuid().ToString('N') }) $true
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

$schemeRevision = ''
if ($Command -eq 'Start' -and -not $SkipSchemeRuntime) {
    try { $schemeRevision = Get-CaelestiaSchemeRevision $Prefix } catch { $schemeRevision = '' }
}
$schemeRuntime = $null
if ($Command -eq 'Start' -and -not $SkipSchemeRuntime) {
    if ($PreparedSchemeRuntime) {
        # Activation consumes only a completed generation for this payload's
        # pinned revision. Missing, failed or mismatched records keep the fixed
        # palette instead of provisioning inside the readiness budget.
        if ($schemeRevision) { $schemeRuntime = Get-CaelestiaPreparedSchemeRuntime $profile $schemeRevision $Prefix }
        if ($null -eq $schemeRuntime) {
            # The installer reports the failure while the previous version is
            # still live. Keep the new shell running on its fixed palette.
            Write-CaelestiaSchemeRuntimeLog -ProfileRoot $profile -Event 'scheme-runtime' `
                -Fields ([ordered]@{ state = 'unprepared'; action = 'fixed-palette' }) `
                -Message 'install or the next normal start can retry preparation'
        }
    } else {
        # A valid published generation needs no provisioning. Otherwise try to
        # repair without waiting; a busy lock keeps the fixed palette, and the
        # shell stays on it until the next shell start (a start never waits for
        # a provisioner that is already running). -Verify runs the venv's
        # python, so a lost base interpreter is repaired here, not trusted.
        if ($schemeRevision) { $schemeRuntime = Get-CaelestiaPreparedSchemeRuntime $profile $schemeRevision $Prefix -Verify }
        if ($null -eq $schemeRuntime) {
            try {
                $schemeResult = & (Join-Path $PSScriptRoot 'Install-SchemeRuntime.ps1') -ProfileRoot $profile -LockWaitSeconds 0 |
                    Select-Object -Last 1 | ConvertFrom-Json
                if ($schemeResult -and $schemeResult.available -eq $true -and
                    (-not $schemeRevision -or [string]$schemeResult.revision -eq $schemeRevision)) {
                    $schemeRuntime = $schemeResult
                } elseif ($schemeResult -and $schemeResult.inProgress -eq $true) {
                    Write-CaelestiaSchemeRuntimeLog -ProfileRoot $profile -Event 'scheme-runtime' `
                        -Fields ([ordered]@{ state = 'provisioning'; action = 'fixed-palette' }) `
                        -Message 'another provisioning run is in progress; retry on the next normal start'
                }
            } catch {
                Write-CaelestiaSchemeRuntimeLog -ProfileRoot $profile -Event 'scheme-runtime' `
                    -Fields ([ordered]@{ state = 'prepare-error'; action = 'fixed-palette' }) -Message $_.Exception.Message
            }
        }
    }
}
$schemeAvailable = $null -ne $schemeRuntime -and $schemeRuntime.available -eq $true
# Starting the shell never launches Python or any discovery process. The
# Wallpaper Engine bridge's interpreter was resolved while preparing and is
# only read back from runtime.json; with nothing recorded the feature is
# unavailable for this start. This holds for -SkipSchemeRuntime too.
$wePython = if ($schemeAvailable) { [string]$schemeRuntime.python }
    elseif ($Command -eq 'Start') { Get-CaelestiaSchemeInterpreter $profile }
    else { '' }

$info = New-Object Diagnostics.ProcessStartInfo
$info.FileName = $exe
# Launcher apps and helpers inherit this directory. Never pin an updatable
# payload, and let terminals open in the same home directory as Explorer apps.
$info.WorkingDirectory = $env:USERPROFILE
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
$info.EnvironmentVariables['CAELESTIA_INSTALL_ROOT'] = $installRoot
$info.EnvironmentVariables['CAELESTIA_VERSION_ID'] = [string]$record.versionId
$info.EnvironmentVariables['CAELESTIA_SOURCE_REVISION'] = [string]$record.sourceRevision
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
    $errors = ''
    $ipcFailure = $null
    try {
        $process = [Diagnostics.Process]::Start($info)
        $outTask = $process.StandardOutput.ReadToEndAsync()
        $errTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(10000)) { $process.Kill(); throw 'Shell IPC timed out.' }
        $output = $outTask.GetAwaiter().GetResult()
        # Consume diagnostics, but never echo shell state or user data on failure.
        $errors = $errTask.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw "Shell IPC $Command failed (exit $($process.ExitCode)). See the profile logs." }
    } catch {
        # Partially captured IPC output can contain shell state or user data.
        # Clear it before Quit recovery, which continues and later emits output.
        $output = ''
        $errors = ''
        # Quit must still reach a supervisor that is starting or in restart
        # backoff, when no shell exists to answer IPC.
        if ($Command -ne 'Quit') { throw }
        $ipcFailure = $_.Exception.Message
    }
    if ($Command -eq 'Quit') {
        # Let the supervisor restore its owned AppBars/taskbar before uninstall.
        # 60 s covers child exit grace (5 s), log drain (2 s), bounded banner
        # recovery (45 s) and desktop restore.
        $bound = 60000
        $supervisors = @(Get-CaelestiaSupervisors $profile)
        foreach ($supervisor in $supervisors) {
            $deadline = [DateTime]::UtcNow.AddMilliseconds($bound)
            if ($supervisor.Process.HasExited) { continue }
            # IPC acceptance does not mean qs has exited. Always notify the
            # supervisor so it can bound the wait for its own child. Its event
            # exists before "starting" is published, including banner recovery.
            if (-not ('Caelestia.Takeover.Native' -as [type])) {
                Add-Type -Path (Join-Path $PSScriptRoot 'DesktopTakeover.cs') -ReferencedAssemblies System.Windows.Forms, System.Web.Extensions
            }
            Stop-CaelestiaSupervisor $supervisor
            if (-not $supervisor.Process.WaitForExit([Math]::Max(1000, [int]($deadline - [DateTime]::UtcNow).TotalMilliseconds))) {
                throw "Desktop supervisor has not finished restoring: $($supervisor.StatusPath)"
            }
        }
        if (-not @(Get-CaelestiaSupervisors $profile).Count) {
            if ($ipcFailure) { Write-Verbose "No running shell to quit: $ipcFailure" }
            $unrestored = Get-CaelestiaUnrestoredSnapshot $profile
            if ($unrestored) {
                & (Join-Path $PSScriptRoot 'Restore-Desktop.ps1') -SnapshotPath $unrestored.FullName -InactiveOnly | Out-Null
                if (-not [Caelestia.Takeover.Native]::ExplorerWorkDeferred) {
                    Move-Item -LiteralPath $unrestored.FullName -Destination ($unrestored.FullName + '.adopted') -Force
                }
            }
        }
        # Without a journal there is nothing to restore. Skipping it avoids the
        # session-wide helper mutex that another install's live worker holds.
        if (Test-Path -LiteralPath (Join-Path $profile 'state\banner-suppression.json')) {
            & (Join-Path $PSScriptRoot 'Banner-Suppression.ps1') -StateDirectory (Join-Path $profile 'state') -Command Restore
        }
    }
    Write-Output $output
    if ($autostartFailure) {
        # Quit and desktop restoration are complete and the shell is gone, so
        # this launcher shows the report before failing the call.
        Show-CaelestiaHandoffDialog $autostartFailure
        throw $autostartFailure
    }
    return
}

$info.Arguments = '--no-duplicate --no-color --log-times --path "' + (Join-Path $stage 'shell.qml') + '"'
# Rotate the live shell's logs so the previous session's crash output survives.
# Smoke writes its own files, so it cannot rotate away the live session's logs.
$logName = if ($Smoke) { 'shell.smoke' } else { 'shell' }
$stdoutPath = Join-Path $profile "logs\$logName.stdout.log"
$stderrPath = Join-Path $profile "logs\$logName.stderr.log"
if (-not $Smoke) {
    Move-CaelestiaLogToPrevious $stdoutPath
    Move-CaelestiaLogToPrevious $stderrPath
}
$supervisorConfig = Join-Path $profile 'config\windows.json'
$supervised = $null
if ($Smoke) {
    # A temporary install's read-only smoke can coexist with the live desktop
    # supervisor. Never acquire its takeover mutex or signal global recovery.
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.EnvironmentVariables['QS_DISABLE_CRASH_HANDLER'] = '1'
    # This direct path never hides Explorer's taskbar, so the shell must not
    # filter its taskbar shortcuts even when the caller's environment does.
    $info.EnvironmentVariables.Remove('QS_WINDOWS_TASKBAR_SHORTCUT_FILTER')
    $process = [Diagnostics.Process]::Start($info)
    $outTask = $process.StandardOutput.ReadToEndAsync()
    $errTask = $process.StandardError.ReadToEndAsync()
    Write-Output "Started Caelestia smoke PID $($process.Id). Profile: $profile"
} else {
    $supervised = & (Join-Path $PSScriptRoot 'Start-DesktopShell.ps1') -StartInfo $info `
        -StateDirectory (Join-Path $profile ('runtime\supervisor-' + [guid]::NewGuid().ToString('N'))) `
        -ConfigPath $supervisorConfig -StdoutPath $stdoutPath -StderrPath $stderrPath
    $process = $supervised.Watchdog
    Wait-CaelestiaReady $Prefix
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
