# Windows brightness prototype

ERM-504's bounded M2 brightness slice projects the pinned backend's
`Quickshell.Windows.Brightness` route API through a default-off, pure state
object, a thin native wrapper and an upstream-compatible singleton, and loads
one **original** Caelestia brightness surface in a separate native window.
Brightness control is not reimplemented.

## Scope and the original component

The smallest meaningful original brightness surface is the OSD brightness row in
[`modules/osd/Content.qml`](../../modules/osd/Content.qml): a `CustomMouseArea`
whose wheel changes brightness, the original `FilledSlider` with the
`brightness_${round(value * 6) + 1}` icon, and the original slider dimensions,
typography, motion and Material Symbols font. The host stages this content and
places it, centered, in a window of at most 560x620 logical pixels inset 80 from
the chosen screen. Escape closes an interactive run.

`Content.qml` gained two Windows-localized properties, both defaulting to the
upstream Linux behavior:

- `audioControlsEnabled` (default `true`): hides the speaker and microphone
  rows. The bounded host sets it to `false`; it stages the reviewed Windows
  audio facade only because the original content references `Audio`, and that
  facade's native loader stays inactive under the launcher's `0` opt-in. No
  audio device is observed or controlled.
- `brightnessControlsEnabled` (default `true`): disables the wheel handler and
  the slider, and renders the original row at the upstream disabled opacity
  `0.38` when the service refuses the monitor's route. The handle still shows
  the last observed value and the host adds a short plain capability label.

`components/controls/FilledSlider.qml`, `components/effects/Elevation.qml` and
`utils/Icons.qml` are staged as original support components. The shared M1
`services/Colours.qml` adapter gained the upstream `layer()` helper (identity,
because the palette is fixed and opaque) and the `m3inverseSurface`,
`m3inverseOnSurface` and `m3outline` palette values that `FilledSlider` reads.
These are additive; no existing M1 value changed.

The full OSD wrapper, bar scroll action, dashboard/sidebar surfaces, global
shortcuts (`brightnessUp`/`brightnessDown`), the original IPC handler and the
Linux `asdbctl`/`ddcutil`/`brightnessctl` processes are not staged. The bar and
other panels keep their own unavailable adapters.

## Service states and route policy

[`BrightnessService.qml`](../services/brightness/BrightnessService.qml) imports
no Quickshell or native module, creates no timers and never queries on its own.
The singleton wrapper [`Brightness.qml`](../services/brightness/Brightness.qml)
preserves the original contract for staged consumers: `monitors` (one typed
`Monitor` per `Quickshell.screens` entry), `getMonitorForScreen()`,
`getMonitor()` (model/serial/name; `id:` and a focused `active` monitor cannot
be derived on Windows), `increaseBrightness()`/`decreaseBrightness()`,
`ddcMonitors`/`ddcMonitorMap` (empty) and `appleDisplayPresent` (false). Each
`Monitor` exposes `brightness`, `setBrightness()`, `increase()`/`decrease()`,
`refreshRoute()`, `route`, `routeLabel`, `capability`, `stateLabel`,
`stateReason`, `writable`, `latched` and `lastOutcome`.

Per-monitor capability states:

| state | meaning |
| --- | --- |
| `unknown` | route not checked; never written |
| `querying` | a route query is in flight; never written |
| `hardware` | a named hardware route (`wmi`, `lcd` or `ddc`) reported a level |
| `software-only` | the backend only offers gamma dimming |
| `unsupported` | the backend reported no route |
| `failed` | a hardware route exists but its level read failed (denied/failed) |

Policy, enforced in the pure state object:

1. **No native write without the strict-route backend.** The adapter
   feature-detects `typeof backend.strictRoutes === "boolean"` and the
   `brightnessWriteResult` signal on the injected backend. The shared build is
   still at the old pin, which has neither: there `Interactive` is refused with
   "Brightness writes need the strict-route backend" and the slider is
   read-only. This is deliberate — the legacy `setBrightness()` path retries
   `\\.\LCD`, falls back to software gamma and then reports `ok = true`.
2. With the strict API present, `strictRoutes = true` is set before the first
   write (one-way) and `brightnessWriteResult(screen, value, ok, method, error)`
   is the only completion. The legacy `brightnessSetFinished(bool)` is inert: at
   the old pin every terminal path reported true, so it can never confirm a
   write. A result that is not `ok` or reports a different route is a failure.
3. A software-only monitor is written only when the separate gamma opt-in is
   enabled. Turning that opt-in off calls `clearSoftwareDimming(screen)` for
   every screen when the backend exposes it.
4. `unknown`, `querying`, `failed` and `unsupported` monitors are never written.
   Route queries are explicit user actions and never run automatically after a
   gamma touch.
5. Non-finite values are refused; finite values are clamped to `0..1`, matching
   upstream `Monitor.setBrightness`.
6. `interactive` (slider accepts input: writes permitted and route known) is
   separate from `writeReady`/`canWrite` (no write in flight). While a write is
   pending, later values coalesce to the newest drag target and are sent after
   the terminal result. A failure drops the queue and snaps the slider back to
   the last confirmed value; a pending write never disables the slider
   mid-gesture.

A strict-route enable refusal is latched as a separate `policyError`, not as a
per-monitor route latch, and an explicit route refresh clears it. Each screen
record also carries a generation: a query result is accepted only while a query
is outstanding for the current generation, so a late result for an unplugged
screen cannot authorize the reconnected monitor.

`brightnessWriteResult` is the only strict confirmation. Success means the
backend accepted the write through the stored route, not that a read-back
confirmed the requested level. WMI and `\\.\LCD` may later emit
`systemBrightnessChanged`; DDC/CI has no read-back.

## Opt-ins and startup policy

All opt-ins are child-process environment variables; the launcher sets them
explicitly so inherited flags cannot enable brightness in another profile.

- `CAELESTIA_WINDOWS_BRIGHTNESS=1` observes routes through read-only queries. It
  constructs the native `Brightness` singleton only after this opt-in.
- `CAELESTIA_WINDOWS_BRIGHTNESS_CONTROLS=1` additionally permits explicit
  hardware writes. It is only set by a non-smoke `Interactive` run.
- `CAELESTIA_WINDOWS_BRIGHTNESS_SOFTWARE=1` additionally permits gamma writes.
  The launcher forwards it only when the user explicitly sets it in the parent
  process and also requests a non-smoke `Interactive` run. Every `-Smoke` run
  forces controls and software gamma off.

The host calls `Brightness.beginObservation()` once at startup. That performs
one `query()` per screen, never `probe()`, and only while this process has
applied no software dimming. A later automatic response is impossible: any
software write sets `gammaTouched` and blocks automatic re-query. The non-smoke
refresh button calls `refreshRoutes()` explicitly.

### Querying and teardown side effects

`query()` and `probe()` share `startProbe()`. In a read-only process neither
writes at startup, because no gamma dimming exists yet: the only gamma write on
that path is guarded by `GammaController::dims()` and only drops dimming this
process applied earlier (`windows/deps/quickshell/src/windows/system/brightness.cpp`,
lines 1209-1221). `probe()` is not a write-free alternative — it runs the same
gamma handling and only skips the DDC/CI read. Automatic observation therefore
uses `query()` once so the UI has a level, never probes, and refuses automatic
re-queries after a gamma write. A user-initiated refresh can drop software
dimming and is documented as such.

The native singleton's destructor waits for the worker pool
(`brightness.cpp:1147-1155`); the host exits after the capture, no brightness
worker or prototype process remains, and the harness checks that. The service
never calls `refresh()` (a WMI/LCD read-back) and never calls `probe()`.

## Strict-route gate and the old pin

At backend `14010429` (the shared gitlink) a hardware write failure
automatically retries another route and then software gamma, then emits success:

- `windows/deps/quickshell/src/windows/system/brightness.cpp:1386-1393` retries
  `\\.\LCD` after a WMI failure and emits a `routeChanged`.
- `brightness.cpp:1395-1400` falls back to `useSoftware()` and emits
  `brightnessSetFinished(screenName, true)`.
- `brightness.cpp:1403-1413` applies the gamma ramp itself.
- `brightness.cpp:1343-1401` never emits `ok = false` on any terminal path.
- `brightness.cpp:1260-1266` forces the DDC route when a write arrives before a
  route was resolved.

The adapter therefore refuses every native write on this build. It does not
reach `setBrightness()` at all: `strictBackend` is false because the old-pin
singleton has no `strictRoutes` and no `brightnessWriteResult`, so `Interactive`
is reported as unsupported and the slider is read-only.

The backend fork now has an accepted strict-route API (branch
`windows/m2-brightness-strict-route`, commit `63eee61`): a one-way `strictRoutes`
property that can only be enabled while idle, exactly one
`brightnessWriteResult(screen, value, ok, method, error)` per strict write
request, and `clearSoftwareDimming(screen)`. In strict mode the backend uses the
stored route only: no unresolved/overlapping write, no `\\.\LCD` retry and no
gamma fallback, and a rejection is a real failure result. The wrapper forwards
those members when the native singleton has them; the adapter enables strict
routes before the first write and uses the result as the only completion.

Adopting the fork requires its own backend PR, gitlink and `sources.lock.json`
revision. This slice changes no backend source and makes no live hardware-write
claim.

## Validation

```powershell
$qtPrefix = "$env:LOCALAPPDATA\caelestia-dev\Qt\6.11.2\msvc2022_64"
powershell -NoProfile -File windows/scripts/Test-BrightnessService.ps1 `
    -QtPrefix $qtPrefix
powershell -NoProfile -File windows/scripts/Test-BrightnessPrototype.ps1 `
    -QtPrefix $qtPrefix
```

`Test-BrightnessService.ps1` stages only the state object and fixture into Qt's
offscreen `qml.exe`. It rejects native imports, staging hash mismatches and QML
diagnostics. The 304 injected assertions cover every capability state, WMI/LCD/
DDC route names and labels, the strict-capable and old-pin backend shapes,
one-way `strictRoutes`, terminal-only write completion, coalesced pending
writes, failure snap-back and queue drop, per-screen query generations, the
latched strict policy failure, `clearSoftwareDimming`, the gamma opt-in refusal,
non-finite and out-of-range values, hot unplug/re-plug and mid-write removal,
controls-off refusal, read-only system read-back, malformed backend shapes, the
one-shot automatic observation and the explicit refresh.

`Test-BrightnessPrototype.ps1` runs the fixture, then disabled/read-only smoke on
every measured connected screen, then the original M1 bar/session regression. It
also compares each display's `GetDeviceGammaRamp` hash before and after the whole
harness as a net-state check; `GammaController` restores ramps on `aboutToQuit`,
so a matching hash does not prove that no write occurred. Smoke never sends input
and never writes brightness.

Raw results are under `windows/.local/build/brightness-validation-<timestamp>/`.

## Limits

- No live hardware write, DDC denial, gamma write or recovery was performed.
  The strict-route native branch is unvalidated here: the shared gitlink predates
  it, `Interactive` is refused on this build, and the fixture proves only the
  policy over injected backend shapes.
- The strict-route wrapper's forwarding path (`strictSupported`,
  `brightnessWriteResult`, `clearSoftwareDimming`) cannot run until the gitlink
  and `sources.lock.json` move; this slice changes neither.
- A strict success means the backend accepted the write through the stored
  route, not that a read-back confirmed the level. Real DDC/CI failure text is
  still not exposed by `queried()`; `failed` states name the route and say that
  no readable level was reported, without a Win32 code.
- `getMonitor("active")` has a defined value only when one monitor is connected
  or a host assigns `activeScreen`; Windows has no Hyprland focused-monitor
  identity. `getMonitor("id:...")` returns null.
- No bar scroll action, dashboard/sidebar brightness control, global shortcut,
  IPC mutation, toast or Linux process is staged. `FilledSlider`'s original
  disabled visuals are only used through the localized `enabled` binding; the
  OSD's own popout wrapper is not part of this host.
- The staged audio facade is disabled and never observed; it exists only so the
  original OSD content compiles and its read-only bindings can be evaluated.
- No backend source, gitlink or `sources.lock.json` change is part of this slice.
