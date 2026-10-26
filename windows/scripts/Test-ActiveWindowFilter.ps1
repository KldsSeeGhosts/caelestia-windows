[CmdletBinding()]
param([string]$OutputPath)

$ErrorActionPreference = 'Stop'
& "$PSScriptRoot\..\services\hypr\Watch-ActiveWindow.ps1" -Once | Out-Null
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class ForegroundFixture {
    [DllImport("user32.dll", CharSet=CharSet.Unicode)]
    public static extern IntPtr CreateWindowEx(uint exStyle, string cls, string title, uint style,
        int x, int y, int width, int height, IntPtr parent, IntPtr menu, IntPtr instance, IntPtr param);
    [DllImport("user32.dll")] public static extern bool DestroyWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hwnd, int command);
    [DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, uint attribute, ref int value, uint size);
}
'@
$windows = [Collections.Generic.List[IntPtr]]::new()
$checks = [ordered]@{}
try {
    # Offscreen, NOACTIVATE windows: no foreground change or input.
    $app = [ForegroundFixture]::CreateWindowEx(0x08000000, 'STATIC', 'Caelestia filter fixture',
        0x10C00000, -30000, -30000, 80, 80, [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero)
    $windows.Add($app)
    if ($app -eq [IntPtr]::Zero) { throw 'Could not create native fixture.' }
    $checks.application = [CaelestiaForeground]::IsApplication($app)
    $tool = [ForegroundFixture]::CreateWindowEx(0x08040080, 'STATIC', 'Caelestia tool fixture',
        0x10C00000, -30000, -30000, 80, 80, [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero)
    $windows.Add($tool)
    if ($tool -eq [IntPtr]::Zero) { throw 'Could not create native tool fixture.' }
    $checks.toolWithAppWindowRejected = -not [CaelestiaForeground]::IsApplication($tool)
    $cloak = 1
    if ([ForegroundFixture]::DwmSetWindowAttribute($app, 13, [ref]$cloak, 4) -ne 0) {
        throw 'Could not cloak native fixture.'
    }
    $checks.cloakedRejected = -not [CaelestiaForeground]::IsApplication($app)
    $cloak = 0
    [void][ForegroundFixture]::DwmSetWindowAttribute($app, 13, [ref]$cloak, 4)
    [void][ForegroundFixture]::ShowWindow($app, 0)
    $checks.hiddenRejected = -not [CaelestiaForeground]::IsApplication($app)
    $checks.nullRejected = -not [CaelestiaForeground]::IsApplication([IntPtr]::Zero)
    $shells = @(Get-Process qs, quickshell -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 })
    foreach ($shell in $shells) {
        if (-not [CaelestiaForeground]::IsOwnShell($shell.MainWindowHandle) -or
            [CaelestiaForeground]::IsApplication($shell.MainWindowHandle)) {
            throw 'A qs shell window passed the application filter.'
        }
    }
    $checks.existingQsWindowsRejected = $true
    if (@($checks.Values | Where-Object { -not $_ }).Count) { throw 'A foreground filter assertion failed.' }
    $result = [ordered]@{ passed = $true; checks = $checks; observedQsWindows = $shells.Count }
    $json = $result | ConvertTo-Json -Depth 4
    if ($OutputPath) { $json | Set-Content -LiteralPath $OutputPath -Encoding UTF8 }
    $json
} finally {
    foreach ($window in $windows) {
        if ($window -ne [IntPtr]::Zero) { [void][ForegroundFixture]::DestroyWindow($window) }
    }
}
