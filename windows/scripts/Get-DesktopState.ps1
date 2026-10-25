[CmdletBinding()]
param(
    [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
if (-not ('Caelestia.DesktopSnapshot.Native' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace Caelestia.DesktopSnapshot {
    public static class Native {
        [StructLayout(LayoutKind.Sequential)]
        public struct Rect {
            public int Left, Top, Right, Bottom;
        }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
        private struct MonitorInfo {
            public int Size;
            public Rect Monitor, Work;
            public uint Flags;
            [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
            public string Device;
        }
        [StructLayout(LayoutKind.Sequential)]
        private struct AppBarData {
            public uint Size;
            public IntPtr Window;
            public uint CallbackMessage, Edge;
            public Rect Bounds;
            public IntPtr Parameter;
        }
        public sealed class Monitor {
            public string DeviceName;
            public bool Primary;
            public Rect PhysicalBounds, PhysicalWorkArea;
            public int? ScalePercent;
            public double? LogicalWidthAt96Dpi, LogicalHeightAt96Dpi;
            public double? LogicalWorkWidthAt96Dpi, LogicalWorkHeightAt96Dpi;
        }
        public sealed class Result {
            public List<Monitor> Monitors = new List<Monitor>();
            public List<string> Warnings = new List<string>();
            public bool PhysicalCoordinates;
            public ulong TaskbarStateFlags;
            public bool TaskbarAutoHide, TaskbarAlwaysOnTop;
            public uint ForegroundProcessId;
            public long ForegroundWindow;
        }

        private delegate bool MonitorCallback(IntPtr monitor, IntPtr dc, ref Rect bounds, IntPtr data);
        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool EnumDisplayMonitors(IntPtr dc, IntPtr clip, MonitorCallback callback, IntPtr data);
        [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool GetMonitorInfo(IntPtr monitor, ref MonitorInfo info);
        [DllImport("user32.dll", SetLastError = true)]
        private static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);
        [DllImport("shcore.dll")]
        private static extern int GetScaleFactorForMonitor(IntPtr monitor, out int scale);
        [DllImport("shell32.dll")]
        private static extern UIntPtr SHAppBarMessage(uint message, ref AppBarData data);
        [DllImport("user32.dll")]
        private static extern IntPtr GetForegroundWindow();
        [DllImport("user32.dll")]
        private static extern uint GetWindowThreadProcessId(IntPtr window, out uint process);

        public static Result Capture() {
            Result result = new Result();
            // Change only this calling thread's measurement context and restore
            // it in finally. No window, display, or persistent settings change.
            IntPtr previous = SetThreadDpiAwarenessContext(new IntPtr(-4));
            result.PhysicalCoordinates = previous != IntPtr.Zero;
            if (!result.PhysicalCoordinates)
                result.Warnings.Add("Could not select a per-monitor DPI measurement context; bounds may be virtualized.");
            try {
                MonitorCallback callback = delegate(IntPtr handle, IntPtr dc, ref Rect bounds, IntPtr data) {
                    MonitorInfo info = new MonitorInfo();
                    info.Size = Marshal.SizeOf(typeof(MonitorInfo));
                    if (!GetMonitorInfo(handle, ref info)) {
                        result.Warnings.Add("GetMonitorInfo failed: " + Marshal.GetLastWin32Error());
                        return true;
                    }
                    Monitor monitor = new Monitor {
                        DeviceName = info.Device, Primary = (info.Flags & 1) != 0,
                        PhysicalBounds = info.Monitor, PhysicalWorkArea = info.Work
                    };
                    int scale;
                    int scaleResult = GetScaleFactorForMonitor(handle, out scale);
                    if (scaleResult == 0 && scale > 0) {
                        monitor.ScalePercent = scale;
                        // Size only: scaling each monitor's desktop origin
                        // independently would invent a logical desktop layout.
                        monitor.LogicalWidthAt96Dpi = (info.Monitor.Right - info.Monitor.Left) * 100.0 / scale;
                        monitor.LogicalHeightAt96Dpi = (info.Monitor.Bottom - info.Monitor.Top) * 100.0 / scale;
                        monitor.LogicalWorkWidthAt96Dpi = (info.Work.Right - info.Work.Left) * 100.0 / scale;
                        monitor.LogicalWorkHeightAt96Dpi = (info.Work.Bottom - info.Work.Top) * 100.0 / scale;
                    } else {
                        result.Warnings.Add("GetScaleFactorForMonitor failed for " + info.Device + ": " + scaleResult);
                    }
                    result.Monitors.Add(monitor);
                    return true;
                };
                if (!EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, callback, IntPtr.Zero))
                    result.Warnings.Add("EnumDisplayMonitors failed: " + Marshal.GetLastWin32Error());
            } finally {
                if (previous != IntPtr.Zero) SetThreadDpiAwarenessContext(previous);
            }
            AppBarData appBar = new AppBarData();
            appBar.Size = (uint)Marshal.SizeOf(typeof(AppBarData));
            result.TaskbarStateFlags = SHAppBarMessage(4, ref appBar).ToUInt64(); // ABM_GETSTATE
            result.TaskbarAutoHide = (result.TaskbarStateFlags & 1) != 0;
            result.TaskbarAlwaysOnTop = (result.TaskbarStateFlags & 2) != 0;
            IntPtr foreground = GetForegroundWindow();
            result.ForegroundWindow = foreground.ToInt64();
            GetWindowThreadProcessId(foreground, out result.ForegroundProcessId);
            return result;
        }
    }
}
'@
}

$native = [Caelestia.DesktopSnapshot.Native]::Capture()
function ConvertTo-Rectangle($Rect) {
    [ordered]@{
        left = $Rect.Left; top = $Rect.Top; right = $Rect.Right; bottom = $Rect.Bottom
        width = $Rect.Right - $Rect.Left; height = $Rect.Bottom - $Rect.Top
    }
}
$monitors = @(
    foreach ($monitor in $native.Monitors) {
        [ordered]@{
            deviceName = $monitor.DeviceName
            primary = $monitor.Primary
            physicalBounds = ConvertTo-Rectangle $monitor.PhysicalBounds
            physicalWorkArea = ConvertTo-Rectangle $monitor.PhysicalWorkArea
            scalePercent = $monitor.ScalePercent
            logicalSizeAt96Dpi = [ordered]@{
                width = $monitor.LogicalWidthAt96Dpi; height = $monitor.LogicalHeightAt96Dpi
            }
            logicalWorkAreaSizeAt96Dpi = [ordered]@{
                width = $monitor.LogicalWorkWidthAt96Dpi; height = $monitor.LogicalWorkHeightAt96Dpi
            }
        }
    }
)
# Names/PIDs only. Do not collect unrelated window captions or command lines.
$relevantNames = @('explorer', 'qs', 'quickshell', 'ksg-shell', 'ksg_shell', 'ksgshell', 'komorebi', 'glazewm', 'yasb')
$processes = @(
    Get-Process | Where-Object { $_.ProcessName -in $relevantNames } |
        Sort-Object ProcessName, Id | ForEach-Object {
            [ordered]@{ name = $_.ProcessName; pid = $_.Id }
        }
)
$result = [ordered]@{
    capturedAtUtc = [DateTime]::UtcNow.ToString('o')
    physicalCoordinates = $native.PhysicalCoordinates
    coordinateNotes = 'Physical monitor/work rectangles preserve negative origins. Logical sizes are derived from monitor scale; no synthetic logical desktop origins are assigned.'
    monitors = $monitors
    explorerRunning = @($processes | Where-Object { $_.name -eq 'explorer' }).Count -gt 0
    taskbar = [ordered]@{
        query = 'SHAppBarMessage ABM_GETSTATE'
        stateFlags = $native.TaskbarStateFlags
        autoHide = $native.TaskbarAutoHide
        alwaysOnTop = $native.TaskbarAlwaysOnTop
        scope = 'Shell taskbar state, not individual secondary taskbar visibility'
    }
    relevantProcesses = $processes
    foreground = [ordered]@{ pid = $native.ForegroundProcessId; windowId = $native.ForegroundWindow }
    warnings = @($native.Warnings.ToArray())
}
$json = $result | ConvertTo-Json -Depth 8
if ($OutputPath) {
    $OutputPath = [IO.Path]::GetFullPath($OutputPath)
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutputPath) | Out-Null
    [IO.File]::WriteAllText($OutputPath, $json + [Environment]::NewLine, (New-Object Text.UTF8Encoding($false)))
}
Write-Output $json
