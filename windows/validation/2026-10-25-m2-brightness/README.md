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
| Native gamma ramps | Identical SHA-256 before and after the whole harness on both displays | [before](gamma-before.json), [after](gamma-after.json) |
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
  it. That gap and the proposed strict-route fork flag are recorded in
  [M2-SERVICES.md](../audits/M2-SERVICES.md) candidate 7 and in the
  [prototype README](../../brightness-prototype/README.md). A backend change
  requires its own PR, gitlink and `sources.lock.json` revision.
- DDC failure text is not exposed by `queried()`, so `failed` states name the
  route without a Win32/HRESULT code.
- The M1 smoke is a regression check, not renewed input/transparency
  acceptance. No Linux build or remote CI pass is claimed; inherited root
  Actions remain disabled.
