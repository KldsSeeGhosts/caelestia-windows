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

Pending the committed-source acquisition. No live recording or desktop tests
are authorized in this task.
