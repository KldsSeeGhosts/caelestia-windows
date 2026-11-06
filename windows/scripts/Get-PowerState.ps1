[CmdletBinding()]
param(
    [string]$OutputPath
)

# Read-only native power observation for before/after comparisons. No setting,
# scheme, overlay, or plan is queried through a mutating command; powercfg is
# invoked with /getactivescheme only.
$ErrorActionPreference = 'Stop'
if (-not ('Caelestia.PowerSnapshot.Native' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace Caelestia.PowerSnapshot {
    public static class Native {
        [StructLayout(LayoutKind.Sequential)]
        public struct SystemPowerStatus {
            public byte ACLineStatus;        // 0 offline, 1 online, 255 unknown
            public byte BatteryFlag;         // 128 no battery, 255 unknown
            public byte BatteryLifePercent;  // 0-100, 255 unknown
            public byte Reserved1;
            public uint BatteryLifeTime;     // seconds, uint.MaxValue unknown
            public uint BatteryFullLifeTime; // seconds, uint.MaxValue unknown
        }

        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool GetSystemPowerStatus(out SystemPowerStatus status);

        [DllImport("powrprof.dll")]
        public static extern uint PowerGetEffectiveOverlayScheme(out Guid scheme);

        public static SystemPowerStatus? CaptureStatus() {
            SystemPowerStatus status;
            return GetSystemPowerStatus(out status) ? (SystemPowerStatus?)status : null;
        }
    }
}
'@
}

$warnings = @()
$native = [Caelestia.PowerSnapshot.Native]::CaptureStatus()
if (-not $native) {
    $warnings += 'GetSystemPowerStatus failed; battery presence cannot be measured.'
}

$overlayGuid = [Guid]::Empty
$overlayResult = [Caelestia.PowerSnapshot.Native]::PowerGetEffectiveOverlayScheme([ref]$overlayGuid)
if ($overlayResult -ne 0) {
    $warnings += "PowerGetEffectiveOverlayScheme failed with $overlayResult."
}
$overlayName = switch ($overlayGuid.ToString('D')) {
    '961cc777-2547-4f9d-8174-7d86181b8a7a' { 'Best efficiency (Power saver)' }
    'ded574b5-45a0-4f42-8737-46345c09c238' { 'Best performance' }
    default { 'Balanced overlay' }
}

# Base power scheme. This is the write target of plan changes, not of the
# backend's overlay-scheme profile selection; both are recorded.
$activeScheme = [ordered]@{ guid = $null; name = $null }
try {
    $schemeLine = (powercfg /getactivescheme 2>&1 | Out-String).Trim()
    $schemeGuid = [regex]::Match($schemeLine, '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}').Value
    $schemeName = [regex]::Match($schemeLine, '\(([^)]*)\)').Groups[1].Value
    if (-not $schemeGuid) { $warnings += 'powercfg /getactivescheme did not report a GUID.' }
    $activeScheme.guid = $schemeGuid
    $activeScheme.name = $schemeName
} catch {
    $warnings += "powercfg /getactivescheme failed: $($_.Exception.Message)"
}

# Independent battery enumeration. CIM queries are read-only; a missing WMI
# service is recorded, not treated as proof about hardware.
$batteries = @()
try {
    $batteries = @(
        Get-CimInstance -ClassName Win32_Battery -ErrorAction Stop | ForEach-Object {
            [ordered]@{
                name = $_.Name
                batteryStatus = $_.BatteryStatus
                estimatedChargeRemainingPercent = $_.EstimatedChargeRemaining
                estimatedRunTimeMinutes = $_.EstimatedRunTime
            }
        }
    )
} catch {
    $warnings += "Win32_Battery query failed: $($_.Exception.Message)"
}

$status = $null
if ($native) {
    $status = [ordered]@{
        acLineStatus = $native.ACLineStatus
        acOnline = $native.ACLineStatus -eq 1
        batteryFlag = $native.BatteryFlag
        batteryPresent = $native.BatteryFlag -ne 128 -and $native.BatteryFlag -ne 255
        batteryLifePercent = $native.BatteryLifePercent
        batteryLifeTimeSeconds = $(if ($native.BatteryLifeTime -eq [uint32]::MaxValue) { $null } else { $native.BatteryLifeTime })
        batteryFullLifeTimeSeconds = $(if ($native.BatteryFullLifeTime -eq [uint32]::MaxValue) { $null } else { $native.BatteryFullLifeTime })
    }
}

# Stable identity for before/after equality. BatteryLifePercent moves in whole
# percent steps; a charging or discharging machine may therefore report an
# honest drift failure instead of silently passing.
$identity = [ordered]@{
    activeSchemeGuid = $activeScheme.guid
    activeSchemeName = $activeScheme.name
    overlaySchemeGuid = $(if ($overlayResult -eq 0) { $overlayGuid.ToString('D') } else { $null })
    overlaySchemeName = $(if ($overlayResult -eq 0) { $overlayName } else { $null })
    acLineStatus = $(if ($native) { $native.ACLineStatus } else { $null })
    batteryPresent = $(if ($native) { $status.batteryPresent } else { $null })
    batteryLifePercent = $(if ($native) { $native.BatteryLifePercent } else { $null })
}

$result = [ordered]@{
    capturedAtUtc = [DateTime]::UtcNow.ToString('o')
    identity = $identity
    systemPowerStatus = $status
    overlayScheme = [ordered]@{
        query = 'PowerGetEffectiveOverlayScheme'
        guid = $identity.overlaySchemeGuid
        name = $identity.overlaySchemeName
        note = 'This is the write target of backend PowerProfiles profile selection.'
    }
    activeScheme = [ordered]@{
        query = 'powercfg /getactivescheme'
        guid = $activeScheme.guid
        name = $activeScheme.name
        note = 'Base power plan; the write target of plan changes.'
    }
    batteries = $batteries
    warnings = @($warnings)
    measurement = 'Read-only observation: GetSystemPowerStatus, PowerGetEffectiveOverlayScheme, powercfg /getactivescheme and a Win32_Battery CIM query. No setting or plan is written.'
}
$json = $result | ConvertTo-Json -Depth 6
if ($OutputPath) {
    $OutputPath = [IO.Path]::GetFullPath($OutputPath)
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutputPath) | Out-Null
    [IO.File]::WriteAllText($OutputPath, $json + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
}
Write-Output $json
