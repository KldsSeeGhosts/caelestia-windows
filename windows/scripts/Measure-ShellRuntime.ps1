<#
.SYNOPSIS
Measures one isolated shell trial. Use Measure-ShellBenchmark.ps1 for repeated trials.
.DESCRIPTION
Stages the production graph with the existing combined read-only test host.
Never reads the installed profile. NonVisible uses CreateDesktop without
SwitchDesktop. Offscreen uses Qt's software renderer, not a native swapchain.
Live requires -LiveDesktop and is reserved for the desktop QA owner.

Panel time ends when the parent receives the fully-open frameSwapped marker.
It includes IPC process startup and log transport, so it is an upper bound on
request-to-frame time, not input-to-photon latency. The shell also records its
own request-to-frame timer. Neither endpoint proves DWM scanout.

Plant changes only the disposable staged QML. Production reads no test variable.
Results with a plant must never be saved as a production baseline.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$QtPrefix,
    [Parameter(Mandatory)][string]$BuildRoot,
    [Parameter(Mandatory)][string]$RunRoot,
    [string]$SourceRoot,
    [ValidateSet('Idle', 'Resources', 'Panel', 'Reload')][string]$Metric = 'Idle',
    [ValidateSet('NonVisible', 'Offscreen', 'Live')][string]$Mode = 'NonVisible',
    [ValidateRange(1, 3600)][int]$WarmupSeconds = 120,
    [ValidateRange(2, 86400)][int]$IdleSeconds = 300,
    [ValidateRange(2, 10000)][int]$Cycles = 100,
    [ValidateRange(0, 60)][int]$CycleIntervalSeconds = 15,
    [ValidateRange(0, 600)][int]$RecoverySeconds = 30,
    [ValidateRange(0, 15)][int]$ScreenIndex = 0,
    [ValidateSet('None', 'CPU', 'Resources', 'Panel', 'Reload')][string]$Plant = 'None',
    [switch]$LiveDesktop,
    [Parameter(DontShow)][string]$WorkerDesktop
)

$ErrorActionPreference = 'Stop'
$windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$BuildRoot = (Resolve-Path -LiteralPath $BuildRoot).Path
if (-not $SourceRoot) {
    $sourceLine = Get-Content "$BuildRoot\caelestia\CMakeCache.txt" | Where-Object { $_ -like 'CMAKE_HOME_DIRECTORY:INTERNAL=*' }
    if (-not $sourceLine) { throw 'Cannot locate the shell checkout. Pass -SourceRoot or use a Build-Prototype build root.' }
    $SourceRoot = $sourceLine.Substring('CMAKE_HOME_DIRECTORY:INTERNAL='.Length)
    # Build roots record their checkout's path, not its revision. A checkout that
    # moved on would stage different QML over these binaries.
    $built = (Get-Content "$BuildRoot\logs\build.json" -Raw | ConvertFrom-Json).sourceRevision
    $current = (& git -C $SourceRoot rev-parse HEAD).Trim()
    if ($current -ne $built) { throw "The build root's checkout moved from $built to $current. Pass -SourceRoot with a checkout of $built." }
}
$SourceRoot = (Resolve-Path -LiteralPath $SourceRoot).Path
$QtPrefix = (Resolve-Path -LiteralPath $QtPrefix).Path
$RunRoot = [IO.Path]::GetFullPath($RunRoot)
# metadata.json names no account or home path. See Caelestia-Privacy.ps1.
. (Join-Path $PSScriptRoot 'Caelestia-Privacy.ps1')
Initialize-CaelestiaPrivacy @(
    @{ from = $RunRoot; to = '<runRoot>' }, @{ from = $BuildRoot; to = '<buildRoot>' },
    @{ from = $SourceRoot; to = '<source>' }, @{ from = $QtPrefix; to = '<qt>' }
)
function Get-TextSha256([string]$Text) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text))).Replace('-', '') }
    finally { $sha.Dispose() }
}
if ($Mode -eq 'Live' -and -not $LiveDesktop) { throw 'Live trials require -LiveDesktop.' }
if ($Mode -ne 'Live' -and $LiveDesktop) { throw '-LiveDesktop requires -Mode Live.' }
if ($Mode -eq 'Offscreen' -and $ScreenIndex -ne 0) { throw 'Offscreen has only screen 0.' }

Add-Type @'
using System;
using System.Collections.Concurrent;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
public static class ShellBenchNative {
    [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)]
    struct StartupInfo {
        public int cb;
        public string reserved, desktop, title;
        public int x, y, width, height, charsX, charsY, fill, flags;
        public short show, reservedBytes;
        public IntPtr reservedPointer, stdin, stdout, stderr;
    }
    [StructLayout(LayoutKind.Sequential)]
    struct ProcessInfo { public IntPtr process, thread; public int pid, tid; }
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern IntPtr CreateDesktop(string name, IntPtr device, IntPtr mode, uint flags, uint access, IntPtr security);
    [DllImport("user32.dll")] static extern bool CloseDesktop(IntPtr desktop);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool CreateProcess(string app, StringBuilder command, IntPtr pa, IntPtr ta,
        bool inherit, uint flags, IntPtr environment, string directory, ref StartupInfo startup, out ProcessInfo process);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr handle);
    [DllImport("kernel32.dll")] static extern uint WaitForSingleObject(IntPtr handle, uint milliseconds);
    [DllImport("kernel32.dll", SetLastError=true)] static extern bool GetExitCodeProcess(IntPtr process, out uint code);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] static extern IntPtr GetThreadDesktop(uint thread);
    [DllImport("user32.dll", CharSet=CharSet.Unicode, SetLastError=true)]
    static extern bool GetUserObjectInformation(IntPtr handle, int index, StringBuilder value, int size, out int needed);
    [DllImport("user32.dll")] public static extern uint GetGuiResources(IntPtr process, uint flags);
    public static string DesktopName() {
        var name = new StringBuilder(256); int needed;
        if (!GetUserObjectInformation(GetThreadDesktop(GetCurrentThreadId()), 2, name, 512, out needed))
            throw new Win32Exception();
        return name.ToString();
    }
    public static int OnDesktop(string command, string directory, string name) {
        var desktop = CreateDesktop(name, IntPtr.Zero, IntPtr.Zero, 0, 0x01ff, IntPtr.Zero);
        if (desktop == IntPtr.Zero) throw new Win32Exception();
        try {
            var startup = new StartupInfo { cb=Marshal.SizeOf(typeof(StartupInfo)), desktop="winsta0\\"+name };
            ProcessInfo info;
            if (!CreateProcess(null, new StringBuilder(command), IntPtr.Zero, IntPtr.Zero, false,
                0x08000000, IntPtr.Zero, directory, ref startup, out info)) throw new Win32Exception();
            try {
                if (WaitForSingleObject(info.process, 0xffffffff) != 0) throw new Win32Exception();
                uint code;
                if (!GetExitCodeProcess(info.process, out code)) throw new Win32Exception();
                return (int)code;
            } finally { CloseHandle(info.thread); CloseHandle(info.process); }
        } finally { CloseDesktop(desktop); }
    }
}
public sealed class ShellBenchLog : IDisposable {
    public readonly ConcurrentDictionary<string,long> Markers = new ConcurrentDictionary<string,long>();
    readonly StreamWriter stdout, stderr;
    public ShellBenchLog(Process process, string directory) {
        stdout = new StreamWriter(Path.Combine(directory,"stdout.log")) { AutoFlush=true };
        stderr = new StreamWriter(Path.Combine(directory,"stderr.log")) { AutoFlush=true };
        process.OutputDataReceived += (s,e) => Receive(e.Data,stdout);
        process.ErrorDataReceived += (s,e) => Receive(e.Data,stderr);
        process.BeginOutputReadLine(); process.BeginErrorReadLine();
    }
    void Receive(string line, StreamWriter stream) {
        if (line == null) return;
        long tick = Stopwatch.GetTimestamp();
        lock(stream) stream.WriteLine(line);
        const string prefix = "CAELESTIA_BENCH_FRAME ";
        int start = line.IndexOf(prefix, StringComparison.Ordinal);
        if (start >= 0) Markers[line.Substring(start+prefix.Length).Trim()] = tick;
    }
    public void Dispose() { stdout.Dispose(); stderr.Dispose(); }
}
'@

if ($Mode -eq 'NonVisible' -and -not $WorkerDesktop) {
    if (Test-Path -LiteralPath $RunRoot) { throw 'RunRoot must be new.' }
    $desktop = 'CaelestiaBench-' + [guid]::NewGuid().ToString('N')
    $command = '"' + $windowsPowerShell + '" -NoProfile -File "' + $PSCommandPath + '"'
    foreach ($key in @('QtPrefix', 'BuildRoot', 'RunRoot', 'SourceRoot', 'Metric', 'Mode', 'WarmupSeconds',
            'IdleSeconds', 'Cycles', 'CycleIntervalSeconds', 'RecoverySeconds', 'ScreenIndex', 'Plant')) {
        $value = [string](Get-Variable -Name $key -ValueOnly)
        if ($value.Contains('"')) { throw "Quotes are not supported in $key." }
        $command += ' -' + $key + ' "' + $value + '"'
    }
    $command += ' -WorkerDesktop "' + $desktop + '"'
    $exitCode = [ShellBenchNative]::OnDesktop($command, $BuildRoot, $desktop)
    if ($exitCode -ne 0) { throw "Non-visible trial failed ($exitCode). See $RunRoot." }
    return
}
if ($Mode -eq 'NonVisible' -and [ShellBenchNative]::DesktopName() -ne $WorkerDesktop) {
    throw 'Worker is not on the desktop created for this trial.'
}
if (Test-Path -LiteralPath $RunRoot) { throw 'RunRoot must be new.' }
New-Item -ItemType Directory -Path $RunRoot | Out-Null
$profileRoot = Join-Path $RunRoot 'profile'
$stage = & "$SourceRoot\windows\scripts\Stage-ShellPrototype.ps1" -Destination "$RunRoot\stage" -ProfileRoot $profileRoot -Prototype combined
foreach ($dir in @('config', 'state', 'runtime', 'cache', 'data')) {
    New-Item -ItemType Directory -Force -Path "$profileRoot\$dir" | Out-Null
}
$config = Get-Content "$SourceRoot\windows\shell\shell.json" -Raw | ConvertFrom-Json
$config.background.enabled = $false
$config.windows.clipboard.enabled = $false
$config.session.commands = @{}
$config | ConvertTo-Json -Depth 32 | Set-Content "$profileRoot\config\shell.json" -Encoding UTF8
Copy-Item -LiteralPath "$SourceRoot\windows\shell\windows.json" -Destination "$profileRoot\config\windows.json"
'{"binds":[]}' | Set-Content "$profileRoot\config\keybinds.json" -Encoding UTF8

# This overlay lives only in the trial stage. The source and backend stay unchanged.
$probe = @'
    property string benchGeneration: Date.now().toString(36) + Math.random().toString(36)
    property string benchPending: ""
    property string benchPanel: ""
    property int benchReadyFrames: 0
    property int benchFrames: 0
    property real benchFrameMs: 0
    property int benchBusyTicks: 0
    property var benchRetained: []
    ElapsedTimer { id: benchClock }
    ElapsedTimer { id: benchBusyClock }
    Timer {
        interval: 1
        repeat: true
        running: __CPU__
        onTriggered: {
            root.benchBusyTicks++;
            benchBusyClock.restart();
            while (benchBusyClock.elapsedMs() < 8) {}
        }
    }
    Timer {
        id: benchDelay
        interval: 400
        onTriggered: root.benchOpen()
    }
    Timer {
        id: benchReloadDelay
        interval: 400
        onTriggered: Quickshell.reload(false)
    }
    function benchOpen(): void {
        if (benchPanel === "nexus") {
            Nexus.WindowFactory.openPage(3);
        } else {
            benchPrototype.showPanel(benchPanel, 0);
        }
        win.contentItem.Window.window.update();
    }
    function benchReady(): bool {
        const panels = ShellState.componentsFor(win.screen)?.panels;
        if (!panels)
            return false;
        if (benchPanel === "idle")
            return ["dashboard", "launcher", "utilities", "sidebar", "osd"].every(n => !panels[n].visible)
                && !panels.popouts.hasCurrent && Nexus.WindowFactory.windowCount === 0;
        const item = benchPanel === "nexus" ? Nexus.WindowFactory.activeWindow() : panels[benchPanel];
        return !!item && item.visible && item.width > 0 && item.height > 0
            && (benchPanel === "nexus" || item.offsetScale === 0);
    }
    function benchFrame(nexus: bool): void {
        benchFrames++;
        if (!benchPending || (benchPanel === "nexus") !== nexus)
            return;
        if (!benchReady()) {
            benchReadyFrames = 0;
            return;
        }
        if (++benchReadyFrames < 2) {
            const window = nexus ? Nexus.WindowFactory.activeWindow()?.contentItem.Window.window : win.contentItem.Window.window;
            window?.update();
            return;
        }
        benchFrameMs = benchClock.elapsed();
        console.log("CAELESTIA_BENCH_FRAME " + benchGeneration + "/" + benchPending);
        benchPending = "";
    }
    Connections {
        target: win.contentItem.Window.window
        function onFrameSwapped(): void { root.benchFrame(false); }
    }
    Connections {
        target: Nexus.WindowFactory.activeWindow()?.contentItem.Window.window ?? null
        function onFrameSwapped(): void { root.benchFrame(true); }
    }
    IpcHandler {
        target: "benchmark"
        function state(): string {
            return JSON.stringify({
                generation: root.benchGeneration, frames: root.benchFrames,
                pending: root.benchPending, frameMs: root.benchFrameMs * 1000,
                ready: root.benchFrames > 0 && win.backingWindowVisible,
                dpr: win.devicePixelRatio, width: win.width, height: win.height,
                nexusWindows: Nexus.WindowFactory.windowCount,
                nexusDpr: Nexus.WindowFactory.activeWindow()?.devicePixelRatio ?? null,
                busyTicks: root.benchBusyTicks, retainedAllocations: root.benchRetained.length
            });
        }
        function request(id: string, panel: string): bool {
            if (!["idle", "dashboard", "launcher", "utilities", "sidebar", "nexus"].includes(panel) || root.benchPending)
                return false;
            root.benchPending = id;
            root.benchPanel = panel;
            root.benchReadyFrames = 0;
            benchClock.restart();
            if (panel === "idle") {
                Nexus.WindowFactory.closeAll();
                benchPrototype.showPanel("idle", 0);
                win.contentItem.Window.window.update();
            } else {
                if (__RESOURCES__)
                    root.benchRetained.push(new Array(1048576).fill(Math.random()));
                if (__PANEL__)
                    benchDelay.start();
                else
                    root.benchOpen();
            }
            return true;
        }
        function restart(): string {
            const previous = root.benchGeneration;
            if (__RELOAD__)
                benchReloadDelay.start();
            else
                Quickshell.reload(false);
            return previous;
        }
    }
'@
foreach ($category in @('CPU', 'Resources', 'Panel', 'Reload')) {
    $probe = $probe.Replace('__' + $category.ToUpperInvariant() + '__', ($Plant -eq $category).ToString().ToLowerInvariant())
}
$shellPath = "$stage\shell.qml"
$shell = [IO.File]::ReadAllText($shellPath)
$shell = $shell.Replace('import QtQuick', "import QtQuick.Window`nimport qs.modules.nexus as Nexus`nimport QtQuick")
$shell = $shell.Replace('    id: root', "    id: root`n$probe")
$shell = $shell.Replace('target: "prototype"', 'id: benchPrototype; target: "prototype"')
$shell = [regex]::Replace($shell, '(?m)^        active: !root.smoke\r?$', '        active: false')
[IO.File]::WriteAllText($shellPath, $shell, [Text.UTF8Encoding]::new($false))

$exe = Join-Path $BuildRoot 'quickshell\qs.exe'
$qmlRoot = Join-Path $BuildRoot 'install\qml'
$info = [Diagnostics.ProcessStartInfo]::new()
$info.FileName = $exe
$info.Arguments = '--no-color --log-times --path "' + $shellPath + '"'
$info.WorkingDirectory = $stage
$info.UseShellExecute = $false
$info.CreateNoWindow = $true
$info.RedirectStandardOutput = $true
$info.RedirectStandardError = $true
foreach ($variable in @($info.EnvironmentVariables.Keys | Where-Object { $_ -match '^(CAELESTIA_|QS_|QSG_|QT_|QML_|XDG_)' })) {
    $info.EnvironmentVariables.Remove($variable)
}
$info.EnvironmentVariables['PATH'] = "$QtPrefix\bin;$qmlRoot\Caelestia\lib;$qmlRoot\M3Shapes;$env:PATH"
$info.EnvironmentVariables['QML_IMPORT_PATH'] = "$stage\imports;$qmlRoot;$QtPrefix\qml"
$info.EnvironmentVariables['QML2_IMPORT_PATH'] = "$stage\imports;$qmlRoot;$QtPrefix\qml"
$info.EnvironmentVariables['QML_DISK_CACHE_PATH'] = "$profileRoot\cache"
$info.EnvironmentVariables['QS_RUNTIME_DIR'] = "$profileRoot\runtime\quickshell"
# An explicit empty RHI load file prevents fallback to Qt's shared app cache.
$pipelineCache = "$profileRoot\cache\pipeline-cache.bin"
[IO.File]::WriteAllBytes($pipelineCache, [byte[]]@())
$info.EnvironmentVariables['QSG_RHI_PIPELINE_CACHE_LOAD'] = $pipelineCache
$info.EnvironmentVariables['QSG_RHI_PIPELINE_CACHE_SAVE'] = $pipelineCache
foreach ($dir in @('CONFIG', 'STATE', 'RUNTIME')) { $info.EnvironmentVariables["CAELESTIA_${dir}_DIR"] = "$profileRoot\$($dir.ToLowerInvariant())" }
$info.EnvironmentVariables['CAELESTIA_PROFILE_ROOT'] = $profileRoot
foreach ($dir in @('CONFIG', 'STATE', 'DATA', 'CACHE')) { $info.EnvironmentVariables["XDG_${dir}_HOME"] = "$profileRoot\$($dir.ToLowerInvariant())" }
foreach ($service in @('AUDIO', 'BATTERY', 'BLUETOOTH', 'BRIGHTNESS', 'MEDIA', 'NETWORK', 'APPS', 'HYPR', 'TRAY', 'SESSION', 'NOTIFICATIONS')) {
    $info.EnvironmentVariables["CAELESTIA_WINDOWS_$service"] = '1'
}
$info.EnvironmentVariables['CAELESTIA_WINDOWS_POWER_PROFILES'] = '1'
$info.EnvironmentVariables['CAELESTIA_SHELL_SESSION'] = '1'
$info.EnvironmentVariables['CAELESTIA_SHELL_SESSION_MODE'] = 'Observe'
$info.EnvironmentVariables['CAELESTIA_WINDOWS_TILING'] = 'off'
$info.EnvironmentVariables['CAELESTIA_WINDOWS_KEYBINDS'] = "$profileRoot\config\keybinds.json"
$info.EnvironmentVariables['CAELESTIA_RUNTIME_PROBE'] = '1'
$info.EnvironmentVariables['CAELESTIA_SHELL_SCREEN'] = [string]$ScreenIndex
$info.EnvironmentVariables['QS_WINDOWS_TRAY_HOOK'] = '0'
$info.EnvironmentVariables['QS_WINDOWS_BLUR'] = '0'
$info.EnvironmentVariables['QS_TRANSITION_TRACE'] = "$RunRoot\transition.jsonl"
$info.EnvironmentVariables['QT_LOGGING_RULES'] = 'quickshell.startup.debug=true;quickshell.windows.tracker.debug=false;quickshell.windows.inputmask.debug=false'
$info.EnvironmentVariables['QSG_RHI_BACKEND'] = 'd3d11'
if ($Mode -eq 'Offscreen') {
    $info.EnvironmentVariables['QT_QPA_PLATFORM'] = 'offscreen'
    $info.EnvironmentVariables['QT_QUICK_BACKEND'] = 'software'
    $info.EnvironmentVariables['QSG_RENDER_LOOP'] = 'basic'
}

$process = $null
$log = $null
$liveLock = $null
$work = [ordered]@{ actionsConfirmed=0; panelsShown=0; cyclesCompleted=0; reloadsCompleted=0; idleIntervals=0 }
$errors = [Collections.Generic.List[string]]::new()
$samples = [Collections.Generic.List[object]]::new()
$actions = [Collections.Generic.List[object]]::new()
$clock = [Diagnostics.Stopwatch]::StartNew()
$lastCpu = 0.0
$lastTime = 0.0
$perflib = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Perflib'
$englishCounters = (Get-ItemProperty -LiteralPath "$perflib\009" -Name Counter).Counter
$localCounters = (Get-ItemProperty -LiteralPath "$perflib\CurrentLanguage" -Name Counter).Counter
$counterIds = @{}
$counterNames = @{}
for ($index = 0; $index + 1 -lt $englishCounters.Length; $index += 2) {
    $counterIds[$englishCounters[$index + 1]] = $englishCounters[$index]
}
for ($index = 0; $index + 1 -lt $localCounters.Length; $index += 2) {
    $counterNames[$localCounters[$index]] = $localCounters[$index + 1]
}
$cpuLoadCounter = '\' + $counterNames[$counterIds['Processor']] + '(_Total)\' + $counterNames[$counterIds['% Processor Time']]
$metadata = [ordered]@{
    schemaVersion=2; metric=$Metric; mode=$Mode; plant=$Plant
    # A stable per-installation identifier that does not reveal the computer name.
    machine='sha256:' + (Get-TextSha256 ('caelestia-bench:' + (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Cryptography').MachineGuid)).Substring(0, 16).ToLowerInvariant()
    logicalProcessors=[Environment]::ProcessorCount
    os=[Environment]::OSVersion.VersionString
    culture=[Globalization.CultureInfo]::CurrentCulture.Name
    uiCulture=[Globalization.CultureInfo]::CurrentUICulture.Name
    cpuLoadCounter=$cpuLoadCounter
    windowsBuild=Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' |
        Select-Object CurrentBuildNumber, UBR, DisplayVersion
    uptimeSeconds=([DateTime]::Now - (Get-CimInstance Win32_OperatingSystem).LastBootUpTime).TotalSeconds
    shellRevision=(& git -C $SourceRoot rev-parse HEAD).Trim()
    sourceStatus=@(& git -C $SourceRoot status --short)
    backendPin=(& git -C $SourceRoot rev-parse HEAD:windows/deps/quickshell).Trim()
    protocolSha256=(Get-FileHash $PSCommandPath).Hash
    buildRecordSha256=(Get-FileHash "$BuildRoot\logs\build.json").Hash
    build=Get-Content "$BuildRoot\logs\build.json" -Raw | ConvertFrom-Json
    executableSha256=(Get-FileHash $exe).Hash
    qtVersion=(Get-Item "$QtPrefix\bin\Qt6Core.dll").VersionInfo.FileVersion
    qtCoreSha256=(Get-FileHash "$QtPrefix\bin\Qt6Core.dll").Hash
    payloadSha256=(Get-FileHash "$stage\sources.json").Hash
    probeSha256=(Get-FileHash $shellPath).Hash
    startedUtc=[DateTime]::UtcNow.ToString('o')
    workload=[ordered]@{ warmupSeconds=$WarmupSeconds; idleSeconds=$IdleSeconds; cycles=$Cycles; cycleIntervalSeconds=$CycleIntervalSeconds; recoverySeconds=$RecoverySeconds; screenIndex=$ScreenIndex }
    environment=[ordered]@{}; desktop=[ShellBenchNative]::DesktopName()
}
$metadata.nativeModules = @(
    Get-ChildItem "$qmlRoot\Caelestia","$qmlRoot\M3Shapes" -Recurse -File -Filter '*.dll' |
        Sort-Object FullName | ForEach-Object {
            [ordered]@{ path=$_.FullName.Substring($qmlRoot.Length + 1); sha256=(Get-FileHash $_.FullName).Hash }
        }
)
$metadata.shellManifestSha256 = $metadata.payloadSha256
$metadata.configSha256 = (Get-FileHash "$profileRoot\config\shell.json").Hash
$identity = @($metadata.shellManifestSha256, $metadata.executableSha256, $metadata.probeSha256,
    $metadata.qtCoreSha256, $metadata.configSha256, $metadata.nativeModules)
$metadata.payloadSha256 = Get-TextSha256 ($identity | ConvertTo-Json -Depth 8 -Compress)
foreach ($variable in $info.EnvironmentVariables.Keys | Where-Object { $_ -match '^(CAELESTIA_|QS_|QSG_|QT_|QML_|XDG_)' }) {
    $metadata.environment[$variable] = $info.EnvironmentVariables[$variable]
}
function Invoke-BenchIpc([string]$Method, [string[]]$Values = @(), [string]$Target = 'benchmark') {
    $clientInfo = [Diagnostics.ProcessStartInfo]::new()
    $clientInfo.FileName = $exe
    $clientInfo.Arguments = "ipc --pid $($process.Id) call $Target $Method " + ($Values -join ' ')
    $clientInfo.UseShellExecute = $false
    $clientInfo.CreateNoWindow = $true
    $clientInfo.RedirectStandardOutput = $true
    $clientInfo.RedirectStandardError = $true
    $clientInfo.EnvironmentVariables['PATH'] = $info.EnvironmentVariables['PATH']
    $clientInfo.EnvironmentVariables['QS_RUNTIME_DIR'] = $info.EnvironmentVariables['QS_RUNTIME_DIR']
    $client = [Diagnostics.Process]::Start($clientInfo)
    try {
        $outTask = $client.StandardOutput.ReadToEndAsync()
        $errTask = $client.StandardError.ReadToEndAsync()
        if (-not $client.WaitForExit(10000)) { $client.Kill(); $client.WaitForExit(); throw "IPC timeout $Method" }
        $output = $outTask.GetAwaiter().GetResult().Trim()
        $stderr = $errTask.GetAwaiter().GetResult()
        if ($client.ExitCode -ne 0 -or $output -in @('false', '-1')) { throw "IPC rejected $Method $stderr" }
        return $output
    } finally { $client.Dispose() }
}
function Read-Sample([string]$Phase, [int]$Cycle) {
    $process.Refresh()
    if ($process.HasExited) { throw 'Shell exited during trial.' }
    $time = $clock.Elapsed.TotalSeconds
    $cpu = $process.TotalProcessorTime.TotalSeconds
    $cpuPercent = if ($time -gt $script:lastTime) { 100 * ($cpu - $script:lastCpu) / ($time - $script:lastTime) } else { 0 }
    $load = (Get-Counter $cpuLoadCounter -ErrorAction Stop).CounterSamples[0].CookedValue
    $row = [pscustomobject][ordered]@{
        elapsedSeconds=$time; phase=$Phase; cycle=$Cycle
        privateBytes=$process.PrivateMemorySize64; workingSet=$process.WorkingSet64
        handles=$process.HandleCount
        gdi=[ShellBenchNative]::GetGuiResources($process.Handle, 0)
        user=[ShellBenchNative]::GetGuiResources($process.Handle, 1)
        threads=$process.Threads.Count; cpuSeconds=$cpu
        cpuCorePercent=$cpuPercent; cpuMachinePercent=$cpuPercent / [Environment]::ProcessorCount
        systemCpuPercent=$load
    }
    $samples.Add($row)
    $script:lastCpu = $cpu
    $script:lastTime = $time
}
function Wait-Frame([string]$Panel) {
    $id = [guid]::NewGuid().ToString('N')
    $before = Invoke-BenchIpc state | ConvertFrom-Json
    $start = [Diagnostics.Stopwatch]::GetTimestamp()
    Invoke-BenchIpc request @($id, $Panel) | Out-Null
    $marker = $before.generation + '/' + $id
    $deadline = [Diagnostics.Stopwatch]::StartNew()
    while (-not $log.Markers.ContainsKey($marker)) {
        if ($process.HasExited -or $deadline.Elapsed.TotalSeconds -gt 15) { throw "No presented frame for $Panel." }
        Start-Sleep -Milliseconds 5
    }
    $state = Invoke-BenchIpc state | ConvertFrom-Json
    if ($state.pending -or -not $state.ready -or $state.generation -ne $before.generation) { throw "Invalid frame confirmation for $Panel." }
    $work.actionsConfirmed++
    if ($Panel -ne 'idle') { $work.panelsShown++ }
    $actions.Add([pscustomobject]@{
        panel=$Panel; requestQpc=$start; observedQpc=$log.Markers[$marker]
        requestToFrameObservedMs=1000 * ($log.Markers[$marker] - $start) / [Diagnostics.Stopwatch]::Frequency
        shellRequestToFrameMs=$state.frameMs; frameCount=$state.frames
        dpr=$(if ($Panel -eq 'nexus') { $state.nexusDpr } else { $state.dpr })
    })
}
function Sample-Idle([string]$Phase, [int]$Seconds) {
    Read-Sample $Phase 0
    $start = $script:lastTime
    while ($script:lastTime - $start -lt $Seconds) {
        $remaining = $Seconds - ($clock.Elapsed.TotalSeconds - $start)
        if ($remaining -gt 0) { Start-Sleep -Milliseconds ([int][Math]::Min(1000, 1000 * $remaining)) }
        Read-Sample $Phase 0
    }
}
try {
    if ($Mode -eq 'Live') {
        $liveLock = [Threading.Mutex]::new($false, 'Local\CaelestiaBenchmarkLiveDesktop')
        if (-not $liveLock.WaitOne(0)) { throw 'Another benchmark owns the live desktop.' }
    }
    $process = [Diagnostics.Process]::Start($info)
    $log = [ShellBenchLog]::new($process, $RunRoot)
    $readyClock = [Diagnostics.Stopwatch]::StartNew()
    do {
        if ($process.HasExited -or $readyClock.Elapsed.TotalSeconds -gt 45) { throw 'Shell did not render its first frame.' }
        try { $state = Invoke-BenchIpc state | ConvertFrom-Json } catch { $state = $null }
        if (-not $state.ready) { Start-Sleep -Milliseconds 50 }
    } until ($state.ready)
    $metadata.processId = $process.Id
    $metadata.screen = $state
    $prototypeState = Invoke-BenchIpc state @() prototype | ConvertFrom-Json
    $metadata.controlGates = [ordered]@{}
    foreach ($service in $prototypeState.services.PSObject.Properties) {
        foreach ($gate in $service.Value.PSObject.Properties |
                Where-Object Name -in @('controls', 'launch', 'dispatch', 'activation', 'mirror', 'actions',
                    'profileWrites', 'keepAwakePermitted', 'keepAwakeHeld', 'recorderPermitted', 'recorderRunning', 'backendEnabled')) {
            $metadata.controlGates["$($service.Name).$($gate.Name)"] = $gate.Value
            if ($gate.Value -eq $true) { throw "Unexpected enabled control gate $($service.Name).$($gate.Name)." }
        }
    }
    if ($Metric -eq 'Resources') {
        foreach ($panel in @('dashboard', 'launcher', 'utilities', 'sidebar', 'nexus')) {
            Wait-Frame $panel
            Wait-Frame idle
        }
        $metadata.preconditionActions = @($actions.ToArray())
        foreach ($key in @($work.Keys)) { $work[$key] = 0 }
        $actions.Clear()
    }
    Sample-Idle 'warmup' $WarmupSeconds
    $warmedState = Invoke-BenchIpc state @() prototype | ConvertFrom-Json
    $metadata.workloadDimensions = [ordered]@{
        applications=$warmedState.services.apps.count
        monitors=$warmedState.services.hypr.monitors
        workspaces=$warmedState.services.hypr.workspaces
    }
    Wait-Frame idle
    switch ($Metric) {
        'Idle' {
            $metadata.idleStateBefore = Invoke-BenchIpc state | ConvertFrom-Json
            Sample-Idle 'idle' $IdleSeconds
            $work.idleIntervals = @($samples | Where-Object phase -eq 'idle').Count - 1
        }
        'Resources' {
            Sample-Idle 'initial-idle' $IdleSeconds
            $panels = @('dashboard', 'launcher', 'utilities', 'sidebar', 'nexus')
            for ($cycle = 1; $cycle -le $Cycles; $cycle++) {
                $cycleClock = [Diagnostics.Stopwatch]::StartNew()
                Wait-Frame $panels[($cycle - 1) % $panels.Count]
                Wait-Frame idle
                $remaining = $CycleIntervalSeconds - $cycleClock.Elapsed.TotalSeconds
                if ($remaining -gt 0) { Start-Sleep -Milliseconds ([int](1000 * $remaining)) }
                $work.cyclesCompleted++
                Read-Sample 'cycle' $cycle
            }
            Sample-Idle 'final-idle' $RecoverySeconds
        }
        'Panel' {
            $panels = @('dashboard', 'launcher', 'utilities', 'sidebar')
            for ($cycle = 0; $cycle -lt $Cycles; $cycle++) {
                Wait-Frame $panels[$cycle % $panels.Count]
                Wait-Frame idle
            }
        }
        'Reload' {
            $reloadClock = [Diagnostics.Stopwatch]::StartNew()
            $previous = Invoke-BenchIpc restart
            do {
                if ($process.HasExited -or $reloadClock.Elapsed.TotalSeconds -gt 45) { throw 'Reload failed to render a new generation.' }
                try { $state = Invoke-BenchIpc state | ConvertFrom-Json } catch { $state = $null }
                if (-not $state.ready -or $state.generation -eq $previous) { Start-Sleep -Milliseconds 10 }
            } until ($state.ready -and $state.generation -ne $previous)
            $metadata.reloadMilliseconds = $reloadClock.Elapsed.TotalMilliseconds
            $work.reloadsCompleted++
        }
    }
    $metadata.finalState = Invoke-BenchIpc state | ConvertFrom-Json
    if ((Get-FileHash $exe).Hash -ne $metadata.executableSha256 -or
        (Get-FileHash "$BuildRoot\logs\build.json").Hash -ne $metadata.buildRecordSha256) {
        throw 'Build changed during the trial.'
    }
    Read-Sample 'finished' $work.cyclesCompleted
} catch {
    $errors.Add($_.Exception.Message)
} finally {
    if ($process -and -not $process.HasExited) {
        try { Invoke-BenchIpc quit @() prototype | Out-Null } catch { $errors.Add($_.Exception.Message) }
        if (-not $process.WaitForExit(10000)) { $process.Kill(); $process.WaitForExit(); $errors.Add('Forced shell termination.') }
    }
    if ($process) {
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { $errors.Add("Shell exit code $($process.ExitCode).") }
        $process.Dispose()
    }
    if ($log) { $log.Dispose() }
    if ($liveLock) {
        try { $liveLock.ReleaseMutex() } catch { }
        $liveLock.Dispose()
    }
    $metadata.qpcFrequency = [Diagnostics.Stopwatch]::Frequency
    ConvertTo-SafeManifestValue $metadata | ConvertTo-Json -Depth 32 | Set-Content "$RunRoot\metadata.json" -Encoding UTF8
    foreach ($sample in $samples) {
        foreach ($property in $sample.PSObject.Properties) {
            if ($property.Value -is [double]) {
                $property.Value = $property.Value.ToString('R', [Globalization.CultureInfo]::InvariantCulture)
            }
        }
    }
    $samples | Export-Csv "$RunRoot\samples.csv" -NoTypeInformation
    $actions | ForEach-Object { $_ | ConvertTo-Json -Compress } | Set-Content "$RunRoot\actions.jsonl" -Encoding UTF8
    [ordered]@{ completed=($errors.Count -eq 0); errorCount=$errors.Count; errors=@($errors); work=$work } |
        ConvertTo-Json -Depth 8 | Set-Content "$RunRoot\completion.json" -Encoding UTF8
}
if ($errors.Count) { throw ($errors -join ' ') }
