# M2 brightness route policy, 2026-10-25

This archive records the bounded brightness slice for ERM-504 on branch
`t3/m2-brightness-route-policy`. It separates fixture-only route policy from
native read-only observation and makes no live hardware-write claim. ERM-504 and
M2 remain **In Progress** for interactive writes, denial/recovery and the
backend strict-route gap.

## Sources and runtime

- Clean root `c6117d0aaa0365e848faefb72a0c9dcd988b4ad3`.
- Backend `1401042969e4b7ab3cfb314fc76945ab081db3de`; gitlink and
  `windows/sources.lock.json` are unchanged by this slice.
- Windows 11 `10.0.26300.0`, Qt 6.11.2, clang-cl 20.1.8, MSVC tools
  14.44.35207, Windows SDK 10.0.26100.0, CMake 4.4.4 and Ninja 1.13.2. The
  shared native build record is unchanged from the media slice; this slice
  changes only QML, fixtures and PowerShell, so `qs.exe` was not rebuilt.
- Primary `\\.\DISPLAY1` at native 150%, 3840x2160 at 0,0; secondary
  `\\.\DISPLAY2` at native 175%, 3840x2160 at -3840,0.
- Every run below reports `sourceDirty=false` at the root revision above.

## Delivered scope

`windows/services/brightness/BrightnessService.qml` is a pure QtObject with no
Quickshell/native imports, timers or startup queries. It models six capability
states (`unknown`, `querying`, `hardware` with the route named, `software-only`,
`unsupported`, `denied/failed`) and enforces the route policy: hardware routes
only, a route change or gamma fallback during a write is a latched failure, a
software gamma write needs the separate opt-in, and unknown/failed/unsupported
routes are never written. `Brightness.qml` preserves the original singleton
contract (typed per-screen `Monitor`, `getMonitorForScreen`, `getMonitor`,
`increaseBrightness`/`decreaseBrightness`), and `NativeBrightnessBackend.qml`
wraps `Quickshell.Windows.Brightness` only after the observation opt-in.

The bounded host stages the original OSD brightness row from
`modules/osd/Content.qml` with its original `FilledSlider`, icon formula,
dimensions and typography. The content gained `audioControlsEnabled` and
`brightnessControlsEnabled` hooks, both defaulting to the upstream Linux
behavior. The staged audio facade is always disabled; no audio device is
observed. The M1 `Colours.qml` adapter gained the upstream `layer()` helper
(identity for the fixed opaque palette) and the inverse-surface/outline colours
`FilledSlider` reads.

## Results

| Check | Observed result | Evidence |
| --- | --- | --- |
| Offscreen brightness policy | 255 assertions, no diagnostics, no native imports | [fixture](fixture/result.json), [staged fixture](fixture/BrightnessServiceTest.qml), [log](fixture/brightness-fixture-20261025-181700-084.stdout.log) |
| Disabled at 150% (screen 0) | Pass; no native facade, no OSD component, no route query or probe, both monitors `unknown` | [result](brightness-disabled-screen0/result.json), [capture](brightness-disabled-screen0/brightness-20261025-181700-377.png) |
| Read-only at 150% (screen 0) | Pass; both monitors hardware `ddc`, original OSD loaded with the slider disabled, no writes | [result](brightness-readonly-screen0/result.json), [capture](brightness-readonly-screen0/brightness-20261025-181704-229.png) |
| Disabled at 175% negative origin (screen 1) | Pass; no native facade or OSD component | [result](brightness-disabled-screen1/result.json), [capture](brightness-disabled-screen1/brightness-20261025-181708-047.png) |
| Read-only at 175% negative origin (screen 1) | Pass; both monitors hardware `ddc`, no writes | [result](brightness-readonly-screen1/result.json), [capture](brightness-readonly-screen1/brightness-20261025-181711-839.png) |
| Original M1 bar/session regression | Pass | [result](m1-regression/result.json) |
| Media service regression | 148 assertions, pass | [log](commands/final-media-service.json) |
| Battery service regression | 128 assertions, pass | [log](commands/final-battery-service.json) |
| Native gamma ramps | Net-state check only: identical SHA-256 before and after the whole harness on both displays; `GammaController` restores ramps on `aboutToQuit`, so this does not prove that no write occurred | [before](gamma-before.json), [after](gamma-after.json) |
| Desktop state | Explorer PID 9252, KSG Shell PID 24108, work rectangles and taskbar flags unchanged; no brightness prototype process remained | [before](desktop-before.json), [after](desktop-after.json) |

Observed read-only routes from the native query:

| Screen | Panel kind | Route | Read level |
| --- | --- | --- | --- |
| MAG321UX OLED (`\\.\DISPLAY1`) | external, DisplayPort | `ddc` (DDC/CI answers) | 100% |
| DELL S2725QS (`\\.\DISPLAY2`) | external, DisplayPort | `ddc` (DDC/CI answers) | 100% |

The machine has no battery, so WMI was not asked for the external outputs
(`brightness.cpp:853-858`). The native query log is in each read-only run's
`*.stdout.log` (`quickshell.windows.brightness` INFO lines). The adapter's own
`CAELESTIA_BRIGHTNESS_ROUTES` line in each read-only result is the archived
route summary.

## What the fixture actually covers

- Safe disabled construction and the absence of any native object, query or
  write while disabled.
- Every capability state, including WMI, `\\.\LCD`, DDC/CI, software-only,
  unsupported and a hardware route whose level read failed.
- Route change after a write through both the `routeChanged` signal and a
  `methodFor()` mismatch at completion, including a WMI -> LCD hardware
  alternative; each latches the monitor and refuses further writes until a
  route refresh.
- Gamma writes refused without `CAELESTIA_WINDOWS_BRIGHTNESS_SOFTWARE=1`;
  enabled only with it.
- Non-finite, string, null and object values refused; out-of-range numbers
  clamped to `0..1`.
- Pending writes not queued, duplicate/foreign completion ignored, and route
  refresh refused while a write is pending.
- Hot unplug, re-plug without stale state, mid-write removal and late signals
  for absent screens.
- One-shot automatic observation, its refusal after any gamma touch, and the
  explicit refresh path.
- Malformed but QObject-shaped backends without invented state.

## Commands

Native PowerShell from the repository root:

```powershell
$qtPrefix = "$env:LOCALAPPDATA\caelestia-dev\Qt\6.11.2\msvc2022_64"
$buildRoot = 'D:\AiStack\caelestia-windows\windows\.local\build'
powershell -NoProfile -File windows/scripts/Test-BrightnessService.ps1 `
    -QtPrefix $qtPrefix -BuildRoot $buildRoot
powershell -NoProfile -File windows/scripts/Test-BrightnessPrototype.ps1 `
    -QtPrefix $qtPrefix -BuildRoot $buildRoot
powershell -NoProfile -File windows/scripts/Test-MediaService.ps1 `
    -QtPrefix $qtPrefix -BuildRoot $buildRoot
powershell -NoProfile -File windows/scripts/Test-BatteryService.ps1 `
    -QtPrefix $qtPrefix -BuildRoot $buildRoot
```

`Test-BrightnessPrototype.ps1` runs the fixture, disabled/read-only smoke on
every measured screen, and the M1 smoke, then compares desktop state, gamma
ramps and for leaked prototype processes. The raw command logs are under
[commands](commands). The archived matrix keeps the original absolute build
paths; [archive.ps1](archive.ps1) records the copy procedure and
[artifacts.sha256.json](artifacts.sha256.json) identifies all 39 archived
artifacts.

## Remaining acceptance

- No live brightness or gamma write, real DDC denial, hardware fallback or
  recovery was performed. `Interactive` is implemented and gated but
  unvalidated; the fixture proves only the policy over injected backend shapes.
- The adapter cannot prevent the pinned backend from attempting its internal
  LCD/gamma fallback or from reporting `brightnessSetFinished(..., true)` after
  it. That gap and the accepted strict-route fork API are recorded in
  [M2-SERVICES.md](../../audits/M2-SERVICES.md) candidate 7 and in the
  [prototype README](../../brightness-prototype/README.md). A backend change
  requires its own PR, gitlink and `sources.lock.json` revision.
- DDC failure text is not exposed by `queried()`, so `failed` states name the
  route without a Win32/HRESULT code.
- The M1 smoke is a regression check, not renewed input/transparency
  acceptance. No Linux build or remote CI pass is claimed; inherited root
  Actions remain disabled.

## Review addendum, strict-route adapter v2

This addendum records the review fixes on branch
`t3/m2-brightness-adapter-v2` (the route-policy branch merged with
`windows/m2-services-integration` at `cf53844d`; code changes in `cfb770e5`).
The final runs below were made on a clean tree at `9ed3cdb3`, and every harness
result reports `sourceDirty=false`. The merge added the brightness slice to the
integration launcher's slice table and removed a duplicated `Colours.layer()`
left by the automatic merge.

Reviewed behavior that changed:

1. Native writes now require the strict-route backend, feature-detected at
   runtime from `typeof backend.strictRoutes === "boolean"` **and** the
   `brightnessWriteResult` signal. The shared gitlink is still at the old pin,
   so on this build `Interactive` is refused with "Brightness writes need the
   strict-route backend" and the slider stays read-only. With the strict API
   present, strict routes are enabled before the first write and the one-shot
   `brightnessWriteResult` is the only write confirmation.
2. A pending write is cleared only by the terminal strict result for that
   screen. The legacy `brightnessSetFinished(bool)` is inert: at the old pin it
   is true after an internal gamma fallback, so it can never confirm a write.
   A strict-route enable refusal is latched as a separate `policyError`, not as
   a per-monitor route latch, and an explicit refresh clears it.
3. Each screen record carries a generation. A query result is accepted only
   while a query is outstanding for the current generation; removing and
   re-adding a screen bumps the generation and a late result for the old record
   is dropped instead of authorizing the reconnected monitor.
4. `interactive` (slider accepts input: writes permitted and route known) is
   separate from `writeReady`/`canWrite` (no write in flight). While a write is
   pending the newest drag target is coalesced and sent after the terminal
   result; a failure drops the queue and snaps the slider back to the last
   confirmed value. A pending write no longer disables the slider mid-gesture.
5. Gamma-ramp hashes are described as a net-state check only.
6. The audit link now resolves to `../../audits/M2-SERVICES.md`.

Commands (native PowerShell from the repository root):

```powershell
$qtPrefix = "$env:LOCALAPPDATA\caelestia-dev\Qt\6.11.2\msvc2022_64"
$buildRoot = 'D:\AiStack\caelestia-windows\windows\.local\build'
powershell -NoProfile -File windows/scripts/Test-BrightnessService.ps1 `
    -QtPrefix $qtPrefix -BuildRoot $buildRoot
powershell -NoProfile -File windows/scripts/Test-BrightnessPrototype.ps1 `
    -QtPrefix $qtPrefix -BuildRoot $buildRoot
powershell -NoProfile -File windows/scripts/Test-NetworkPrototype.ps1 `
    -QtPrefix $qtPrefix -BuildRoot $buildRoot
```

| Check | Observed result |
| --- | --- |
| Offscreen strict-route fixture | Pass; **304 assertions**; no native imports, staging hash mismatch or QML diagnostic. Covers the strict-capable fake, the old-pin fake without strict members, one-way `strictRoutes`, coalescing, terminal-only completion, snap-back, generation, policy latch, `clearSoftwareDimming` and all prior route states |
| Brightness prototype harness | Pass; 6 runs (fixture, `Disabled`/`ReadOnly` on each of the two measured screens, M1 regression); `runs=6`, `output=brightness-validation-20261025-195607-204` |
| Network prototype regression | Pass; 6 runs; `output=network-validation-20261025-195632-216`; confirms the `Start-ShellPrototype.ps1`/`Stage-ShellPrototype.ps1` slice-table merge did not regress another slice |

The fixture is the only new evidence for strict-route behavior. It injects
both backend shapes; no native strict build exists in the shared tree.

### Untested in this addendum

- Every native write path: no `Interactive` run was made and no real monitor
  brightness or gamma ramp was written. `Disabled` and `ReadOnly` are the only
  native smoke modes exercised.
- The strict-route native QML wrapper (`strictSupported`, forwarding
  `brightnessWriteResult`, `clearSoftwareDimming`) against the fork branch
  `windows/m2-brightness-strict-route` at `63eee61`. The shared build is at the
  old pin, so the wrapper's strict branch is feature-detected off here. It
  cannot be exercised until the gitlink and `sources.lock.json` move, which
  this slice deliberately does not do.
- Real DDC/CI denial, overlapping-write rejection, route changes during a
  strict write, and recovery after a strict failure on hardware.
- The caveat that a strict success means the backend accepted the write through
  the stored route, not that a read-back confirmed the level.

## Review addendum (pinned backend)

This addendum records the second review's fixes on branch
`t3/m2-brightness-adapter-v3` (based on `windows/m2-services-integration` at
`187d3f4f`; code changes in `7a2df8f1`). The backend gitlink was already at
`525786f`, which carries the strict brightness API, so the fake could finally
be written against the real completion semantics read from
`windows/deps/quickshell/src/windows/system/brightness.cpp`. The final runs
below were made on a clean tree at `7a2df8f1` and report `sourceDirty=false`
against backend `525786f`.

Reviewed behavior that changed:

1. **Stale queries no longer authorize a reconnected monitor.** Query
   completions are matched to the request they answer through a per-screen
   FIFO of globally unique request tokens (`_queryRequests`), kept across
   record replacement. A completion consumes the oldest outstanding token and
   is accepted only when it answers the token the current record issued; the
   pinned backend answers one screen's queries in request order on a single
   worker thread, so the oldest request is the one a completion answers. A
   completion for a pre-reconnect request is consumed and discarded. The
   fixture drives the review's exact ordering (query A, reconnect, query B,
   deliver A's completion) plus a double reconnect and an
   A,B-delivered-in-order pass.
2. **Queued writes can no longer bypass revoked controls.** Every queued
   dispatch goes through `write()`'s authorization of the current state, and
   the queue is dropped the moment authorization changes: the controls opt-in
   revoked or a strict-route policy failure latched drop it immediately
   (disabling the service resets the records and removing the screen drops
   the record with its queue). The fixture covers the review's case — queue
   a target, clear `controlsEnabled`, complete the first write OK, zero
   further backend calls — plus the policy-latch and disable drops.
3. **A denied write snaps the displayed slider back.** A terminal failure
   bumps a monotonic `resyncSerial` on the record (also when a queued drag
   target is dropped). The OSD content gained a `brightnessResyncSerial`
   hook that restores the slider's `value` binding when the serial changes;
   it defaults to `0` and never fires on Linux, so the upstream
   `modules/osd/Content.qml` behavior is unchanged. The facade exposes the
   serial per monitor and the brightness prototype passes it through; its
   smoke now asserts the hook is bound to the service serial.
4. **The fake models the pinned backend.** Queued query completion in request
   order (`routeChanged` then `queried`, `isDdc` true only for ddc and
   software), queued hardware completion with per-screen in-flight state
   finalized before `brightnessSetFinished` and exactly one
   `brightnessWriteResult`, direct synchronous rejection of unresolved-route
   and overlapping writes with the native error text, direct software-route
   completion, idle-only one-way `strictRoutes` (refused while a write is
   active, disable attempts counted and refused), and `clearSoftwareDimming`
   that emits nothing. The fixture checks the model directly, including the
   native argument order and strings.

Assertions that were updated because they depended on the old fake's
synchronous write completion: the strict-write, clamp, coalescing, failure and
blocked-fixture sequences now assert `pending`/`writePending` after `write()`
and settle through an explicit `completeWrite()`; the `emitResult`,
`emitFinish` and `respondToQuery` knobs are gone (a withheld completion is an
undelivered queued one); the old `queryGeneration` field comparison was
replaced by the token-ordering scenarios above; the mid-write unplug test now
also carries a queued target. The old-pin `OldBackend` still answers
synchronously — only feature detection and write refusal are asserted against
it, and neither depends on completion timing.

The displayed-value test for item 3 runs offscreen: a `DisplayProbe` in the
fixture carries the same value binding and resync-serial hook as the staged
OSD slider (an imperative drag assignment breaks the binding; the serial
restores it), asserted through the failure, wrong-route, controls-revocation
and policy-latch sequences. The native prototype smoke verifies the
host-to-hook serial plumbing read-only (`osdResyncSerial` equals the selected
monitor's serial); the FilledSlider rebind after a real denied write needs an
`Interactive` run and remains untested.

Commands (native PowerShell from the repository root):

```powershell
$qtPrefix = "$env:LOCALAPPDATA\caelestia-dev\Qt\6.11.2\msvc2022_64"
$buildRoot = 'D:\AiStack\caelestia-windows\windows\.local\build'
powershell -NoProfile -File windows/scripts/Test-BrightnessService.ps1 `
    -QtPrefix $qtPrefix -BuildRoot $buildRoot
powershell -NoProfile -File windows/scripts/Test-BrightnessPrototype.ps1 `
    -QtPrefix $qtPrefix -BuildRoot $buildRoot
```

| Check | Observed result |
| --- | --- |
| Offscreen strict-route fixture | Pass; **394 assertions**; no native imports, staging hash mismatch or QML diagnostic; `brightness-fixture-20261025-221440-912` |
| Brightness prototype harness | Pass; 6 runs (fixture, `Disabled`/`ReadOnly` on each of the two measured screens, M1 regression); desktop identity, gamma ramp hashes and the leaked-process check all clean; `brightness-validation-20261025-221440-634` |

No shared script under `windows/scripts/` changed, so
`Test-NetworkPrototype.ps1` was not re-run; the M1 regression above covers the
staged shell closure that includes the `Content.qml` hook.

### Untested in this addendum

- Every native write path: `Disabled` and `ReadOnly` remain the only native
  smoke modes; no real monitor brightness or gamma ramp was written, so the
  native `brightnessWriteResult` paths, real DDC/CI denial, overlap rejection
  and recovery are still fixture-only claims.
- The native OSD `FilledSlider` rebind after a real denied write (needs
  `Interactive`); the offscreen probe and the read-only host plumbing are the
  evidence for the hook.
- The fake's legacy (non-strict) path is a minimal occupancy model without the
  old pin's fallback chains; it exists only for the direct model checks, and
  the adapter is asserted never to reach it (`legacySetCalls === 0` on every
  fake).
- `systemBrightnessChanged` (read-back and WMI events) is still not modeled;
  no adapter behavior depends on its timing.

## Review addendum 2 (request IDs)

This addendum records the third review's fixes on branch
`t3/m2-brightness-adapter-v3` (code changes in `b483660d`, on top of
`7a2df8f1`). The per-screen FIFO of query tokens is gone: a parallel backend
change adds request ids, and the adapter is now written against that API —

- `int queryRequest(string screenName)` returns a process-unique, strictly
  increasing positive id immediately;
- `signal queryFinished(int requestId, string screenName, bool available,
  bool isDdc, real brightness)` fires exactly once per `queryRequest()` call,
  for every outcome, on the GUI thread; plain `query()`/`queried()` are
  unchanged and never carry ids.

The final runs below were made on a clean tree at `b483660d` and report
`sourceDirty=false` against backend `525786f` (gitlink and
`windows/sources.lock.json` unchanged; the pinned backend still has no ids).

Reviewed behavior that changed:

1. **A stale completion can never authorize (finding 1).** Each record stores
   the id it issued, and a `queryFinished` is accepted only when its id equals
   the current record's outstanding id; everything else is discarded.
   Disable, re-enable and reconnect need no token bookkeeping because an
   issued id never repeats. A backend swap additionally ends the records'
   outstanding queries, so a completion for a pre-swap request — forwarded by
   the new wrapper, which wraps the same process-wide native singleton —
   finds no waiting record and cannot match a later request's id.
2. **Out-of-order completion is safe (finding 2).** Acceptance no longer
   assumes any delivery order: the newer request's completion is accepted on
   its own id even when the backend's startup gate lets it dispatch before an
   older deferred request, and the older completion is then discarded.
3. **Every refused or failed write snaps the display back (finding 3).**
   `_refuse` bumps the resync serial exactly like a terminal failure, so the
   strict-enable refusal (confirmed 0.4, dragged 0.9, serial 0 to 1) and the
   direct rejection paths — a synchronous dispatch throw and a directly
   failing software write — all restore the confirmed displayed value.
4. **The fake models the id API (finding 4) and emits exactly one
   `strictRoutesChanged` per enable** (the property's own change signal; the
   duplicate explicit emit is gone). `queryRequest` returns synchronous ids
   from a test-wide counter, completions stay queued until delivered and may
   be delivered out of request order (`deliverQuery(id)` picks a specific
   request), and every completion also fires the plain `queried` signal.

The id API is feature-detected in `NativeBrightnessBackend.qml`
(`typeof Brightness.queryRequest === "function"`; the wrapper exposes
`queryRequest` as a callable or `undefined` and forwards `queryFinished`).
Without ids — the pinned `525786f` build — route queries still update
read-only display state through plain `queried`, but `writesAllowed` stays
false, the slider stays read-only, the reason and the write refusal state
that the backend cannot match query results, and there is no heuristic
fallback. When ids are supported the plain `queried` signal is ignored, so a
result is never processed twice. The prototype host now reports `queryIds`
in its state; the read-only smokes below show `strictBackend: true,
queryIds: false, writesAllowed: false` on this build, so the closed controls
gate is demonstrated truthfully rather than by the old-pin strict gap.

Fixture scenarios added or reworked (each deterministic): the review's exact
finding-1 sequence (query A at 0.2, disable, re-enable, query B at 0.8,
deliver A — the record keeps waiting and only B's 0.8 is recorded); the
review's finding-2 ordering (deferred A2 completes after B2; B2 is accepted
first, A2 discarded); reconnect with in-order delivery and an unissued id
plus the plain `queried` signal ignored mid-query; disable/re-enable with
stale delivery; wrapper replacement with the stale id forwarded by the new
wrapper and the detached wrapper's own delivery; the no-id backend staying
read-only (display settles, controls refused, nothing reaches the backend);
the strict-enable refusal snapping the dragged display back; exactly one
`strictRoutesChanged` per enable and none for refusals; and the two direct
rejection paths snapping back. Assertions that changed meaning: a refused
write now bumps the resync serial and rebinds the display (the old fixture
asserted it did not), the first successful write's serial check became a
delta (earlier refusals now legitimately bump it), and the `queryToken`
field checks became `queryId` identity checks on the accepted request.

Commands (native PowerShell from the repository root):

```powershell
$qtPrefix = "$env:LOCALAPPDATA\caelestia-dev\Qt\6.11.2\msvc2022_64"
$buildRoot = 'D:\AiStack\caelestia-windows\windows\.local\build'
powershell -NoProfile -File windows/scripts/Test-BrightnessService.ps1 `
    -QtPrefix $qtPrefix -BuildRoot $buildRoot
powershell -NoProfile -File windows/scripts/Test-BrightnessPrototype.ps1 `
    -QtPrefix $qtPrefix -BuildRoot $buildRoot
```

| Check | Observed result |
| --- | --- |
| Offscreen request-id fixture | Pass; **466 assertions**; no native imports, staging hash mismatch or QML diagnostic; `brightness-fixture-20261025-230208-443` at `b483660d`, `sourceDirty=false` |
| Brightness prototype harness | Pass; 6 runs (fixture, `Disabled`/`ReadOnly` on each of the two measured screens, M1 regression); desktop identity, gamma ramp hashes and the leaked-process check all clean; read-only runs show `queryIds=false` with the controls gate closed; `brightness-validation-20261025-230208-156` |

No shared script under `windows/scripts/` changed, so
`Test-NetworkPrototype.ps1` was not re-run.

### Untested in this addendum

- Every native write path and the native `queryRequest`/`queryFinished`
  delivery itself: `Disabled` and `ReadOnly` remain the only native smoke
  modes (safety gate), and the pinned `525786f` backend has no ids. The id
  path, real DDC/CI denial, overlap rejection and recovery are fixture-only
  claims until the backend gitlink moves.
- The native OSD `FilledSlider` rebind after a real denied write (needs an
  `Interactive` run); the offscreen `DisplayProbe` and the read-only
  host-to-hook plumbing remain the evidence for the hook.
- `systemBrightnessChanged` (read-back and WMI events) is still not modeled;
  no adapter behavior depends on its timing.

## Review addendum 3 (route changes and 64-bit ids)

The review of `5c7e1548` blocked it on two findings. The orchestrator fixed both
in the follow-up commit:

1. **P1: a stale completion's route change.** The backend emits `routeChanged`
   before `queryFinished`. A request issued before a disable/re-enable could
   finish after the current record was authorized; its id was rejected, but its
   route change still moved the record to an unconfirmed route that remained
   writable. With ids, a route change outside an accepted query now withdraws
   write authorization by querying again. The latch is kept, because this isn't
   a route refresh the user asked for.
2. **P2: 64-bit ids narrowed to 32 bits.** The backend id is a `qint64`. The
   record's `queryId`, the wrapper's and fake's `queryFinished` parameter, and
   the fake's id allocator are now `real`, so ids past `INT_MAX` keep their
   exact value.

Rerun with the same commands: `Test-BrightnessService.ps1` passed with 480
assertions, including the review's route sequence and a 64-bit id check, and
`Test-BrightnessPrototype.ps1` passed. Only Disabled and ReadOnly native runs
were made, and nothing was written.

## Review addendum 4 (closing)

The re-check of `2ea5dd4e` found two low-likelihood issues, which the orchestrator fixed
without another review round:

- An uncorrelated route change during a pending write now drops the queued
  target and re-queries once the write settles.
- The fake id counter is now `real`, and a query past `INT_MAX` is exercised
  end to end.

`Test-BrightnessService.ps1` passed with 484 assertions, and
`Test-BrightnessPrototype.ps1` passed. Review stops here by decision: day-to-day
behavior is next verified live on the desktop, not with more offscreen edge cases.
No real brightness has been written yet.
