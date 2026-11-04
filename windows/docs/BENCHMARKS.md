# Measure shell runtime changes

Use the inbox Windows PowerShell host, `powershell.exe`.
Each build root's `caelestia/CMakeCache.txt` identifies its shell checkout.
The runner stages that checkout's QML and uses the build root's native binaries.
Use `-SourceRoot` and `-SourceRootB` only to override those checkouts deliberately.
Use matching release builds from `Build-Prototype.ps1`.
Do not rebuild or edit either payload during a run.

```powershell
$qt = "$env:LOCALAPPDATA\caelestia-dev\Qt\6.11.2\msvc2022_64"
powershell -NoProfile -File windows/scripts/Measure-ShellBenchmark.ps1 `
    -QtPrefix $qt -BuildRoot C:\b-bench -BuildRootB C:\b-bench-b `
    -RunRoot C:\b-bench\runs\comparison -Metric Idle -Mode NonVisible
```

Select `Idle`, `Resources`, `Panel`, or `Reload` with `-Metric`.
Omit the parameter to measure all four categories.
Each category runs in a fresh process at least five times per side.
The runner alternates A and B within each category.
Use the same root twice for an A/A check.
QML, Quickshell IPC, and Qt pipeline caches stay in the trial profile.
Each trial starts with an empty pipeline cache and warms it through its workload.
Qt supports explicit load and save paths for this cache.
See the [Qt pipeline-cache documentation](https://doc.qt.io/qt-6.11/qquickgraphicsconfiguration.html#pipeline-cache-save-and-load).

`benchmark.json` contains the raw trial summaries, exact revisions, work
counts, errors, machine load, median, range, and comparison.
Keep the run directory for the raw samples, actions, startup phases, and traces.
A failed action, incomplete trial, changed workload, or fewer than five trials
makes the comparison inconclusive.
The noise floor is the larger run-to-run range of the two sides.
A median delta inside that range is no measurable difference.

## Choose a workload

The default idle workload warms for 120 seconds, then observes 300 seconds
without IPC traffic or input.
`idleCpuCorePercent` uses one logical core as 100%.
`idleCpuMachinePercent` divides that value by the logical core count.
Both use CPU-time deltas across the measured interval, not a mean of samples.

The resource workload first visits every tested panel and Nexus.
It then warms, records idle counters, performs 100 open-close cycles across
dashboard, launcher, utilities, sidebar, and the Nexus audio page, and records
30 seconds of recovery.
Cycles start at least 15 seconds apart.
The default trial takes about 35 minutes.
Private bytes, working set, handles, GDI objects, and USER objects each report
net growth from warmed idle and least-squares slopes per cycle and per minute.
Retained caches can cause a net increase without a sustained leak.
Inspect the raw cycle and recovery samples before making a leak claim.

Panel trials alternate fully-open drawers and fully-closed idle state.
The disposable test host confirms nonzero geometry and two rendered frames
after the drawer reaches its open position.
The parent measures IPC dispatch through receipt of the frame marker.
This value includes IPC process startup and log transport.
The shell also records its own request-to-frame timer.
Each drawer has its own aggregate so a slow drawer cannot hide in the pooled median.
Neither value measures DWM scanout or physical input-to-photon latency.
Nexus keeps its normal platform placement. Each action records its actual scale.

Reload trials use a stopwatch around the existing soft reload operation.
Completion requires a different generation and that generation's first frame.
The existing `quickshell.startup` phases remain in each trial summary.
The process ID does not change.

For a short calibration, override the workload explicitly.
Do not call a short calibration a warmed runtime baseline or a soak.

```powershell
powershell -NoProfile -File windows/scripts/Measure-ShellBenchmark.ps1 `
    -QtPrefix $qt -BuildRoot C:\b-bench -BuildRootB C:\b-bench-b `
    -RunRoot C:\b-bench\runs\calibration -Metric Resources -Mode NonVisible `
    -WarmupSeconds 5 -IdleSeconds 10 -Cycles 10 -CycleIntervalSeconds 0 `
    -RecoverySeconds 5
```

## Validate isolation and sensitivity

Run each category on `NonVisible` and `Offscreen` before choosing its mode.
`NonVisible` creates a separate desktop and starts its worker there through
`STARTUPINFO.lpDesktop`. It never switches the user's desktop.
`Offscreen` uses Qt's software scene graph at the virtual screen's scale.
Its results do not establish native D3D11, DWM, native-object, or live idle parity.
The native mode records a refused foreground activation as an isolation warning.
It still requires the Nexus window to render before counting that action.

Check frame counts and work counts, run an A/A comparison, then repeat with
`-PlantB CPU`, `Resources`, `Panel`, or `Reload` for the matching category.
The plants run only in generated test QML. No production code reads a test flag.
The CPU plant adds an eight-millisecond busy timer.
The resource plant retains an array on each open.
Panel and reload plants add a 400-millisecond delay before the actual operation.
The resource plant checks allocation sensitivity, not native-object sensitivity.
Do not freeze a metric until the relevant planted regression exceeds its noise.

If neither isolated mode reproduces the production workload, reserve that metric
for the desktop QA owner. `-Mode Live` refuses without `-LiveDesktop`.
Live trials still use a separate profile and read-only service gates.
They do not replace, install, stop, or reload the installed shell.
Coordinate with other desktop work before running them.

## Store and compare baselines

Without `-BuildRootB`, the runner measures only side A.
Add `-SaveBaseline <name>` to save successful unplanted results.
The default store is
`%LOCALAPPDATA%\caelestia-windows-bench\baselines\<machine>\<name>.json`.
Use `-BaselineRoot` to choose another external directory.
Existing baseline names cannot be overwritten.

Add `-CompareBaseline <name>` to compare the current A trials with that baseline.
The machine, Windows build, Qt version, core count, mode, screen geometry,
scale, workload, service control gates, and both measurement-script hashes must match.
Baselines and raw evidence stay outside the repository.
Do not save a calibration as evidence of production parity.

Run the parser and comparison fixtures without launching a shell.

```powershell
windows/scripts/Measure-ShellBenchmark.Tests.ps1 -TestRoot C:\b-bench\fixtures
```
