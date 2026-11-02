[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QtPrefix,
    [string]$BuildRoot,
    # Optional shared M1 result cache; one path per suite invocation.
    [string]$M1CachePath
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
if (-not $BuildRoot) { $BuildRoot = Join-Path $repoRoot 'windows\.local\build' }
$BuildRoot = [IO.Path]::GetFullPath($BuildRoot)
$output = Join-Path $BuildRoot ('brightness-validation-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff'))
New-Item -ItemType Directory -Force -Path $output | Out-Null
$records = New-Object Collections.Generic.List[object]
$failure = $null

function Get-DesktopSnapshot([string]$Name) {
    & "$PSScriptRoot\Get-DesktopState.ps1" -OutputPath (Join-Path $output "$Name.json") | ConvertFrom-Json
}
function Assert($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Desktop-Identity($State) {
    # Foreground/cursor movement and unrelated application processes are outside
    # this read-only gate. qs/quickshell processes are excluded because other
    # agents may run their own prototype smokes concurrently; the leak check
    # below owns this harness's own process.
    [ordered]@{
        monitors = $State.monitors
        taskbar = $State.taskbar
        explorerRunning = $State.explorerRunning
        processes = @($State.relevantProcesses | Where-Object { $_.name -notin @('qs', 'quickshell') })
    } | ConvertTo-Json -Depth 10 -Compress
}
function Brightness-Policy($State) {
    [ordered]@{
        status = $State.status; enabled = $State.enabled
        controlsEnabled = $State.controlsEnabled
        softwareEnabled = $State.softwareEnabled
        backendLoaded = $State.backendLoaded
        nativeRequested = $State.nativeRequested
        nativeBackendId = $State.nativeBackendId
        ready = $State.ready; lastError = $State.lastError
        writeRequests = $State.writeRequests
        everWrote = $State.everWrote; gammaTouched = $State.gammaTouched
        refusedWrites = $State.refusedWrites
        autoObservationDone = $State.autoObservationDone
        osdLoaded = $State.osdLoaded
        osdControlsEnabled = $State.osdControlsEnabled
        osdAudioControlsEnabled = $State.osdAudioControlsEnabled
        selectedScreen = $State.selectedScreen
        selectedCapability = $State.selectedCapability
        selectedRoute = $State.selectedRoute
        selectedWritable = $State.selectedWritable
        monitors = @($State.monitors | ForEach-Object {
            [ordered]@{
                screen = $_.screen; capability = $_.capability; route = $_.route
                writable = $_.writable; latched = $_.latched
            }
        })
    } | ConvertTo-Json -Depth 10 -Compress
}
function Assert-NoWrites($State, [string]$Where) {
    Assert (-not $State.controlsEnabled) "$Where enabled brightness controls."
    Assert (-not $State.softwareEnabled) "$Where enabled software gamma."
    Assert ($State.writeRequests -eq 0) "$Where sent a write request."
    Assert (-not $State.everWrote) "$Where ever wrote brightness."
    Assert (-not $State.gammaTouched) "$Where touched the gamma ramp."
    Assert ($State.refusedWrites -eq 0) "$Where refused an unexpected write."
}
function Assert-Routes($State, [string]$Where) {
    Assert ($State.monitorCount -gt 0) "$Where has no monitor states."
    Assert ($State.monitorCount -eq @($State.monitors).Count) "$Where monitor count is inconsistent."
    foreach ($monitor in $State.monitors) {
        Assert ($monitor.capability -notin @('unknown', 'querying')) "$Where did not settle $($monitor.screen): $($monitor.capability)"
        if ($monitor.capability -eq 'hardware') {
            Assert ($monitor.route -in @('wmi', 'lcd', 'ddc')) "$Where hardware route is invalid for $($monitor.screen)."
            Assert ($monitor.available -and $monitor.brightnessKnown) "$Where hardware route lacks a level for $($monitor.screen)."
            Assert ($monitor.brightness -ge 0 -and $monitor.brightness -le 1) "$Where brightness is out of range for $($monitor.screen)."
        } elseif ($monitor.capability -eq 'software-only') {
            Assert ($monitor.route -eq 'software') "$Where software route is invalid for $($monitor.screen)."
            Assert (-not $monitor.writable) "$Where software-only route is writable without its opt-in."
        } elseif ($monitor.capability -eq 'failed') {
            Assert ($monitor.route -in @('wmi', 'lcd', 'ddc')) "$Where failed route is invalid for $($monitor.screen)."
            Assert ($monitor.lastError.Length -gt 0) "$Where failed route has no reason for $($monitor.screen)."
            Assert (-not $monitor.writable) "$Where failed route is writable for $($monitor.screen)."
        } else {
            Assert ($monitor.route -eq '') "$Where unsupported route invented a method for $($monitor.screen)."
            Assert (-not $monitor.writable) "$Where unsupported route is writable for $($monitor.screen)."
        }
    }
}

# Gamma ramps are read through GetDeviceGammaRamp. This is a net-state check,
# not proof that no write happened: GammaController restores its ramps on
# aboutToQuit, and a write followed by restoration would leave the same final
# hash. The service-level write counters above are the write evidence; the hash
# shows only that the desktop's gamma was left as it was found. Unsupported
# reads are recorded and skipped rather than treated as a failure.
if (-not ('Caelestia.BrightnessGamma.Native' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Security.Cryptography;

namespace Caelestia.BrightnessGamma {
    public static class Native {
        [DllImport("gdi32.dll", CharSet = CharSet.Unicode)]
        private static extern IntPtr CreateDCW(string driver, string device, string port, IntPtr initData);
        [DllImport("gdi32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetDeviceGammaRamp(IntPtr hdc, ushort[] ramp);
        [DllImport("gdi32.dll")]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool DeleteDC(IntPtr hdc);

        public static string Capture(string device) {
            IntPtr dc = CreateDCW("DISPLAY", device, null, IntPtr.Zero);
            if (dc == IntPtr.Zero)
                return "no-device-context";
            try {
                ushort[] ramp = new ushort[3 * 256];
                if (!GetDeviceGammaRamp(dc, ramp))
                    return "unsupported:" + Marshal.GetLastWin32Error();
                using (SHA256 sha = SHA256.Create()) {
                    byte[] bytes = new byte[ramp.Length * 2];
                    Buffer.BlockCopy(ramp, 0, bytes, 0, bytes.Length);
                    return BitConverter.ToString(sha.ComputeHash(bytes)).Replace("-", "").ToLowerInvariant();
                }
            } finally {
                DeleteDC(dc);
            }
        }
    }
}
'@
}
function Get-GammaSnapshot($DesktopSnapshot, [string]$Name) {
    $ramps = @(
        foreach ($monitor in $DesktopSnapshot.monitors) {
            [ordered]@{
                deviceName = $monitor.deviceName
                rampSha256 = [Caelestia.BrightnessGamma.Native]::Capture($monitor.deviceName)
            }
        }
    )
    $result = [ordered]@{ capturedAtUtc = [DateTime]::UtcNow.ToString('o'); ramps = $ramps }
    $result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $output "$Name.json") -Encoding UTF8
    $result
}

$beforeDesktop = Get-DesktopSnapshot 'desktop-before'
$beforeGamma = Get-GammaSnapshot $beforeDesktop 'gamma-before'
try {
    $fixture = & "$PSScriptRoot\Test-BrightnessService.ps1" -QtPrefix $QtPrefix -BuildRoot $BuildRoot | ConvertFrom-Json
    Assert $fixture.passed 'Adapter fixtures failed.'
    $records.Add([ordered]@{ kind = 'fixture'; result = $fixture })
    $screenCount = $beforeDesktop.monitors.Count
    Assert ($screenCount -gt 0) 'No measured monitor available.'
    # Native screen selection is explicit. The parent runs this harness on the
    # desktop; the smoke itself never sends input and never writes brightness.
    for ($screen = 0; $screen -lt $screenCount; $screen++) {
        foreach ($mode in @('Disabled', 'ReadOnly')) {
            $result = & "$PSScriptRoot\Start-ShellPrototype.ps1" -QtPrefix $QtPrefix -BuildRoot $BuildRoot `
                -Brightness -BrightnessMode $mode -Smoke -ScaleFactor native -ScreenIndex $screen | ConvertFrom-Json
            Assert $result.passed "Brightness UI failed on screen $screen in $mode mode."
            $records.Add([ordered]@{ kind = 'brightness'; result = $result })
            Assert ($result.brightnessSnapshots.Count -eq 2) 'Brightness smoke did not record initial and final state.'
            $initial = $result.brightnessSnapshots[0].state
            $final = $result.brightnessSnapshots[1].state
            Assert-NoWrites $initial "screen $screen $mode initial"
            Assert-NoWrites $final "screen $screen $mode final"
            Assert ($initial.enabled -eq ($mode -ne 'Disabled')) 'Brightness observation opt-in does not match the requested mode.'
            if ($mode -eq 'Disabled') {
                $disabledClean = ($initial.status -eq 'disabled') -and (-not $initial.nativeRequested) -and (-not $initial.backendLoaded) -and (-not $initial.osdLoaded) -and ($initial.selectedCapability -eq 'unknown') -and ($initial.queryRequests -eq 0)
                Assert $disabledClean 'Disabled mode constructed the backend or original component.'
                foreach ($monitor in $initial.monitors) {
                    Assert ($monitor.capability -eq 'unknown' -and $monitor.route -eq '') 'Disabled mode probed or invented a route.'
                }
                $nativeBrightnessLogs = @(Select-String -LiteralPath $result.stdout -Pattern 'quickshell\.windows\.brightness|Brightness change events')
                Assert ($nativeBrightnessLogs.Count -eq 0) 'Disabled mode logged native brightness activity.'
            } else {
                Assert ($initial.status -eq 'observing') "Brightness service did not settle: $($initial.status) ($($initial.reason))"
                Assert $initial.nativeRequested 'Enabled mode did not activate the native backend loader.'
                Assert $initial.backendLoaded 'Enabled mode did not load the native facade.'
                Assert ($initial.nativeBackendId -eq 'Quickshell.Windows.Brightness') 'Unexpected native backend identity.'
                Assert $initial.osdLoaded 'Enabled mode did not load the original OSD content.'
                Assert (-not $initial.osdAudioControlsEnabled) 'Staged audio rows were not disabled.'
                Assert (-not $initial.selectedWritable) 'Read-only smoke left the selected monitor writable.'
                Assert ($initial.queryRequests -ge $initial.monitorCount) 'Read-only observation did not query every monitor.'
                Assert-Routes $initial "screen $screen ReadOnly initial"
                Assert-Routes $final "screen $screen ReadOnly final"
                Assert (@($result.brightnessRoutes).Count -eq $initial.monitorCount) 'Recorded routes do not cover every monitor.'
            }
            Assert ((Brightness-Policy $initial) -eq (Brightness-Policy $final)) 'Brightness policy or route identity changed during the read-only smoke.'
        }
    }
    $regression = & "$PSScriptRoot\Caelestia-M1Regression.ps1" -QtPrefix $QtPrefix -BuildRoot $BuildRoot `
        -CachePath $M1CachePath
    Assert $regression.passed 'Original M1 bar/session smoke regression failed.'
    $records.Add([ordered]@{ kind = 'm1-regression'; result = $regression })
} catch {
    $failure = $_.ToString()
} finally {
    $afterDesktop = Get-DesktopSnapshot 'desktop-after'
    $afterGamma = Get-GammaSnapshot $afterDesktop 'gamma-after'
}
try {
    Assert ((Desktop-Identity $beforeDesktop) -eq (Desktop-Identity $afterDesktop)) 'Shell processes, work areas or taskbar state changed.'
    # A leaked prototype would carry the staged shell path in its command line.
    # The harness's own command line may mention "brightness-prototype" in log
    # names, so match the generated run directory instead.
    $leaked = @(Get-CimInstance Win32_Process |
        Where-Object { $_.CommandLine -and $_.CommandLine -match 'shell-runs[\\/]brightness-' })
    Assert ($leaked.Count -eq 0) 'A brightness prototype process remained after the runs.'
    foreach ($before in $beforeGamma.ramps) {
        $after = @($afterGamma.ramps | Where-Object { $_.deviceName -eq $before.deviceName })
        Assert ($after.Count -eq 1) "Gamma ramp for $($before.deviceName) was not captured after the runs."
        if ($before.rampSha256 -match '^[0-9a-f]{64}$' -and $after[0].rampSha256 -match '^[0-9a-f]{64}$') {
            Assert ($before.rampSha256 -eq $after[0].rampSha256) "Gamma ramp changed for $($before.deviceName)."
        }
    }
} catch {
    if ($failure) { $failure += "`n" + $_.ToString() } else { $failure = $_.ToString() }
}
$summary = [ordered]@{
    passed = -not [bool]$failure; failure = $failure
    sourceRevision = (& git -C $repoRoot rev-parse HEAD).Trim()
    sourceDirty = [bool](& git -C $repoRoot status --porcelain)
    backendRevision = (& git -C "$repoRoot\windows\deps\quickshell" rev-parse HEAD).Trim()
    measurementSources = @('Get-DesktopState.ps1', 'Test-BrightnessService.ps1', 'Test-BrightnessPrototype.ps1') | ForEach-Object {
        [ordered]@{ source = "windows/scripts/$_"; sha256 = (Get-FileHash -LiteralPath (Join-Path $PSScriptRoot $_)).Hash }
    }
    gammaBefore = $beforeGamma; gammaAfter = $afterGamma
    output = $output; records = @($records.ToArray())
}
$summary | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $output 'result.json') -Encoding UTF8
[ordered]@{ passed = $summary.passed; failure = $failure; output = $output; runs = $records.Count } | ConvertTo-Json
if ($failure) { throw $failure }
