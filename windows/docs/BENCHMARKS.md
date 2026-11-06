# Windows performance tools

These public tools restore the existing paired shell harness and its focused
native/QML probes. They are not a new framework or a whole-app optimization.
No baseline, trace-backed hotspot ranking, current sensitivity qualification,
desktop smoothness or whole-shell savings is certified by this publication.
Working-file provenance hashes are in [origins.json](../bench/origins.json);
private history and private evidence links are not included.

The inventory is [map.json](../bench/map.json). Representative configurations,
fixtures, runnable drivers and explicit missing drivers are recorded in
[scenarios.json](../bench/scenarios.json). A manifest entry with a null driver
is blocked coverage, not an implemented or passing workload.

## Three different workflows

Explore/profile uses diagnostic probes and instrumented runs to find hypotheses.
Confirm uses fresh same-session paired acquisitions without external tracing.
Validate uses an explicitly authorized native desktop owner, representative
providers/GPU paths, correctness checks and a full paired suite at milestones.
Longer-session monitoring is separate from all scored benchmarks.
External profiling and optional native transition tracing are disabled in
confirmation. Readiness/geometry/frame markers remain part of acquisition;
their overhead is not yet characterized or claimed to be zero.

Never install, change autostart, enable tiling/takeover, open a native provider,
capture user data, elevate or change authentication implicitly. Offscreen
software rendering is not native D3D11/DWM presentation. Native read-only shell
observation adapters can still observe the system; use an authorized test host.

## Public selftests without a live shell

Run from the repository root with Python 3.10 or newer:

```powershell
py -3 -B windows/bench/test_shellbench.py -v
py -3 -B windows/bench/fixture_controls.py --output E:\Perf\fixture-controls
```

The first command tests the actual selection, interval/replay, qualification,
gate and accounting code. The second runs three independent arithmetic A/A
controls and three 100% added-operation controls, each with eight paired trials.
It preserves every raw observation, expected and actual verdict, including misses
and unresolved outcomes. Its ten-percent fixture threshold is arbitrary.
These fixtures cannot qualify native, QML, shell or desktop metrics, establish
app floors, measure trace overhead or demonstrate app savings.
The fixture counts actual successfully started subprocesses, not a hardcoded
expected count. `identityHashingSeconds` times only fixture identity hashing.
It is not runner setup, staging or shell turnaround. Older fixture receipts
with `setupSeconds` retain their historical bytes; that field measured hashing
only and must not be cited as setup/staging evidence.

## Confirm: immutable same-session pairs

Use matching clean Release builds and checked-out source revisions. No history
is imported or checkout created by these tools. Prepare builds through the
existing build workflow, outside the measured acquisition. To prepare only the
focused synthetic native probe, use:

```powershell
powershell -NoProfile -File windows/bench/tools/Build-Bench.ps1 `
    -SourceRoot C:\src\baseline -QtPrefix C:\tools\Qt `
    -PayloadRoot E:\build\baseline -BuildRoot E:\Perf\native-baseline
```

This standalone probe compiles with two jobs. Reuse it only when its exact
backend, probe source, CMake and executable hashes match. A Release probe is
synthetic layout/foreground logic, not native window placement or hook delivery.
Schema-2 probe receipts record the actual configured compiler/linker/CMake/Ninja
paths, executable hashes and reported versions, not just a requested selector.
Old receipts without those actuals must be rebuilt in a new root. Probe
executable, receipt and cache identities are checked before and after every
paired trial and at completion, including externally reused probe roots.

Select workloads before measuring:

```powershell
windows/scripts/Measure-Bench.ps1 -DiffBase origin/main -SelectOnly
windows/scripts/Measure-Bench.ps1 -Area tiling `
    -BaseRoot E:\build\baseline -BuildRoot E:\build\candidate `
    -BaseSourceRoot C:\src\baseline -SourceRoot C:\src\candidate `
    -QtPrefix C:\tools\Qt -NativeRootA E:\Perf\native-baseline `
    -NativeRootB E:\Perf\native-candidate -RunRoot E:\Perf\diagnostic-001
```

All evidence roots must be new and external to the tool/source and payload
trees. Do not edit, rebuild or clean measured files during acquisition.
The runner records clean shell/native/dependency revisions, build receipt,
executable, installed runtime and native module hashes, Qt DLL identities,
tool/scenario/settings hashes, isolated profile/cache policy and raw work.
The offscreen worker also records staged file and final QML-cache hashes.
Source overrides permit QML-only iteration only when native inputs and pins
match. Each fresh runtime trial gets its own process, profile and empty cache.
Disposable lifecycle runs require the installer's real `-NoIntegration` mode,
and refuse a legacy shortcut/HKCU fallback.

Protocol `public-paired-cost-v5` alternates AB then BA pairs by default. Seven
pairs remain the full-suite default, nine the focused default; use `-Runs 8`
for equal numbers of AB and BA pairs. Reference-dependent Panel, Resources,
Reload and Sensitivity plants require explicit `-Order AB`, for both controls
and comparisons. The provenance/gate repair invalidates old v4 qualification.
Do not mix ordering schemes within a qualification set.

The Python budget is 570 seconds; the outer PowerShell deadline is 580 seconds
including setup, workers and reporting. A timeout is a measurement failure,
never equivalence. Only the runner's owned child tree may be terminated.
Every subprocess timeout is capped by the remaining Python budget. Internal
deadline failures record `complete:false`, remove any cached summary and retain
an error. An outer kill writes a separate private `outer-deadline.json`, so a
partial Python write cannot hide the cause; campaign replay refuses that marker.
The longer-session monitor is not allowed to extend this bound.
The complete suite may exceed the budget on slower hardware and must then
be reported failed, not silently shortened. Select focused areas during edits.

Setup and total turnaround are in `setupSeconds`,
`setupIncludingNativeProbeSeconds`, `workerAcquisitionSeconds`, `wallSeconds`
and per-trial `wallSeconds`. Parent verification is separately recorded as
`integrityCheckSeconds`, and machine checks as `machineCheckSeconds`.
Worker acquisition wall time includes worker staging/metadata and is not a
scored duration. `measurementSeconds` is deliberately null: use each metric's
raw timers, rather than inventing one universal measurement duration.
Worker setup includes actual staging. Do not describe
these as measured staging-cache savings. Staging is retained, not reused across
trials; native probes can be reused after identity verification. Benchmark
staging copies and all raw evidence are retained, including after failures.

`results.json` is replayable raw evidence; `report.html` is self-contained.
Replay into a new directory without overwriting acquisition evidence:

```powershell
py -3 -B windows/scripts/ShellBench.py summarize E:\Perf\confirm-001\results.json `
    --output E:\Perf\replay-001
```

All costs are lower-is-better. Exact paired signed-rank/Walsh intervals assume
independent, continuous, symmetric paired log errors. `same` means within the
declared diagnostic floor, not exact equality. Preserve `improved`, `same`,
`regressed`, `unresolved` and measurement failure as different outcomes.
The inherited floors and historical metric-removal rationale are diagnostic
inputs, not newly reproduced evidence. Native floors of at least five percent
do not establish reliable detection of five-percent improvements.
There is no multiple-comparison/family-wise guarantee.

## Independent qualification and automation

Run at least three independent identical-artifact A/A acquisitions and three
repeats per relevant added-cost size. Use the same machine, Qt/runtime,
configuration, tool hashes, cache and order as the future comparison. For
example, use `-PlantB Tiling -PlantPercent 25` for the synthetic tiling plant.
Recalibrate floors using independent A/A discovery data, freeze them, then
acquire new held-out A/A and added-cost confirmation. Do not tune floors on the
same controls used to claim validation.
Discovery requires three original unplanted acquisitions made with
`-Purpose floor-discovery`. After calibration, make each new A/A and added-cost
control with `-Purpose held-out -Calibration E:\Perf\discovery-floors.json`.
Make the fresh candidate comparison with `-Purpose confirm` and that same
calibration. Without frozen provenance a run is diagnostic-only by default.

```powershell
py -3 -B windows/scripts/ShellBench.py calibrate `
    E:\Perf\discovery-aa1\results.json E:\Perf\discovery-aa2\results.json E:\Perf\discovery-aa3\results.json `
    --output E:\Perf\discovery-floors.json
py -3 -B windows/scripts/ShellBench.py qualify `
    --calibration E:\Perf\discovery-floors.json `
    --aa E:\Perf\aa1\results.json E:\Perf\aa2\results.json E:\Perf\aa3\results.json `
    --added E:\Perf\plant1\results.json E:\Perf\plant2\results.json E:\Perf\plant3\results.json `
    --output E:\Perf\qualification
py -3 -B windows/scripts/ShellBench.py gate E:\Perf\confirm-001\results.json `
    --qualification E:\Perf\qualification\qualification.json --expect improved
```

Qualification refuses fixtures, failed/nonraw acquisitions, different payloads
within controls, repeated input records and configuration changes. Original
acquisition IDs, canonical raw acquisition identities and per-trial raw hashes
are deduplicated across discovery, held-out controls and confirmation. Renaming
an acquisition, reanalyzing it or copying some of its trials does not make it
independent. Analysis replays cannot supply qualification inputs. The frozen
calibration is reproduced from its original discovery receipts; controls must
record its exact identity and floors. A map-file hash alone is not provenance.
These checks prevent receipt reuse, not deliberate fabrication of source data.
It retains
unresolved A/A outcomes, plant misses and tested nominal sizes. Unsupported
plants/metrics cannot qualify by omission. In particular, the fixed-delay QML
load plant is not yet mapped into the percentage-based qualification contract;
full-suite qualification remains blocked until all selected metrics have
appropriate controls. Smaller-than-tested sensitivity is never inferred.
`gate` recomputes raw metric verdicts and the supporting controls, rather than
trusting an acquisition exit code or a hand-edited qualification boolean.
It rejects unresolved, unqualified, planted or regressed comparisons.
Native probe/toolchain fingerprints are part of qualification environment and
payload identity. A changed probe invalidates the previous qualification; the
gate does not transfer sensitivity between native binaries. Current native
candidate acceptance remains blocked until matching proof is available.

Panel p95 requires at least 200 completed observations per panel in every trial.
The existing two-opening workload is marked
`diagnostic-only-insufficient-observations` by replay and qualification, and
cannot pass `gate` even when all A/A and added-cost verdicts resolve. A protocol
field cannot lower this hard minimum. This does not qualify rare-stutter claims
automatically at 200; distribution quality and uncertainty still need review.

Timing plants require actual worker evidence: fired panel timers with measured
delay; executed startup/reload burn markers; completed assembly/activation
hashes; and completed additional quantizer calls. Missing or invalid reference
keys refuse acquisition instead of falling back to one millisecond.
Sensitivity checks every selected constituent. Nominal effects are
metric-specific: panel delays are based on paired p50, not a p95 percentage;
startup is a fixed 400 ms; update uses 256 additional hashes; scheme uses eight
additional quantizations. Qualification records these units and per-metric
relative amounts rather than relabelling every plant as a percentage.

Exit zero from acquisition/replay only means execution/reproduction succeeded.
It can accompany unresolved results. Campaign automation must call `gate` and
inspect all metric verdicts. A statistical gate is not promotion authorization:
absolute user benefit, correctness, full-suite, desktop and longer-session
checks remain separate requirements.

## Evidence privacy and public summaries

All raw `results.json`, build/probe receipts, calibration, qualification,
profile, monitor, logs and trace artifacts are PRIVATE local evidence.
They can contain absolute paths, the full build record, an unsalted truncated
MachineGuid hash, power-scheme output, monitor geometry and process identities.
Do not attach these raw files or their private HTML reports to public issues.
No command uploads them or automatically publishes evidence.

Generate an allowlisted numeric summary instead:

```powershell
py -3 -B windows/scripts/ShellBench.py export-public E:\Perf\confirm-001\results.json `
    --output E:\Perf\public-summary-001
```

The exporter constructs only fixed fields and known metric names. It excludes
commands, raw trials, local paths, machine/build records, arbitrary errors and
free-form metadata. It does not recursively copy/redact unknown fields.
Qualification export also rechecks supporting evidence. Manually review the
new `public-summary.json` before any separately authorized publication.
An allowlisted summary is not whole-app certification or upload permission.

## Explore: bounded Windows and QML profiling

Inspect capability and immutable candidate identity without capture:

```powershell
py -3 -B windows/scripts/ShellBench.py profile --qt C:\tools\Qt `
    --build E:\build\candidate --source C:\src\candidate --seconds 30 `
    --output E:\Perf\profile-inspection
powershell -NoProfile -File windows/bench/tools/Capture-WindowsTrace.ps1 `
    -RunRoot E:\Perf\wpr-inspection
```

Inspection saves tool hashes/help, explicit capability refusals and an empty
hotspot list. It does not activate a debugger or claim overhead. A Qt runtime
does not imply a QML profiler CLI, debug-enabled target, symbols or events.
The QML plan requires loopback-only attachment to a disposable, debug-enabled
process and a profiler-supported bounded record duration. If these capabilities
are absent or unverified, capture is blocked. No guessed CLI syntax is executed.
The bounded interactive adapter can inspect the actual tool without attaching:

```powershell
powershell -NoProfile -File windows/bench/tools/Capture-QmlProfile.ps1 `
    -ProfilerPath C:\tools\Qt\bin\qmlprofiler.exe -RunRoot E:\Perf\qml-inspection
```

For later authorized capture, supply `-Capture -AuthorizedPrivateCapture
-DisposableTarget -TargetPid <pid> -TargetCreationTime100ns <filetime>
-TargetImageSha256 <hash> -Port <loopback-port> -Seconds 30` and a new root.
The adapter verifies the PID/image/creation identity and loopback listener,
attaches without launching/reconfiguring the target, records for the bounded
period, flushes and quits only its owned profiler. It refuses missing features,
early exits, missing output, unsupported trace XML or zero timestamped ranges.
Actual capture, event analysis and matched-symbol qualification remain gates;
help inspection does not establish a working debug target or usable events.

Only the separately authorized Windows operator may request native capture:

```powershell
powershell -NoProfile -File windows/bench/tools/Capture-WindowsTrace.ps1 `
    -RunRoot E:\Perf\trace-001 -Seconds 30 -Capture -AuthorizedPrivateCapture
```

The adapter requires already elevated authority for kernel tracing, uses its
own unique WPR instance for start/stop, never cancels another session, and
retains errors/interrupted output. It never requests elevation. Stop/merge is
bounded too. Raw ETL may contain system/user content: keep it private. Native
stack attribution needs matching symbols; GeneralProfile alone is not a GPU,
DWM, presentation, power or input-to-photon qualification.

Measure tracing/profiler overhead with independent matched instrumented and
uninstrumented runs on the same workload before interpreting it. Record actual
absolute/relative overhead and uncertainty. An absent measurement is
`not-measured`, never zero overhead. Rank only real events/stacks, recording
trace hash, symbol quality, total/self cost, whole-app fraction, scenario
frequency, user benefit, risk and implementation cost.

## Longer-session resource observation

`ShellBench.py monitor` reads explicitly identified shell/helper processes,
never launches a shell or touches input. Supply an external JSON manifest:

```json
{
  "candidateIdentity": {"shellRevision": "<exact SHA>", "payloadSha256": "<exact hash>"},
  "ownershipEvidence": "<private lifecycle receipt proving these helpers belong to this shell>",
  "processes": [
    {"role": "shell", "pid": 1234, "creationTime100ns": 123456789, "imageSha256": "<SHA256>"},
    {"role": "owned-helper", "pid": 1235, "creationTime100ns": 123456790, "imageSha256": "<SHA256>"}
  ]
}
```

```powershell
py -3 -B windows/scripts/ShellBench.py monitor --manifest E:\Perf\owned-processes.json `
    --seconds 3600 --interval 5 --allow-process-observation --output E:\Perf\monitor-001
```

The lifecycle owner supplies ownership evidence, not a name-based process guess.
Pinned handles, creation times and image hashes prevent PID-reuse attribution.
An exited/missing helper fails the observation. Unlisted/transient helpers are
explicitly outside coverage. Private committed bytes, handles and CPU time are
additive; shared working sets are reported per process and never summed.
CPU core-percent is a diagnostic, not battery savings. Scheduling diagnostics
need ETW; context switches are not wakeups. Collection time is recorded, but
collection overhead is not automatically subtracted or declared qualified.
Record the idle/interaction/recovery schedule and cooldown separately. Raw
retention after repeated interactions and growth trends require interpretation;
the monitor deliberately emits no automatic leak verdict. Earlier bounded soak
acceptance is retained, not reopened or extended to current candidates.

## Campaign gates and stopping rules

First acquire a representative identified baseline and real traces. Supported
hardware coverage initially means only the measured configuration. Record
Windows/CPU/GPU/driver, power, displays, refresh, scaling, feature configuration
and helper ownership; extend coverage deliberately to laptop/iGPU and other
display/power configurations before claiming broader support.

Before each patch, freeze a baseline-derived absolute target in user-facing
units and a relative target above the qualified detection limit. Rank expected
benefit, evidence strength, risk and cost. Example units are milliseconds to
ready/frame, CPU milliseconds per interaction, and private committed MiB after
cooldown. Do not set arbitrary universal percentages as user benefits.

Preserve upstream UI, motion, behavior, cancellation and recovery. An explicit
feature tradeoff needs a separate decision. Reject a patch that fails behavior
checks, regresses a selected metric, or remains unresolved after three bounded
same-session confirmations. Stop pursuing effects below detection resolution,
disproportionate complexity or improvements without meaningful absolute benefit.
Do not substitute historical comparisons for a fresh same-session baseline,
mandate a language rewrite, or project helper throughput onto whole-shell gains.
