[CmdletBinding()]
param([switch]$Once)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
Add-Type -TypeDefinition @'
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;

public static class CaelestiaForeground {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] static extern IntPtr GetAncestor(IntPtr hwnd, uint flags);
    [DllImport("user32.dll", EntryPoint="GetWindowLongPtrW")] static extern IntPtr GetWindowLongPtr(IntPtr hwnd, int index);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr hwnd, StringBuilder text, int length);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowTextLength(IntPtr hwnd);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr hwnd, StringBuilder text, int length);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr hwnd, uint attribute, out uint value, uint size);

    public static string Title(IntPtr hwnd) {
        var text = new StringBuilder(GetWindowTextLength(hwnd) + 1);
        GetWindowText(hwnd, text, text.Capacity);
        return text.ToString();
    }
    public static string Application(IntPtr hwnd) {
        uint pid;
        GetWindowThreadProcessId(hwnd, out pid);
        try {
            using (var process = Process.GetProcessById((int)pid)) { return process.ProcessName; }
        } catch { return ""; }
    }
    static bool TryProcessName(IntPtr hwnd, out string name) {
        name = "";
        uint pid;
        GetWindowThreadProcessId(hwnd, out pid);
        try {
            using (var process = Process.GetProcessById((int)pid)) {
                name = process.ProcessName.ToLowerInvariant();
                return true;
            }
        } catch { return false; }
    }

    static bool IsShellClass(IntPtr hwnd) {
        var text = new StringBuilder(256);
        GetClassName(hwnd, text, text.Capacity);
        switch (text.ToString()) {
            case "Progman": case "WorkerW": case "Shell_TrayWnd": case "Shell_SecondaryTrayWnd":
            case "Dwm": case "DwmWindow": case "Windows.Internal.Shell.TabProxyWindow":
            case "XamlExplorerHostIslandWindow": case "TopLevelWindowForOverflowXamlIsland":
            case "MultitaskingViewFrame": case "TaskSwitcherWnd": case "TaskListThumbnailWnd":
            case "ThumbnailDeviceHelperWnd": case "ForegroundStaging":
            case "ApplicationManager_DesktopShellWindow": case "LauncherTipWnd":
            case "Shell_InputSwitchTopLevelWindow": case "NotifyIconOverflowWindow":
            case "DV2ControlHost": case "Xaml_WindowedPopupClass": case "#32768":
                return true;
        }
        return false;
    }

    public static bool IsShellSurface(IntPtr hwnd) {
        if (hwnd == IntPtr.Zero) return false;
        if (IsShellClass(hwnd)) return true;
        string name;
        if (!TryProcessName(hwnd, out name)) return false;
        switch (name) {
            case "dwm": case "qs": case "quickshell": case "sihost":
            case "shellexperiencehost": case "startmenuexperiencehost":
            case "shellhost": case "searchhost": case "searchapp": case "searchui":
            case "textinputhost":
                return true;
        }
        return false;
    }

    public static bool IsDesktop(IntPtr hwnd) {
        if (hwnd == IntPtr.Zero) return false;
        var text = new StringBuilder(64);
        GetClassName(hwnd, text, text.Capacity);
        var name = text.ToString();
        return name == "Progman" || name == "WorkerW";
    }

    public static bool IsApplication(IntPtr hwnd) {
        if (hwnd == IntPtr.Zero || !IsWindowVisible(hwnd) || GetAncestor(hwnd, 2) != hwnd)
            return false;
        if ((GetWindowLongPtr(hwnd, -20).ToInt64() & 0x80) != 0)
            return false; // WS_EX_TOOLWINDOW, including tool windows with APPWINDOW.
        uint cloaked;
        if (DwmGetWindowAttribute(hwnd, 14, out cloaked, 4) != 0 || cloaked != 0)
            return false; // DWMWA_CLOAKED, fail closed on an unavailable observation.
        if (IsShellSurface(hwnd)) return false;
        if (GetWindowTextLength(hwnd) == 0) return false;
        string unused;
        return TryProcessName(hwnd, out unused); // fail closed when the owner is unknown.
    }
}
'@

$previous = ''
$lastApplication = [IntPtr]::Zero
do {
    $foreground = [CaelestiaForeground]::GetForegroundWindow()
    if ([CaelestiaForeground]::IsApplication($foreground)) {
        $lastApplication = $foreground
    } elseif ([CaelestiaForeground]::IsDesktop($foreground) -or
        -not [CaelestiaForeground]::IsShellSurface($foreground) -or
        -not [CaelestiaForeground]::IsApplication($lastApplication)) {
        $lastApplication = [IntPtr]::Zero
    }
    # Preserve the last real application while the task switcher, Task View,
    # Start/Search or one of the shell's own panels owns focus. The desktop
    # still clears it.
    $address = if ($lastApplication -eq [IntPtr]::Zero) { '' } else { $lastApplication.ToInt64().ToString('x') }
    $line = @{
        address = $address
        title = if ($address) { [CaelestiaForeground]::Title($lastApplication) } else { '' }
        appId = if ($address) { [CaelestiaForeground]::Application($lastApplication) } else { '' }
    } | ConvertTo-Json -Compress
    if ($Once -or $line -ne $previous) {
        [Console]::Out.WriteLine($line)
        [Console]::Out.Flush()
        $previous = $line
    }
    if (-not $Once) { Start-Sleep -Milliseconds 250 }
} while (-not $Once)
