# Fullscreen transition trace

The backend trace is disabled by default. To enable it for a newly launched
backend process, set `QS_TRANSITION_TRACE` to an absolute JSONL file path in
the environment that launches the shell, for example:

```powershell
$env:QS_TRANSITION_TRACE = 'C:\path\to\isolated-run\backend-trace.jsonl'
```

The directory must already exist and be writable; failure to open it disables
the trace. The writer appends and flushes each record; use a fresh path per
process and remove the environment variable for subsequent launches. This setting does not start, stop, install,
or reconfigure the shell. Only the desktop orchestrator should arrange a
live launch. Do not put logs in the repository. Records contain HWNDs,
geometry and timing, so treat them as potentially sensitive.

Each backend record has `event`, `qpc` and `qpcFrequency` (decimal strings),
UTC, and process ID. QPC is sampled under the writer lock, so records from
multiple threads are ordered. Events include observed fullscreen, style,
physical rectangles, foreground and tracked focus, tiler state and reason,
placement request and result, AppBar calls, and work-area snapshots before,
after and on invalidation. Snapshots are observations, not a comprehensive
system-wide work-area event stream. `placement_verified` with `landed: false`
is an accepted fitting outcome, not a verified landing. UTC is for human
correlation, not interval measurement.

With a QPC-enabled supervisor action log from the same Windows boot, run:

```powershell
powershell -NoProfile -File windows/scripts/Measure-FullscreenTransition.ps1 `
  -BackendTrace C:\path\to\backend-trace.jsonl `
  -TaskbarActions C:\path\to\taskbar-actions.jsonl
```

The read-only script emits one object per observed fullscreen change, with
the time to suspension or a landed placement, taskbar-visible intervals, and
AppBar/work-area observations until that window's next fullscreen change or
the end of the logs. Pipe to `ConvertTo-Json -Depth 10` for nested details.
Missing endpoints remain null. Initial fullscreen observations are marked,
because they are not necessarily transitions. Taskbar action records are
observations around actions, not continuous visibility sampling. Unknown
starts/ends and durations remain null. A show timestamp is callback or polling
observation time, not necessarily the instant the taskbar became visible.
Even known intervals can miss flashes
between observations. Do not infer zero exposure from an empty interval list.
The script rejects missing QPC fields and differing frequencies; matching
frequencies alone cannot establish that logs came from the same boot.

Tracing adds synchronous file I/O and may affect latency. Use it to investigate,
and compare against a separate untraced baseline. It does not capture user
input or frame-level desktop video. Live enabling, capture, and desktop
validation remain the orchestrator's responsibility.

The parser fixture is `powershell -NoProfile -File windows/scripts/Test-MeasureFullscreenTransition.ps1`.
