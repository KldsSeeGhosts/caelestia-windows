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

A build root records its checkout's path, not its revision.
If that checkout has moved since the build, the runner refuses to start.
Pass `-SourceRoot` with a checkout of the built revision, for example a
detached `git worktree add --detach <dir> <sha>`.

`benchmark.json` contains the raw trial summaries, exact revisions, work
counts, errors, machine load, median, range, and comparison.
It is raw evidence and may contain paths from logs.
Keep the run directory for the raw samples, actions, startup phases, and traces.
`verdict.json` is the shareable, agent-facing result described below.

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
    -RecoverySeconds 30
```

Keep the normal recovery period for resource net-growth calibration.
Short recovery windows can include transient UI allocations after close frames.

## Validate isolation and sensitivity

Run each category on `NonVisible` and `Offscreen` before choosing its mode.
`NonVisible` creates a separate desktop and starts its worker there through
`STARTUPINFO.lpDesktop`. It never switches the user's desktop.
Native startup performs the normal stale AppBar registration cleanup and preserves live registrations.
`Offscreen` uses Qt's software scene graph at the virtual screen's scale.
Its results do not establish native D3D11, DWM, native-object, or live idle parity.
Check `workloadDimensions` for missing provider data as well as rendered frames.
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
Add `-SaveBaseline <name>` to save side A, or `-SaveBaselineB <name>` to save
side B, when every group of that side is valid and unplanted.
The default store is
`%LOCALAPPDATA%\caelestia-windows-bench\baselines\<machine>\<name>.json`.
Use `-BaselineRoot` to choose another external directory.
Existing baseline names cannot be overwritten.
A baseline holds contracts, distributions, per-trial metric values, and
revisions. It holds no paths, logs, or raw samples.

Add `-CompareBaseline <name>` to compare the current A trials with that baseline.
The runner takes the baseline's metrics, mode, and workload unless you pass them.
The machine, Windows build, Qt version, core count, mode, screen geometry,
scale, workload, service control gates, and both measurement-script hashes must match.
The machine is a truncated SHA-256 of the Windows installation's `MachineGuid`.
Any change to `Measure-ShellRuntime.ps1` or `Summarize-ShellRuntime.py`
changes their hashes, so record new baselines after a protocol change.
Baselines and raw evidence stay outside the repository.
Do not save a calibration as evidence of production parity.

Record and compare, for example before promoting `dev` to `main`.
Run multi-metric commands from a Windows PowerShell prompt, not through
`powershell -File`: `-File` binds `-Metric Idle, Panel, Reload` as `Idle` alone.
The script's exit code is then in `$LASTEXITCODE`.

```powershell
$wt = 'C:\b-perf\src'
git worktree add --detach "$wt\main" <main-sha>
git worktree add --detach "$wt\dev" <dev-sha>
windows/scripts/Measure-ShellBenchmark.ps1 `
    -QtPrefix $qt -BuildRoot C:\b-main -SourceRoot "$wt\main" `
    -BuildRootB C:\b-dev -SourceRootB "$wt\dev" `
    -RunRoot C:\b-perf\runs\promote -Metric Idle, Panel, Reload -Mode NonVisible `
    -SaveBaseline main-<main-sha> -SaveBaselineB candidate-<dev-sha>
```

Then compare any later build with the saved baseline:

```powershell
powershell -NoProfile -File windows/scripts/Measure-ShellBenchmark.ps1 `
    -QtPrefix $qt -BuildRoot C:\b-topic -RunRoot C:\b-topic\runs\perf `
    -CompareBaseline main-<main-sha>
```

`Test-Candidate.ps1 -PerformanceBaseline <name>` runs the same comparison as a
manifest step after the correctness gate. The step fails unless the verdict is
`same` or `improved`.

The resource soak uses the same tooling. Each side takes about 3 hours:

```powershell
powershell -NoProfile -File windows/scripts/Measure-ShellBenchmark.ps1 `
    -QtPrefix $qt -BuildRoot C:\b-main -SourceRoot "$wt\main" `
    -BuildRootB C:\b-dev -SourceRootB "$wt\dev" `
    -RunRoot C:\b-perf\runs\resources -Metric Resources -Mode NonVisible `
    -SaveBaseline main-<main-sha>-resources -SaveBaselineB candidate-<dev-sha>-resources
```

## Read the verdict

Agents act on the exit code and `verdict.json` alone.

| Exit | Overall verdict | Meaning |
| --- | --- | --- |
| 0 | `same`, `improved`, `measured` | No gating metric regressed and every group was valid. `measured` means nothing was compared. |
| 1 | none | Runner error: bad arguments, failed summary, private data in a record, or a refused baseline. |
| 2 | `regressed` | At least one gating metric regressed. |
| 3 | `inconclusive` | A group failed, ran fewer than five trials, or lost a metric, and nothing regressed. |
| 4 | `mismatch` | The contracts differ. Nothing in that group was compared. |

When several apply, the order is mismatch, regressed, inconclusive, improved,
same. A skipped, failed, or missing metric is never a pass.

`verdict.json`, schema version 1:

```json
{
  "schemaVersion": 1,
  "overall": "same",
  "exitCode": 0,
  "analysisSha256": "...",
  "groups": {
    "A/Panel": { "valid": true, "trials": 5, "errorCount": 0, "shellRevision": "...",
                 "backendPin": "...", "buildSourceRevision": "...", "payloadSha256": "...", "plant": "None" }
  },
  "comparisons": [
    { "baseline": "A", "candidate": "B", "overall": "same",
      "metrics": {
        "panelShellRequestToFrameMs": {
          "group": "Panel", "gating": true, "verdict": "same",
          "baselineMedian": 503.3, "candidateMedian": 503.9, "delta": 0.6, "deltaPercent": 0.12,
          "noiseFloor": 1.9, "baseline": { "runs": 5, "median": 503.3, "min": 502.9, "max": 504.8, "spread": 1.9 },
          "candidate": { "runs": 5, "median": 503.9, "min": 503.1, "max": 504.4, "spread": 1.3 } } } }
  ]
}
```

A two-build run compares A with B. `-CompareBaseline` adds a comparison of the
baseline (`"baseline": "baseline:<name>"`) with A. An inconclusive metric has a
`reason`, and a mismatched one lists the differing `contractMismatch` fields.
Metrics with `"gating": false` are advisory and never decide the verdict.
Every current metric is a cost, so a higher median is a regression.

### Determinism rule

Each metric compares medians of at least five fresh-process trials per side.
The noise floor is the larger run-to-run range (maximum minus minimum) of the
two sides. A median delta within the floor is `same`. A larger delta is
`regressed` or `improved`.

The range rule needs no distribution assumption, and five alternating trials
give it both the in-run drift and the outliers that a variance estimate would
smooth away. For identically distributed sides, a false `regressed` needs the
two samples almost completely separated and the median gap wider than either
range. Complete separation alone has a chance of 1 in 252. Each plant is far
outside the floor of its metric.

An A/B run alternates sides, so slow machine drift affects both equally. A
comparison with a saved baseline crosses sessions and can include drift that
neither range saw. Treat a small regression against an old baseline as a reason
to run an A/B comparison, not as proof.

Run the parser and comparison fixtures without launching a shell.

```powershell
windows/scripts/Measure-ShellBenchmark.Tests.ps1 -TestRoot C:\b-bench\fixtures
```
