# Windows performance protocol

This suite supports issue #26. Issue #35 selects optimization patches only after
the relevant controls and live workload qualify. An acquisition's exit code says
whether it completed, never whether a candidate improved or is equivalent.

## Inventory and scope

The earlier `wip/26-perf-harness` publication had 5,574 lines across 21 files.
Its reusable ideas were bounded acquisition, immutable inputs, interleaved
pairs, explicit helper ownership and an allowlisted public export. Its
`combined` host is retired on current main. Its independent native layout
executable, lifecycle installer, broad selection map and multi-stage calibration
database are deliberately not ported. Historical floors, controls and verdicts
are not current evidence. No backend changes are needed.

The maintained implementation is `windows/bench/method.py`, `Bench.qml` and
`Stage-Bench.ps1`. It uses the normal production staging map, current Nexus
factory and current audio/media/search projection objects. The test host creates
the production drawer graph with disabled input and native providers. It does
not start the production shell entry, register an AppBar, install anything or
read an installed profile. That distinction limits every offscreen result.
The disposable host's fixed CPU spin exists only in this test file.
Nothing enables it in production.

Run pure regression tests with `python -B windows/bench/test_method.py -v`.
They run in the Unit suite. No benchmark acquisition runs in CI.
The first diagnostic report is [the 2026-11-10 baseline](BASELINE-2026-11-10.md).

## Workflow 1. Explore and profile

Use a Release build from `Build-Prototype.ps1`, not the installed shell. Main
uses Qt 6.11.3. On the campaign workstation the tool root is
`$env:LOCALAPPDATA\caelestia-dev-qt6113`. Pass the Qt prefix ending in
`Qt\6.11.3\msvc2022_64`. Build output must be separate from the source.
`-SkipCapture` is allowed for these offscreen tests, but that build cannot
qualify capture or an installable release.

Use `--purpose overhead --instrumentation qmlprofiler` to acquire A without
external profiling and B with the Qt QML profiler. The backend's `--debug`
listener binds `127.0.0.1`. The profiler attaches to the newly owned test process,
not an installed shell. Both sides use the same workload and alternate order.
For a single diagnostic pair, use `--purpose explore --pairs 1` instead.
It has no statistical verdict and cannot qualify a metric.
Keep `.qtd` files private. Parse actual duration ranges with:

```powershell
python -B windows/bench/method.py profile <private-trial-directory>\qml.qtd
```

The output contains private filenames. Inclusive range totals overlap. They
are not CPU self-time, percentages of whole-app CPU, or additive across nested
events. Rank a repeated expensive binding/creation path before proposing a
change, and confirm it without the profiler. Save the trace SHA256, event name,
relative repository filename, count, inclusive duration and symbol quality in
the report. Never publish arbitrary profiler `details` text.

`--purpose overhead --instrumentation transition` similarly enables the
backend's existing `QS_TRANSITION_TRACE` only on B. This records QPC events for
placement, foreground, work area and fullscreen transitions. It is not a
sampling CPU profiler. A software test may produce no native transition
events. That is missing coverage, not a zero-cost native path. Native owner
captures should correlate request/outcome timestamps, retain queue drops and
refusals, and exclude dropped/incomplete spans from latency claims.

Overhead controls report absolute differences and 95% intervals for every
metric, including startup debug attachment. There is no automatic subtraction.
`wallMs` includes profiler flushing and acquisition shutdown. Resource polling,
QML markers and the test host remain on both sides. Their absolute overhead
relative to an uninstrumented public release is **not measured**. Measure that
separately on the owner's disposable live candidate before transferring results.
External profiler CPU and storage activity are outside the shell process total.
ETW/WPR, GPUView and presentation tracing require a separate owner-run plan.
No suite command requests elevation or starts a system-wide trace.

## Workflow 2. Paired confirmation

Example A/A acquisition, from the repository root:

```powershell
$qt = "$env:LOCALAPPDATA\caelestia-dev-qt6113\Qt\6.11.3\msvc2022_64"
$build = "$env:LOCALAPPDATA\Temp\caelestia-perf-build"
$out = "$env:LOCALAPPDATA\Temp\caelestia-perf-aa"
python -B windows/bench/method.py run --build $build --qt $qt `
    --output $out --scenario launcher-search --purpose aa --pairs 24
```

Run an independent added-cost acquisition with another new output root,
`--purpose added --spin-ms 75`. Each of eight steps executes a timed QML CPU
spin. It adds approximately 75 ms to the per-step work span and 600 ms CPU to
the process. The actual observed effect and interval, not this nominal amount,
decide sensitivity. It does not qualify memory or startup-to-ready sensitivity.

```powershell
python -B windows/bench/method.py qualify <aa-root>\raw.json <added-root>\raw.json
python -B windows/bench/method.py analyze <comparison-root>\raw.json
```

For A/B use `--purpose compare --build-b <candidate-build> --source-b
<candidate-checkout>`. Both source checkouts must contain this exact suite.
Record its hash and apply the same method-only commit to both revisions if
needed. Builds must match native inputs and backend pins. The source tree,
staged graph and binaries are separate identities. A QML-only source override
does not relabel the native build revision. Do not rebuild or edit sources,
tools or payloads during an acquisition.

Every acquisition alternates AB, BA, AB, BA, with 12 to 48 complete pairs.
Default 24 pairs. There is no early stopping for a favorable result. A trial
has a 20-second process deadline. Acquisition refuses to start another trial
after 540 seconds, leaving room for the bounded current trial and reporting.
Staging commands have a 45-second timeout. A timeout or missing completion
marker leaves `complete:false`; analysis refuses it. The runner terminates only
its owned PID tree. Never retry a failing launch in a loop.

Each side gets a new stage and disposable profile under Windows Temp. `cold`
means an empty QML disk cache, not a cold OS/filesystem cache or cold boot.
`--cache warm` performs an unscored seed at the same absolute stage paths,
then starts a fresh process with that side's cache. A and B never share caches.
Before/after cache hashes and profile/config hashes are in the raw trial.
Always report cold and warm separately.

Raw receipts contain source SHA, native build source SHA, current backend pin,
working-diff and suite hashes, actual binary hashes, the build receipt hash,
the build's toolchain, staged graph hashes, profile/config and cache hashes,
Windows build and logical processor count. Dirty experiments are diagnostic.
Commit the exact suite and repeat before making a release acceptance claim.
Match CPU/GPU, driver, Windows build, power plan, power source, display topology,
refresh, scale and feature settings in a private owner environment manifest.
This suite does not infer machine equivalence from a computer name.

### Metrics and statistical decisions

All costs are lower-is-better. `readyMs` is process start to the parent observing
two software frames plus host readiness. Polling adds up to one 50-ms interval.
`workMs` is the mean of eight QML workload spans, with a high-resolution
elapsed timer. Search performs 100 generated queries per span. Audio/media
performs 100 synthetic projections per span. Panels include synchronous
open/close dispatch and Nexus construction, not animation completion.
Idle work is an empty control span, not idle utilization.
`cpuMs` is total process CPU through exit.
`privateMiB` is the maximum sampled simultaneous private committed total.
`wallMs` includes launch, workload and shutdown, not staging or identity hashing.

The analyzer computes a paired mean difference with a two-sided 95% Student t
interval. Pairs are the independent units. It uses conservative tabulated
critical values. Assumptions are independent pairs and approximately normal
pair means. Inspect raw differences for drift/outliers. There is no family-wise
or multiple-comparison guarantee. Do not pool different sessions or cache modes.

Fixed diagnostic floors are 50 ms readiness, 25 ms CPU, 4 MiB private commit,
10 ms per workload step and 100 ms wall time. They are declared before controls,
not inferred benefits or empirical detection limits. The measured interval
half-width is the session's resolution estimate. An effect must clear both
the floor and uncertainty.

* `improved` requires the entire interval below the negative floor.
* `regressed` requires the entire interval above the positive floor.
* `not-detected` requires the entire interval inside the declared floor.
  This is not equivalence, proof of no regression, or an optimization success.
* `inconclusive` covers overlapping thresholds and fewer than 12 pairs.

`qualify` recomputes raw verdicts. It requires a current A/A and independent
added-cost acquisition with identical identities and conditions. CPU and work
time qualify only when A/A is `not-detected` and the spin is `regressed`.
Every other metric stays unqualified. A missed plant or false-positive A/A
remains visible. Repeat at least three independent sessions before campaign
acceptance. Use a smaller plant to establish a smaller detection limit.
Do not infer small-effect sensitivity from a large plant.

No current command makes a p95/p99 latency claim. Eight events per trial are
insufficient, and combining correlated frames does not create independent
trials. A future latency adapter must retain timestamps and completion checks,
collect at least 200 observations per workload/side for p95 and 1,000 for p99,
and compute quantile uncertainty with session/block resampling. Those minima
are necessary, not sufficient for rare-stutter claims.

Automation must inspect each required metric's recomputed verdict and current
qualification. Reject a regression, inconclusive result, missed control or
unqualified required metric. Exit zero alone is never an acceptance gate.
The explicit fail-closed command requires at least three independent control
sessions, clean sources, matching method/environment, qualified selected metrics,
an improvement in every selected metric, and no detected regression:

```powershell
python -B windows/bench/method.py gate <comparison>\raw.json `
    --aa <aa1>\raw.json <aa2>\raw.json <aa3>\raw.json `
    --added <added1>\raw.json <added2>\raw.json <added3>\raw.json `
    --metric workMs
```

It exits 2 when rejected and returns JSON reason codes. It still does not
authorize promotion without the behavior, live and growth checks.

## Workflow 3. Owner live validation

These runs are not authorized on an unattended, occupied desktop. Never use
the installed shell/profile. The owner prepares a disposable candidate/profile,
explicit owned test windows and a synthetic content set. One operator controls
the desktop. Record the exact command/interaction, correctness result and
feature configuration. Do not transfer offscreen sensitivity to real D3D11/DWM.

Required owner runs:

| Scenario | Work and checks |
| --- | --- |
| Idle native/GPU | 120 seconds after settling, actual D3D11 presentation, display/power/driver identity, CPU, GPU, helpers and frame cadence. |
| Launcher/search | 256 generated apps, repeat, clear, missing and cancelled queries, check ordering and result publication, never launch a real app. |
| Panels and Nexus | Open/close launcher, dashboard, utilities, sidebar and Nexus. Check geometry, close completion, focus, scaling, animation and fullscreen recovery. |
| Audio/media | Generated tone/artwork and owned media session. Idle/play/pause/track bursts, endpoint loss and recovery. No recording of user audio. |
| Tiling | Owned synthetic windows only, explicit opt-in allowlist. Verify requested and acknowledged geometry, refusals, fullscreen, drag, reload and recovery with QPC trace. |
| Native/GPU | DWM/GPU presentation trace with matching symbols, hotplug and multi-monitor scaling. Software frames do not validate this. |
| Helpers/recovery | Capture with generated content, scheme/Python workers, notification bursts, clipboard only in an explicit synthetic test session, reload and recovery. |

Acquire matching live A/A, added-cost and instrumentation overhead controls
before scoring those metrics. Use native timing markers or QPC transitions
with valid endpoints, not these offscreen work spans. Live drivers and native
tail qualification remain owner work, not implemented automation in this suite.

### Resource accounting and longer-session growth

Short acquisition samples the root process and descendants every 50 ms.
It retains handles and creation times rather than summing processes by name.
CPU and private committed bytes are additive. Shared working sets are never
summed. Capture and Python helpers count only if parentage proves ownership.
Sub-50-ms helpers may escape polling. Record that limitation; verify it against
an owner process-lifecycle trace before claiming whole-app totals.
Do not use CPU cycles as utilization, context switches as wakeups or CPU time
as energy consumption.

The separate longer-session monitor accepts an explicit private manifest:

```json
{
  "processes": [
    {"pid": 1234, "creation100ns": 123456789000000000, "imageSha256": "<SHA256>"}
  ]
}
```

The lifecycle owner supplies this list from its process receipts, including
the shell, capture helper and Python helpers, plus source/binary identities and
ownership evidence. Never infer ownership from executable names. Then run:

```powershell
python -B windows/bench/method.py monitor --manifest <private-manifest.json> `
    --output <new-private-root> --seconds 3600 --interval 5
```

The monitor pins process handles and validates creation times and image hashes. A process exit
fails the observation. Unlisted/new helpers are outside this monitor's coverage.
It records private bytes, CPU, handles, GDI and USER counts over time.
Keep the workload/reload/recovery/cooldown schedule alongside its JSONL.
Inspect retention after cooldown and per-process slopes. No automatic leak
verdict is emitted. Do not extend a short paired benchmark into this session.

## Privacy, targets and stopping rules

All raw receipts, logs, profiles, monitor files and traces are private local
evidence. `public.json` uses an allowlist of numeric results, known scenario
names, version numbers and immutable hashes. It copies no arbitrary errors,
paths, profiler details, device identifiers or machine names. Review before
publication. No command uploads data.

Before a #35 patch, write its measured mechanism, provider/UI path, absolute
user-facing target, relative target above the qualified detection limit,
correctness checks and stopping rule. For example, reducing a demonstrated
creation span by 20 ms and 15% needs a control sensitive below that effect.
Do not choose those example numbers without baseline evidence.

Keep a patch only if a fresh same-session uninstrumented comparison clears
the target and controls, passes behavior tests and survives owner live/growth
validation. Stop after three bounded inconclusive confirmations, an effect
below detection, disproportionate complexity or any unresolved behavior
regression. Revert an unsuccessful experiment. Preserve cancellation,
ownership, animation and recovery contracts. Do not select a rewrite or native
replacement before traces identify a worthwhile cost.
