# Fullscreen transition trace

The backend trace is disabled by default. To enable it for a newly launched
backend process, set `QS_TRANSITION_TRACE` to an absolute JSONL file path in
the environment that launches the shell, for example:

```powershell
$env:QS_TRANSITION_TRACE = 'C:\path\to\isolated-run\backend-trace.jsonl'
```

The directory must already exist and be writable; failure to open it produces
no trace. A worker appends and flushes records; use a fresh path per
process and remove the environment variable for subsequent launches. This setting does not start, stop, install,
or reconfigure the shell. Only the desktop orchestrator should arrange a
live launch. Do not put logs in the repository. Records contain HWNDs,
geometry and timing, so treat them as potentially sensitive.

Each backend record has `event`, `qpc` and `qpcFrequency` (decimal strings),
UTC, and process ID. QPC is sampled under the writer lock, so records from
multiple threads are ordered. Producers use a non-waiting bounded queue; if
the queue is full or contended, events are dropped and a `trace_dropped`
record reports the count once the queue drains. Shutdown waits at most 250 ms
for the worker; a blocked sink or process termination can lose queued records
and drop reports. UTC is estimated from a single startup QPC/UTC calibration,
so later wall-clock changes are not reflected. Events include observed fullscreen, style,
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
starts/ends and durations remain null. In-interval `ObservationQpc` values
preserve visibility observations even when both endpoints are unknown. A show timestamp is callback or polling
observation time, not necessarily the instant the taskbar became visible.
Even known intervals can miss flashes
between observations. Do not infer zero exposure from an empty interval list.
The script rejects missing QPC fields and differing frequencies; matching
frequencies alone cannot establish that logs came from the same boot.

Tracing adds timestamping and bounded enqueue overhead, and can drop records.
The worker performs file I/O separately. Use it to investigate, and compare
against a separate untraced baseline. It does not capture user
input or frame-level desktop video. Live enabling, capture, and desktop
validation remain the orchestrator's responsibility.

The parser fixture is `powershell -NoProfile -File windows/scripts/Test-MeasureFullscreenTransition.ps1`.

## Dia investigation, issue #26 (2026-10-28)

The supplied build-40b8b4c0 trace was summarized with PowerShell, without
publishing its window identities or browsing data. All times below are UTC.
There are five complete observed fullscreen cycles and an exit from the
initially fullscreen window. There are no input/action markers, so these
cycles cannot reliably be labelled as video fullscreen versus F11.

The suspicious totals are startup observations, not transition churn:

- All 131 `work_area` records occur at 05:48:16.872 through 05:48:19.498.
  They comprise 8 `before_register`, 8 `after_register`, 13 `before_position`,
  13 `after_position` and 89 `position_invalidated` observations. A snapshot
  is not itself a work-area change.
- All 8 `appbar_register` records occur by 05:48:18.809; all 13
  `appbar_position` records occur by 05:48:19.481.
- The sole `trace_dropped` report is at 05:48:18.665, with count 1, during
  startup. No drop is reported during the later cycles, although the trace
  cannot prove that an unreported producer event never happened.
- Four of the 9 `placement_request` records are startup placements of
  another application, not requests against the fullscreen browser.

The initial `fullscreen=true` observation is at 05:48:16.843. Its exit
(`fullscreen=false`) at 05:49:09.096 has no `placement_request`; a
`placement_verified` follows at 05:49:09.128. There are no AppBar fullscreen
callbacks recorded for this initial exit.

| `fullscreen=true` | Exit `window_style` | `placement_request` | `fullscreen=false` | Entry/exit requests | `appbar_fullscreen` | `work_area` |
| --- | --- | --- | --- | --- | --- | --- |
| 05:49:18.226 | 05:49:21.346 | 05:49:21.382 | 05:49:21.428 | 0 / 1 | 4 open, 4 close | 0 |
| 05:49:25.167 | 05:49:29.887 | 05:49:29.913 | 05:49:30.029 | 0 / 1 | 4 open, 4 close | 0 |
| 05:49:32.429 | 05:49:36.927 | 05:49:36.960 | 05:49:37.016 | 0 / 1 | 4 open, 4 close | 0 |
| 05:49:40.468 | 05:49:42.778 | 05:49:42.805 | 05:49:42.841 | 0 / 1 | 4 open, 4 close | 0 |
| 05:49:46.284 | 05:49:48.729 | 05:49:48.762 | 05:49:48.805 | 0 / 1 | 4 open, 4 close | 0 |

Every observed entry's raw and DWM rectangles cover the Dell monitor, not
the smaller reserved work area or tile. There is no entry placement sequence
constraining those rectangles. On exit, the browser regains its native frame
styles while its raw rectangle still covers the monitor; the tiler then
requests its saved tile before geometry-based fullscreen detection clears.
This proves an early restore opportunity, not repeated placement contention,
and does not prove which component paints a grey frame.

The private F11 screenshot has a near-edge browser surface, rounded corners
and a thin exposed outer strip; toolbar/sidebar geometry lies inside that
surface. It has no matching trace/input marker. Neither the screenshot nor
`appFullscreen=true` proves that Dia asked for only a work-area rectangle.
In this backend, that state is a geometry observation, not confirmation that
Dia has hidden its own chrome. The trace does not support forcing a new
monitor-sized placement or changing AppBar reservations to fix F11.

### Backend changes and limits

- A style-confirmed exit that still has fullscreen geometry gets the existing
  120 ms style recheck before the tiler can restore its tile. If the app
  restores its own rectangle first, geometry ends the wait immediately.
  A still-stale normal placement gets one bounded fallback. Native
  monitor-covering fullscreen-style re-entry blocks placement even for an
  explicit tile whose tracker notification is still queued.
- Fullscreen windows no longer keep the tiler's custom DWM border colour
  simply because they retain their layout slot. This was reproducible in a
  fake-desktop regression with frame styles retained. Resetting the custom
  colour does not remove Dia's own frame, rounded corners, toolbar or sidebar.
- AppBar fullscreen state, registration seeding and deferred retries are
  monitor-scoped. Duplicate edge callbacks cause one effective stack change.
  Existing reservations remain registered and unchanged. `appbar_fullscreen`
  and `appbar_fullscreen_settled` now include the receiving monitor;
  `panel_fullscreen` records effective stack-state changes.

The tests run the real tiler against a fake desktop and replay the initial
episode plus five cycles at negative monitor coordinates, automatic/explicit
tiling, app-led restoration and stale-normal-placement fallback. They check
zero entry/sustained-fullscreen moves, at most one exit move, unchanged
neighbours and work areas, bounded settling, queued re-entry and border-colour
restoration. The pure AppBar-state test covers monitor isolation, duplicate
edge notifications, simultaneous fullscreen episodes, late registration and
stale retries. It does not exercise Explorer or observe real work-area
notifications. No live shell, DWM frames or visual improvement was verified.
The old trace does not observe shell drawing/layer animation or DWM presents,
so grey-frame attribution to the app/DWM versus shell drawing remains open.

### Required live check

After the backend PR lands on fork `dev`, update/confirm both pins before
merging the companion shell PR. The dedicated desktop QA controller should:

1. Use the Dell at 175% and MSI at 150%, retaining their current arrangement.
   Record the normal raw/DWM tile rectangle and work area on each monitor.
   Use a fresh backend trace and timestamped input markers, without titles
   or browsing content in any shared evidence.
2. On each monitor separately, enter/exit video fullscreen three times and
   F11 three times. Mark each input and capture the raw/DWM rectangle,
   monitor, style, `appFullscreen` and visible outer-edge geometry while
   fullscreen. Distinguish app-owned chrome from shell surfaces.
3. Expect zero placements during entry or genuine fullscreen. Each
   frame-style-confirmed exit has at most one saved-tile placement, never
   before the 120 ms fallback while fullscreen geometry remains. An app
   that restores the exact tile itself needs none. The saved tile and
   neighbouring tiles must return exactly, without a second correction.
4. Expect one effective `panel_fullscreen` change per open/close on the
   affected monitor, with no lowering of the other monitor. In steady
   state, transitions must not register/remove/reposition AppBars or alter
   work-area geometry. Also verify exit after starting the shell over an
   already-fullscreen app, since that initial exit had no AppBar callback
   in the supplied trace.
5. Repeat rapid exit/re-entry and minimize/restore, then compare with an
   untraced baseline. Check the coloured border is absent during framed
   fullscreen and restored once on exit, and record whether grey flashes
   remain. Do not call the visual issue resolved from test counts alone.
