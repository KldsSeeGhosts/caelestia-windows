<#
.SYNOPSIS
Runs repeated shell measurements and compares per-machine baselines.
.EXAMPLE
powershell -NoProfile -File windows/scripts/Measure-ShellBenchmark.ps1 -QtPrefix <Qt> -BuildRoot C:\b-bench -BuildRootB C:\b-bench-b -RunRoot C:\b-bench\runs\aa -Metric Idle -Mode NonVisible
.DESCRIPTION
Each side runs at least five times, in A,B,A,B order. Each metric has its own
fresh process and isolated profile. Nothing is installed or restarted.
Use -SaveBaseline <name> (side A) or -SaveBaselineB <name> (side B) to store
a successful unplanted result outside the repository. -CompareBaseline <name>
takes the metrics, mode and workload from the baseline unless they are passed.
The default store is %LOCALAPPDATA%\caelestia-windows-bench\baselines\<machine>.

Writes benchmark.json (raw evidence) and verdict.json (shareable) to RunRoot.
Exit codes: 0 same, improved, or measured with every group valid; 1 runner
error; 2 regressed; 3 inconclusive; 4 contract mismatch.

Use -PlantB CPU, Resources, Panel, or Reload only for sensitivity experiments.
Plants affect disposable staged QML, never source or production behavior.
Run each category separately to keep its plant and workload explicit.

Live mode refuses without -LiveDesktop. Only the designated desktop QA owner
may run it. NonVisible never calls SwitchDesktop. Offscreen measures software
rendering and must not be described as native D3D11 presentation performance.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QtPrefix,
    [Parameter(Mandatory)][string]$BuildRoot,
    [string]$BuildRootB,
    [string]$SourceRoot,
    [string]$SourceRootB,
    [Parameter(Mandatory)][string]$RunRoot,
    [ValidateSet('Idle', 'Resources', 'Panel', 'Reload')][string[]]$Metric = @('Idle', 'Resources', 'Panel', 'Reload'),
    [ValidateSet('NonVisible', 'Offscreen', 'Live')][string]$Mode = 'NonVisible',
    [ValidateRange(5, 100)][int]$Runs = 5,
    [ValidateRange(1, 3600)][int]$WarmupSeconds = 120,
    [ValidateRange(2, 86400)][int]$IdleSeconds = 300,
    [ValidateRange(2, 10000)][int]$Cycles = 100,
    [ValidateRange(0, 60)][int]$CycleIntervalSeconds = 15,
    [ValidateRange(0, 600)][int]$RecoverySeconds = 30,
    [ValidateRange(0, 15)][int]$ScreenIndex = 0,
    [ValidateSet('None', 'CPU', 'Resources', 'Panel', 'Reload')][string]$PlantB = 'None',
    [string]$BaselineRoot = (Join-Path $env:LOCALAPPDATA 'caelestia-windows-bench\baselines'),
    [ValidatePattern('^[a-zA-Z0-9_-]+$')][string]$SaveBaseline,
    [ValidatePattern('^[a-zA-Z0-9_-]+$')][string]$SaveBaselineB,
    [ValidatePattern('^[a-zA-Z0-9_-]+$')][string]$CompareBaseline,
    [switch]$LiveDesktop
)
$ErrorActionPreference = 'Stop'
$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
if ($PlantB -ne 'None' -and (-not $BuildRootB -or $SaveBaseline -or $SaveBaselineB)) { throw 'Plants require a B build and cannot save a baseline.' }
if ($SaveBaselineB -and (-not $BuildRootB -or $SaveBaselineB -eq $SaveBaseline)) { throw '-SaveBaselineB requires a B build and its own name.' }
$RunRoot = [IO.Path]::GetFullPath($RunRoot)
if (Test-Path -LiteralPath $RunRoot) { throw 'RunRoot must be new.' }
$BaselineRoot = Join-Path ([IO.Path]::GetFullPath($BaselineRoot)) $env:COMPUTERNAME
$repoRoot = (Resolve-Path "$PSScriptRoot\..\..").Path
if ($BaselineRoot.StartsWith($repoRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Baseline store must be outside the repository.' }
$baseline = if ($CompareBaseline) { Join-Path $BaselineRoot "$CompareBaseline.json" } else { $null }
if ($baseline -and -not (Test-Path -LiteralPath $baseline)) { throw "Baseline does not exist: $CompareBaseline" }
foreach ($name in @($SaveBaseline, $SaveBaselineB) | Where-Object { $_ }) {
    if (Test-Path -LiteralPath "$BaselineRoot\$name.json") { throw "Choose a new baseline name. Existing baselines are immutable: $name" }
}
if ($baseline) {
    # Measure what the baseline measured unless the caller says otherwise.
    $contracts = @((Get-Content -LiteralPath $baseline -Raw | ConvertFrom-Json).groups.PSObject.Properties |
        Where-Object Name -like 'A/*' | ForEach-Object { $_.Value.contract } | Where-Object { $_ })
    if (-not $contracts) { throw "Baseline has no contract: $CompareBaseline" }
    if (-not $PSBoundParameters.ContainsKey('Metric')) { $Metric = @($contracts | ForEach-Object { $_.metric }) }
    if (-not $PSBoundParameters.ContainsKey('Mode')) { $Mode = $contracts[0].mode }
    foreach ($name in @('WarmupSeconds', 'IdleSeconds', 'Cycles', 'CycleIntervalSeconds', 'RecoverySeconds', 'ScreenIndex')) {
        if (-not $PSBoundParameters.ContainsKey($name)) {
            Set-Variable -Name $name -Value ([int]$contracts[0].workload.($name.Substring(0, 1).ToLowerInvariant() + $name.Substring(1)))
        }
    }
}
if ($Mode -eq 'Live' -and -not $LiveDesktop) { throw 'Live trials require -LiveDesktop.' }
New-Item -ItemType Directory -Path $RunRoot | Out-Null
# Unattended runs hold a documented power request so the machine stays awake
# and, for modes that present frames, the displays stay on. The request cannot
# turn on a display that is already off. A display change during a trial makes
# that trial, and so its group, inconclusive.
Add-Type @"
using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
public static class ShellBenchRunner {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    struct ReasonContext { public uint Version; public uint Flags; public string Reason; IntPtr pad1, pad2; }
    [DllImport("kernel32.dll", SetLastError=true)] static extern IntPtr PowerCreateRequest(ref ReasonContext context);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool PowerSetRequest(IntPtr request, int type);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool PowerClearRequest(IntPtr request, int type);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    const int DisplayRequired = 0, SystemRequired = 1;
    public static IntPtr Hold(string reason, bool display) {
        var context = new ReasonContext { Version=0, Flags=1, Reason=reason };
        var request = PowerCreateRequest(ref context);
        if (request == new IntPtr(-1)) throw new Win32Exception();
        if (!PowerSetRequest(request, SystemRequired) || (display && !PowerSetRequest(request, DisplayRequired))) {
            var error = new Win32Exception(); CloseHandle(request); throw error;
        }
        return request;
    }
    public static void Release(IntPtr request, bool display) {
        if (display) PowerClearRequest(request, DisplayRequired);
        PowerClearRequest(request, SystemRequired);
        CloseHandle(request);
    }
    [StructLayout(LayoutKind.Sequential)] struct Rect { public int left, top, right, bottom; }
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    struct MonitorInfo { public int size; public Rect monitor, work; public uint flags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string device; }
    delegate bool MonitorProc(IntPtr monitor, IntPtr dc, ref Rect rect, IntPtr data);
    [DllImport("user32.dll")] static extern bool EnumDisplayMonitors(IntPtr dc, IntPtr clip, MonitorProc proc, IntPtr data);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern bool GetMonitorInfo(IntPtr monitor, ref MonitorInfo info);
    // Active monitors attached to the desktop, read fresh on every call.
    public static string Displays() {
        var list = new List<string>();
        EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, (IntPtr monitor, IntPtr dc, ref Rect rect, IntPtr data) => {
            var info = new MonitorInfo { size = Marshal.SizeOf(typeof(MonitorInfo)) };
            if (GetMonitorInfo(monitor, ref info)) {
                var m = info.monitor;
                list.Add(string.Format("{0} {1},{2} {3}x{4}{5}", info.device, m.left, m.top, m.right - m.left, m.bottom - m.top, (info.flags & 1) != 0 ? " primary" : ""));
            }
            return true;
        }, IntPtr.Zero);
        list.Sort(StringComparer.Ordinal);
        return string.Join("; ", list);
    }
}
"@
$displayRequired = $Mode -ne 'Offscreen'
$manifest = [ordered]@{
    schemaVersion=3; twoBuilds=[bool]$BuildRootB; displays=[ShellBenchRunner]::Displays()
    powerRequest=[ordered]@{ held=$false; system=$true; display=$displayRequired }; runs=@()
}
$sides = [ordered]@{ A=$BuildRoot }
if ($BuildRootB) { $sides.B = $BuildRootB }
$powerRequest = [ShellBenchRunner]::Hold('Caelestia shell benchmark', $displayRequired)
$manifest.powerRequest.held = $true
try {
    for ($index = 1; $index -le $Runs; $index++) {
        foreach ($category in $Metric) {
            foreach ($side in $sides.Keys) {
                $path = Join-Path $RunRoot "$category-$side-$index"
                $plant = if ($side -eq 'B') { $PlantB } else { 'None' }
                $arguments = @('-NoProfile', '-File', "$PSScriptRoot\Measure-ShellRuntime.ps1",
                    '-QtPrefix', $QtPrefix, '-BuildRoot', $sides[$side], '-RunRoot', $path,
                    '-Metric', $category, '-Mode', $Mode, '-WarmupSeconds', $WarmupSeconds,
                    '-IdleSeconds', $IdleSeconds, '-Cycles', $Cycles, '-RecoverySeconds', $RecoverySeconds,
                    '-CycleIntervalSeconds', $CycleIntervalSeconds,
                    '-ScreenIndex', $ScreenIndex, '-Plant', $plant)
                $source = if ($side -eq 'B') { $SourceRootB } else { $SourceRoot }
                if ($source) { $arguments += @('-SourceRoot', $source) }
                if ($LiveDesktop) { $arguments += '-LiveDesktop' }
                Write-Host "$category $side trial $index/$Runs ($Mode, plant $plant)"
                $before = [ShellBenchRunner]::Displays()
                # A failed trial is recorded and makes its group inconclusive. Under
                # Stop, Windows PowerShell turns the worker's stderr into a terminating
                # error and the run would end without a verdict.
                $ErrorActionPreference = 'Continue'
                & $windowsPowerShell @arguments *> "$RunRoot\$category-$side-$index.worker.log"
                $exitCode = $LASTEXITCODE
                $ErrorActionPreference = 'Stop'
                $after = [ShellBenchRunner]::Displays()
                $manifest.runs += [ordered]@{ side=$side; metric=$category; index=$index; path=$path; exitCode=$exitCode
                    displaysBefore=$before; displaysAfter=$after
                    displayChanged=($before -ne $manifest.displays -or $after -ne $manifest.displays) }
                $manifest | ConvertTo-Json -Depth 8 | Set-Content "$RunRoot\manifest.json" -Encoding UTF8
            }
        }
    }
} finally {
    [ShellBenchRunner]::Release($powerRequest, $displayRequired)
}
$summaryArguments = @('-3', "$PSScriptRoot\Summarize-ShellRuntime.py", "$RunRoot\manifest.json", '--manifest',
    '--output', "$RunRoot\benchmark.json", '--verdict', "$RunRoot\verdict.json", '--baselines', $RunRoot)
if ($baseline) { $summaryArguments += @('--compare', $baseline) }
& py @summaryArguments
$exitCode = $LASTEXITCODE
if ($exitCode -notin @(0, 2, 3, 4) -or -not (Test-Path -LiteralPath "$RunRoot\verdict.json")) { throw 'Summary failed.' }
# Shareable records must not name the account or a home path.
. (Join-Path $PSScriptRoot 'Caelestia-Privacy.ps1')
Initialize-CaelestiaPrivacy
$records = @(Get-ChildItem -LiteralPath $RunRoot -File -Filter 'baseline-*.json') + @(Get-Item -LiteralPath "$RunRoot\verdict.json") +
    @($manifest.runs | ForEach-Object { Get-Item -LiteralPath "$($_.path)\metadata.json" -ErrorAction SilentlyContinue })
$leaks = @($records | Where-Object { (Get-ManifestPrivacyReport $_.FullName).total -gt 0 } | ForEach-Object { $_.FullName.Substring($RunRoot.Length + 1) })
if ($leaks) { throw "Private path or user-name data in: $($leaks -join ', ')" }
foreach ($save in @(@{ name = $SaveBaseline; side = 'A' }, @{ name = $SaveBaselineB; side = 'B' }) | Where-Object { $_.name }) {
    $projection = "$RunRoot\baseline-$($save.side).json"
    $groups = @((Get-Content -LiteralPath $projection -Raw | ConvertFrom-Json).groups.PSObject.Properties)
    if (-not $groups -or @($groups | Where-Object { -not $_.Value.valid }).Count) { throw "Incomplete results cannot become a baseline: $($save.name)" }
    New-Item -ItemType Directory -Force -Path $BaselineRoot | Out-Null
    [IO.File]::Copy($projection, "$BaselineRoot\$($save.name).json", $false)
}
Write-Output "$RunRoot\benchmark.json"
Write-Output "$RunRoot\verdict.json"
Write-Output "Overall verdict: $((Get-Content -LiteralPath "$RunRoot\verdict.json" -Raw | ConvertFrom-Json).overall) (exit $exitCode)"
exit $exitCode
