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

1. A hardware monitor is written only through its detected route. The adapter
   records the route before the write. If `routeChanged` fires during the write
   or `methodFor()` reports a different route when the write finishes, the
   monitor is latched with `lastOutcome = "route-changed"`, its brightness
   becomes unknown and the host labels the write a failure, not a success. No
   further write is sent until an explicit route refresh (a user action) clears
   the latch.
2. A `wmi` -> `lcd` retry is a hardware alternative, but it is still a route
   change and is still reported as a failure for the requested route.
3. A software-only monitor is written only when the separate gamma opt-in is
   enabled. Otherwise the write is refused before reaching the backend.
4. `unknown`, `querying`, `failed` and `unsupported` monitors are never written.
   This also prevents the backend's unresolved-route behaviour of forcing DDC.
5. Non-finite values are refused; finite values are clamped to `0..1`, matching
   upstream `Monitor.setBrightness`.
6. A pending write is not queued: a second write is refused until the first
   finishes. Duplicate or foreign completion signals are ignored.

`brightnessSetFinished(screenName, ok)` cannot prove success. At this pin every
terminal write path emits `ok = true`, including the internal software-gamma
fallback, so the adapter treats the route as the only failure evidence and
records a forwarded hardware write as `hardware-requested`, never as confirmed.
WMI and `\\.\LCD` may later emit `systemBrightnessChanged` as a read-back; DDC/CI
has no read-back at this pin.

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
software write or detected fallback sets `gammaTouched` and blocks automatic
re-query. The non-smoke refresh button calls `refreshRoutes()` explicitly.

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

## Backend gap: the adapter cannot prevent the internal fallback

At backend `14010429` a hardware write failure automatically retries another
route and then software gamma, then emits success:

- `windows/deps/quickshell/src/windows/system/brightness.cpp:1386-1393` retries
  `\\.\LCD` after a WMI failure and emits a `routeChanged`.
- `brightness.cpp:1395-1400` falls back to `useSoftware()` and emits
  `brightnessSetFinished(screenName, true)`.
- `brightness.cpp:1403-1413` applies the gamma ramp itself.
- `brightness.cpp:1343-1401` never emits `ok = false` on any terminal path.
- `brightness.cpp:1260-1266` forces the DDC route when a write arrives before a
  route was resolved.

The adapter can only detect this after the fact, surface `route-changed`, latch
the monitor and refuse further writes. It cannot stop the backend's own gamma
ramp write. A strict-route backend flag is the proposed fork change: for
example `setBrightnessStrict(screenName, route, value)` (or a `strictRoutes`
property set before construct) that rejects a write when the stored route is
unresolved or differs from the requested route, disables the LCD retry and
gamma fallback for that call, and reports the used route and a real per-write
result. That requires a backend PR, a new gitlink and `sources.lock.json`
revision, and its own validation; this slice changes no backend source and
makes no live hardware-write claim.

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
diagnostics. The 255 injected assertions cover every capability state, WMI/LCD/
DDC route names and labels, route-change-after-write through both the signal and
the method lookup, the gamma opt-in refusal, non-finite and out-of-range values,
hot unplug/re-plug and mid-write removal, controls-off refusal, pending/duplicate
writes, read-only system read-back, malformed backend shapes, the one-shot
automatic observation and the explicit refresh.

`Test-BrightnessPrototype.ps1` runs the fixture, then disabled/read-only smoke on
every measured connected screen, then the original M1 bar/session regression. It
also compares each display's `GetDeviceGammaRamp` hash before and after the whole
harness. Smoke never sends input and never writes brightness.

Raw results are under `windows/.local/build/brightness-validation-<timestamp>/`.

## Limits

- No live hardware write, DDC denial, gamma write or recovery was performed.
  The interactive mode is implemented and gated but unvalidated; the fixture
  proves only the policy over injected backend shapes.
- The adapter cannot prevent the backend's internal fallback attempt (gap
  above). A successful hardware write is recorded as requested, not confirmed.
- Real DDC/CI failure text is not exposed by `queried()`; `failed` states name
  the route and say that no readable level was reported, without a Win32 code.
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
