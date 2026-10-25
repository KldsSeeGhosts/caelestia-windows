# M2 native tray boundary, 2026-10-25

This archive records the bounded read-only tray slice (ERM-506) on branch
`t3/windows-native-tray-boundary`, root `298fd12556a7330e1f8974fd54b871172f7220d1`,
with the backend pin unchanged at
`1401042969e4b7ab3cfb314fc76945ab0813db3de`. It does not enable tray
interception, taskbar changes or real icon activation. The slice remains
read-only: **no real tray item was observed** because the hook is forced off.

## Sources and runtime

- Clean root `298fd125` (`sourceDirty=false` in every recorded run and fixture).
- Clean backend gitlink/manifest `14010429`; not modified by this slice.
- Windows 11 `10.0.26300.0`, Qt 6.11.2, clang-cl 20.1.8, MSVC tools
  14.44.35207, Windows SDK 10.0.26100.0, CMake 4.4.4, Ninja 1.13.2.
- Primary `MAG321UX OLED` 3840x2160 at 150%, secondary `DELL S2725QS`
  3840x2160 at 175% with x=-3840. The 660x600 host rendered at both origins.
- The build was made from this worktree into a separate root,
  `D:\AiStack\caelestia-windows\windows\.local\build-tray`, because the provided
  shared root's CMake cache belongs to a different checkout
  (`CMAKE_HOME_DIRECTORY=D:/AiStack/caelestia-windows`). Reconfiguring it from
  this worktree would have disturbed that shared cache; nothing in the shared
  root was rebuilt or deleted. [Build record](build/build.json),
  [environment](build/environment.json), [commands](build/configure-backend-command.json)
  and configure/build/install logs are included. The backend was rebuilt from
  the same pin, not reused. The required
  [prerequisite report](build/environment-report.json) confirms gitlink and
  manifest alignment; it is not build or runtime evidence.
- Measurement sources: `Get-DesktopState.ps1`
  `44E06C706EE5A930A41EA723D9DFC104469D2019DDBC3BAEA71B240B71A401DE`,
  `Test-TrayService.ps1`
  `A88B2F5FF58A0D4E2AF2A28432066D948D7A1D7C455AD479BBE23D7C869ACA42`,
  `Test-TrayPrototype.ps1`
  `7C0F450241C3F361E3A14ECCB663C2282E3554729370571FF6FBC2771AE6D00F`.

## Delivered scope

`windows/services/tray/TrayService.qml` is a pure QtObject with no Quickshell
import. It separates `disabled`, `initializing`, `empty`, `ready(count)` and
`unavailable`, rejects non-object items, refuses every native request without
the activation opt-in, drops stale requests, exposes `hasMenu=true` with a null
menu handle as "no semantic menu", and treats scroll as an unsupported no-op.
It observes item-list resets as `listGeneration`/`listResets`, not as proof of
an Explorer restart.

`services/Tray.qml` is the default-off facade: `CAELESTIA_WINDOWS_TRAY=1`
constructs `NativeTrayBackend.qml` (a thin `SystemTray.items` reader), and
`CAELESTIA_WINDOWS_TRAY_ACTIVATION=1` separately permits `activate()`,
`secondaryActivate()` and `display()`. Importing the facade with both unset
never resolves the native backend.

The bounded [tray host](../../tray-prototype/README.md) stages the original
`modules/bar/components/Tray.qml`, `TrayItem.qml`,
`modules/bar/popouts/TrayMenu.qml`, `PopoutState.qml` and the original
`components/effects/ColouredIcon.qml`/`Colouriser.qml` chain. Localized hooks
default to upstream Linux behavior: `sourceItems`, `interactionsEnabled`,
`nativeMenuMode`, `semanticMenuAvailable` and the `iconItem` alias. The
unavailable menu notice uses the existing disabled-entry `m3outline` colour.

`Caelestia.Images` is now built in the portable configuration: the analyser is
Qt-only (Quick/Concurrent), and the original `ColouredIcon` imports it. No Linux
service was pulled into the portable set.

### Launcher and safety policy

`Start-ShellPrototype.ps1 -Tray [-TrayMode Disabled|ReadOnly|Interactive]`
adds the opt-ins; `-TrayFixture` additionally requires
`-Tray -TrayMode Disabled -Smoke`. Every prototype run now forces
`QS_WINDOWS_TRAY_HOOK=0` in the child environment. With that value the backend
does not create its interception window/thread and does not schedule Explorer
snapshots (`host.cpp` 172-201). `SystemTray` construction still starts the
host's 10-second prune timer (`host.cpp` 145-147), so isolation is not "zero
backend timers". `-Smoke` always disables activation. `Interactive` is an
unvalidated explicit opt-in and was not run.

No taskbar setting, Explorer process, registry value, notification-area
configuration or real tray icon was touched. No pointer or keyboard input was
sent. The fixture preview uses inert JS objects and a bundled PNG.

## Results

| Check | Observed result | Evidence |
| --- | --- | --- |
| Offscreen tray adapter | 115 assertions, 0 diagnostics, no native import or reference | [fixture result](fixture/result.json), [staged adapter](fixture/TrayService.qml), [staged fixture](fixture/TrayServiceTest.qml) |
| Disabled at 150% and 175% | Pass; `disabled`, no facade/backend/component, `SystemTray` construction marker absent | [primary](tray-disabled-screen0/result.json), [secondary](tray-disabled-screen1/result.json) |
| Read-only at 150% and 175% | Pass; `empty`, 0 items, 0 titles, `SystemTray` construction marker present, activation/menu refused, scroll unsupported | [primary](tray-readonly-screen0/result.json), [capture](tray-readonly-screen0/capture.png), [secondary](tray-readonly-screen1/result.json), [capture](tray-readonly-screen1/capture.png) |
| Fixture preview | Pass; 3 original delegates, asynchronous icon `Ready`, tint layer on, tint `#e2bdc7`, no native construction | [result](tray-fixture/result.json), [capture](tray-fixture/capture.png) |
| Original M1 regression | Pass | [result](m1-regression/result.json), [capture](m1-regression/capture.png) |
| Media adapter regression | Pass; 148 assertions | [result](shared-regressions/media-fixture/result.json) |
| Battery adapter regression | Pass; 128 assertions | [result](shared-regressions/battery-fixture/result.json) |

The construction marker is the backend's INFO line
`QS_WINDOWS_TRAY_HOOK=0: not hooking the system tray`, enabled only for tray
runs via `quickshell.windows.systray.info=true`. It appears in ReadOnly and is
absent in Disabled and fixture runs, so those modes did not construct
`SystemTray`. Both native runs recorded `hookMode=0`,
`interceptionEnabled=false`, `menuMode=native`, `menuCoordinatesSupported=false`
and `scrollSupported=false`.

Read-only observation recorded **0 items and 0 titles on both monitors**. This
is the expected result with interception disabled: in the pinned backend the
Explorer snapshot is scheduled only from the hook-after-first-frame path
(`host.cpp` 197-201), so `items` never leaves empty. The empty state therefore
cannot distinguish "no tray icons" from "enumeration never ran"; the service
reason intentionally claims neither.

[matrix.json](matrix.json) is the harness summary; per-run `result.json`,
`stdout.log`, `stderr.log`, `sources.json` and captures are copied without
rewriting paths. [artifacts.sha256.json](artifacts.sha256.json) identifies all
56 raw artifacts. [archive.ps1](archive.ps1) records the copy procedure.

## Preserved state

[Desktop before](desktop-before.json) and [after](desktop-after.json) preserve
Explorer PID 9252, KSG Shell PID 24108, both monitor bounds/work areas and
taskbar `ABM_GETSTATE` flags `1` (auto-hide on, always-on-top off). The harness
compares monitors, taskbar flags and the Explorer process; unrelated `qs`
processes from concurrent slices are recorded but not failed on. None appeared
in these snapshots.

## Commands

Native PowerShell from the repository root:

```powershell
$devRoot = Join-Path $env:LOCALAPPDATA 'caelestia-dev'
$qtPrefix = "$devRoot\Qt\6.11.2\msvc2022_64"
$llvmBin = "$devRoot\clang+llvm-20.1.8-x86_64-pc-windows-msvc\bin"
$buildRoot = 'D:\AiStack\caelestia-windows\windows\.local\build-tray'

powershell -NoProfile -File windows/scripts/Build-Prototype.ps1 `
    -QtPrefix $qtPrefix -LlvmBin $llvmBin `
    -Cli11Include "$devRoot\deps\CLI11-2.5.0\include" `
    -ToolsBin "$devRoot\tools\Scripts" -BuildRoot $buildRoot -Jobs 8

powershell -NoProfile -File windows/scripts/Test-TrayService.ps1 `
    -QtPrefix $qtPrefix -BuildRoot $buildRoot
powershell -NoProfile -File windows/scripts/Start-ShellPrototype.ps1 `
    -QtPrefix $qtPrefix -BuildRoot $buildRoot -Tray -TrayMode Disabled -Smoke
powershell -NoProfile -File windows/scripts/Start-ShellPrototype.ps1 `
    -QtPrefix $qtPrefix -BuildRoot $buildRoot -Tray -TrayMode ReadOnly -Smoke
powershell -NoProfile -File windows/scripts/Start-ShellPrototype.ps1 `
    -QtPrefix $qtPrefix -BuildRoot $buildRoot -Tray -TrayMode Disabled -TrayFixture -Smoke
powershell -NoProfile -File windows/scripts/Test-TrayPrototype.ps1 `
    -QtPrefix $qtPrefix -BuildRoot $buildRoot
```

`Test-TrayPrototype.ps1` runs the fixture, Disabled and ReadOnly smoke on every
measured monitor, the fixture preview, the M1 regression, and the media/battery
fixtures. The final run finished with `passed=true`, 11 records and
`sourceDirty=false`.

## Backend gaps (pinned `14010429`)

- `SystemTray` exposes only `items`; there is no readiness, snapshot-complete,
  Explorer-generation or error property (`qml.hpp` lines 16-18).
- `hasMenu` is always true while `menu` is always null (`item.hpp` lines
  102-104), so the original `TrayMenu` cannot render a semantic menu.
- `display()` ignores the parent window and both coordinates (`item.cpp` lines
  199-210); the service records that they are ignored instead of claiming
  placement. Activation/menu display call `AllowSetForegroundWindow` (`item.cpp`
  lines 149-153, 212-230) and can foreground another application.
- `scroll()` is an empty stub (`item.cpp` line 197).
- `ownerAlive()` is not invokable (`item.hpp` line 90), and Explorer identity is
  tracked only inside the hook (`hook.cpp` lines 474-487). A reset item list is
  observable, but an Explorer restart cannot be proven from QML.
- Read-only observation cannot enumerate items while interception is off; the
  snapshot path is part of the hook construction (`host.cpp` lines 172-201).
  App icons, tooltips, titles, real activation and the real native context menu
  therefore remain unobserved.

## Upstream edits and why

- `modules/bar/components/Tray.qml`: `sourceItems`, item interaction/menu hooks,
  `itemMenuRequested`. Defaults use `SystemTray` and upstream click behavior.
- `modules/bar/components/TrayItem.qml`: widened `modelData` role for inert
  fixtures, `interactionsEnabled`, `nativeMenuMode`, `nativeMenuRequested`,
  `iconItem` alias. Defaults activate/secondaryActivate as before.
- `modules/bar/popouts/TrayMenu.qml`: `semanticMenuAvailable` (default true) and
  an unavailable notice using the existing `m3outline` disabled colour.
- `components/effects/ColouredIcon.qml` and `Colouriser.qml` are staged
  unchanged; the portable build now includes `Caelestia.Images`.
- `windows/shell-prototype/adapters/services/Colours.qml`: added upstream
  `m3outline` `#9e8c91` for the disabled menu styling.
- `plugin/src/Caelestia/CMakeLists.txt` and `windows/README.md`: portable
  `Images` module with its Qt-only rationale.
- `windows/scripts/Stage-ShellPrototype.ps1` / `Start-ShellPrototype.ps1`:
  additive `-Tray`, `-TrayMode`, `-TrayFixture`, hook force, environment and
  result fields. The tray config node is added only for tray runs.

## Remaining acceptance

Real tray item observation, icon/tooltip rendering with live items, activation,
the native context menu and Explorer restart are **unvalidated**. Enabling
interception requires a separate tray-ownership review of the
`Shell_TrayWnd`/`TrayNotifyWnd` hook, message forwarding and `TaskbarCreated`
broadcast (`hook.cpp` 211-350) before it may be turned on. `Interactive` mode,
real icon clicks and the semantic `TrayMenu` with a live handle were not
exercised. M2 remains incomplete; no Linux build, release or remote CI pass is
claimed.
