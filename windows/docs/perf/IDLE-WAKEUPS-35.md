# Idle status and clock counts

Part of #35. This bounded extension of the #26 method measures event counts,
not CPU time, energy, frame timing or whole-shell utilization.

## Predeclared experiment

The recorder starts a status client every 15 seconds after its startup query.
The clock schedules one timeout per second even when neither seconds loader
exists. Target the recorder's recurring idle clients at zero, a reduction of
4 starts per minute. Target the clock at minute precision, a reduction of
59 timer callbacks per minute, about 98%. Preserve the single startup baseline
that discovers a recording after reload.

Use `windows/bench/idle_work.py` with a full baseline SHA. It reuses #26's
production staging, disposable profile, environment isolation and identity
receipts. It never loads the shell entry or creates a window. The real recorder
adapter and SystemClock run offscreen. Only Glazier's host controller is replaced
with a fake that cannot launch anything. The status executable accepts only
`--status`, logs its own start timestamp and returns synthetic idle JSON.
It cannot record, inject input or write a clipboard.

Count helper starts inside the observation window from the executable's own
log, not periodic process enumeration. Count Time.dateChanged notifications
after settling. With no configuration or precision changes during the window,
the pinned backend emits one notification per SystemClock timeout. These are
the two selected timer paths, not every OS or shell wakeup. Recorder timer
expiries produce the observed status starts in this healthy idle fixture.

Run three independent sessions, each with concurrent baseline A, duplicate A/A,
added-cost A and candidate B hosts. Alternate launch order. Each window lasts
60.25 seconds after three seconds settling. The independent count plant adds
one status process per 15 seconds and one timer callback per second.
Require A/A process counts to match and clock counts to differ by no more than
one. Require the plant to add 4 starts and 60 callbacks, with one callback
boundary tolerance. This establishes an event-count resolution of one event per
window, not the CPU/timing sensitivity of method.py's statistical gate.

Stop on any failed control, invalid response, incomplete host, behavior
regression or after these three fixed sessions. Do not retry toward a favorable
result. Keep raw receipts private. Record source, backend, binary, staged graph
and suite hashes. Run a separate 120-second candidate idle observation as a
bounded recovery/growth smoke check. It cannot replace the owner's live,
hour-long resource and recovery validation.

The shell regression runs a 16.25-second idle window, longer than the old
15-second poll, after synthetic startup, open/close, starting and disconnected
active recovery checks. It also verifies second ticks with two consumers,
removal of one consumer, and restoration of minute precision after the last
consumer leaves. The real seconds loaders retain/release the clock separately,
so per-screen settings and component destruction do not require a singleton
to read a screen-specific attached Config.

## Results

Measured on Windows build 26300, Qt 6.11.3, software/offscreen rendering.
The clean implementation revision was
`9f2ada0a6fe84c523085443eefaea3431d9e8b2f`. The baseline adapter revision was
`180f67122c8a95b3e09e306004769b8e03f6d324`. A and B used the same new count
host and staged graph, with only Recorder.qml and Time.qml replaced on A.
Neither UI seconds consumer exists in this count workload.
The native build source was `e6e8e6a852964c1d4633b19f2e9b4191967ba093`;
both sides used backend `53717a1dd8a458deb635f5f3b2f87b37e9cb87cd`.
No native inputs changed.

All three independent sessions produced these raw counts:

| Count per observation window | A | Duplicate A | Added-cost A | B |
| --- | ---: | ---: | ---: | ---: |
| Status client starts | 4 | 4 | 8 | 0 |
| SystemClock callbacks | 60 | 60 | 60 | 1 |
| Independent planted timer callbacks | 0 | 0 | 60 | 0 |

A durations were 60.257, 60.249 and 60.262 seconds. B durations were
60.252, 60.251 and 60.251 seconds. Every A/A and added-count control passed.
There were no retries or rejected trials.

Normalized rates, rounded to two decimals:

| Selected metric | Before per minute | After per minute | Change |
| --- | ---: | ---: | ---: |
| Recorder status processes and corresponding poll expiries | 3.98 | 0.00 | 100% fewer |
| SystemClock callbacks | 59.75 | 1.00 | 98.33% fewer |
| These two timer paths combined | 63.73 | 1.00 | 98.44% fewer |

Each candidate process made exactly one startup status query, excluded from
the settled idle window. This is deliberate reload recovery, not recurring
idle polling. The separate synthetic open/close regression made one extra
query when the consumer opened.

The separate 120.251-second candidate observation passed all 14 synthetic
behavior checks, with zero idle process starts and two clock callbacks.
This is a longer idle correctness observation only. It measures no resource
growth slope and does not qualify an hour-long live session.

Private count receipt SHA256:
`7ce73b6e84cec8a5d1a3b0052efab9d44c507b87361046809e793c3c44e02cc5`.
Longer observation receipt SHA256:
`1433bebd792e6d1a4258eadb60331b4283473381380a97881260708810d8393f`.
Suite SHA256:
`c7027fd6e87a77acdd8a8f6478c13eb9c6ae51dafd9036cb61fdfacaaec2979d`.
The private receipts retain all staged graph, binary and build receipt hashes.

All 26 Shell suite checks passed offscreen, including capture recording,
hotplug teardown and the new 14-assertion idle test. Existing headless recorder
logic passed 51 assertions. Performance-method analysis and negative count
controls passed 20 tests.

The Unit invocation completed 19 of 21 checks successfully. Its two failures
were missing toolchain executables on the invoking process's PATH:

```text
& : The term 'cmake' is not recognized as the name of a cmdlet, function, script file, or operable program. Check the
spelling of the name, or if a path was included, verify that the path is correct and try again.

AssertionError: unexpectedly None : CTest must be on PATH, as in hosted Windows
```

After prepending the existing `caelestia-dev/tools/Scripts` directory to PATH,
the targeted reruns passed: Test-Versioning with 98 assertions and
Test-NexusPipeline with 83 owner-tool assertions and 57 behavioral tests.
The original Unit suite receipt remains failed; it was not edited or relabeled.
Test-CIChanges and Test-RepositoryPolicy passed in that original run.
Test-PairContract passed 105 tests with one existing skip, and the explicitly
requested `python -B -m unittest windows/tests/pair_contract/test_pair_contract.py`
passed all 43 tests separately. No gate or verifier changed.

Reproduce the count acquisition from the repository root, with paths to the
matching offscreen build and Qt SDK:

```powershell
python -B windows/bench/idle_work.py --build $build --qt $qt `
    --baseline 180f67122c8a95b3e09e306004769b8e03f6d324
python -B windows/bench/idle_work.py --test --seconds 120 --build $build --qt $qt
```

No live recording or desktop tests were authorized or run. Actual recording
start/stop/pause, reload against a real ongoing recording, live native/GPU
costs and the owner's hour-long growth/recovery validation remain unqualified.
The measured result justifies these two count reductions in the isolated host,
not a whole-shell CPU, timing, power or release-acceptance claim.
