# M3-2 Hyprland adapter and prototype, 2026-10-25

This archive records stages 0-3 of the M3-2 Hyprland (window/workspace) slice on
branch `t3/m3-hypr-adapter`. It adds a pure dispatch/observation state object, a
thin `Quickshell.Hyprland` wrapper loaded only after the observation opt-in, the
`Hypr` singleton facade staged at `services/Hypr.qml`, and a bounded host for
the original bar workspace and active-window components.

**No Hyprland observation or dispatch ran on this desktop.** The only native
mode recorded here is `Disabled`. Native `Observe` and `Dispatch` were
deliberately not launched; nothing in this archive moved a window, switched a
virtual desktop, constructed a tiler, changed the taskbar or sent a dispatch to
the backend. Every dispatch result in this slice is from the offscreen fixture's
recording fake. The orchestrator owns the live `Observe`/`Dispatch` runs.

## Sources and runtime

- Implementation commit
  `ca40f983f5d0aa6402a41cb8f87536dc894d9fe2`, clean during every recorded run
  (`sourceDirty=false`). The evidence commit that adds this directory is later
  and changes no runtime source.
- Backend unchanged at
  `1401042969e4b7ab3cfb314fc76945ab081db3de`; the root gitlink,
  `windows/sources.lock.json` and the submodule are not part of this slice.
- Windows 11 Pro `10.0.26300`, Qt `6.11.2`, existing shared build
  `D:\AiStack\caelestia-windows\windows\.local\build`. QML/PowerShell-only
  changes; no rebuild was performed.
- Primary monitor `\\.\DISPLAY1` at 150%, 3840x2160, origin `(0,0)`; secondary
  `\\.\DISPLAY2` at 175%, 3840x2160, origin `(-3840,0)`. Both native smokes ran
  at native scaling.

## Delivered behavior

- [`HyprService.qml`](../../services/hypr/HyprService.qml) imports only QtQuick.
  It projects an injected backend, implements the global-focus limitation and
  owns the dispatch allowlist and refusal records.
- [`NativeHyprBackend.qml`](../../services/hypr/NativeHyprBackend.qml) is the
  only file that imports `Quickshell.Hyprland`; it is loaded by URL through the
  facade's `Loader` only when `CAELESTIA_WINDOWS_HYPR=1`.
- [`Hypr.qml`](../../services/hypr/Hypr.qml) is staged at `services/Hypr.qml`
  and keeps the original component surface. Observation and dispatch are
  separate opt-ins (`CAELESTIA_WINDOWS_HYPR` and
  `CAELESTIA_WINDOWS_HYPR_DISPATCH`); dispatch needs both.
- Allowed dispatch forms: `workspace <1-9999>`, `workspace r+1`/`r-1`,
  `workspace name:<safe-name>`, `movetoworkspace <n>,address:0x<hex>` and
  `killwindow address:0x<hex>` translated to `closewindow address:0x<hex>`.
  `togglespecialworkspace` and `Hypr.toggleSpecial` are consumed no-ops.
  Everything else, including malformed, multi-command and injected strings, is
  refused before the backend call and recorded in `lastRefusal`.
- Special-workspace UI is inactive. The backend's `specialWorkspace` name/id is
  always empty/0, so the original `SpecialWorkspaces` component lists nothing.
- Per-monitor workspace ownership is **not** claimed:
  `workspaceForMonitor()` returns the global focused workspace for every
  monitor, matching the pinned backend. Every monitor shows the same active
  workspace.
- The host stages the original `Workspaces`, `Workspace`, `SpecialWorkspaces`,
  `OccupiedBg`, `GapMarkers`, `ActiveIndicator` and bar `ActiveWindow`
  components unmodified. Two Windows-local adapters are described in the
  [prototype README](../../hypr-prototype/README.md): the external `M3Shapes`
  module is a compile/display stand-in and the upstream `Brightness` service is
  replaced by an unavailable type stub. The prototype selects the original
  `Text` workspace display type, so the M3Shapes stand-in is not rendered.
- `Start-ShellPrototype.ps1` gained the `hypr` row (`-Hypr`, `-HyprMode
  Disabled|Observe|Dispatch`; smoke forces dispatch off) and
  `Stage-ShellPrototype.ps1` gained the `hypr` slice. No `Tiling`,
  `WindowManager` or `Taskbar` object is staged or constructed.

## Commands and results

All commands were run from the worktree with the shared build and Qt prefix:

```powershell
$qtPrefix = "$env:LOCALAPPDATA\caelestia-dev\Qt\6.11.2\msvc2022_64"
$buildRoot = 'D:\AiStack\caelestia-windows\windows\.local\build'

powershell -NoProfile -File windows/scripts/Test-HyprService.ps1 `
    -QtPrefix $qtPrefix -BuildRoot $buildRoot
powershell -NoProfile -File windows/scripts/Test-HyprPrototype.ps1 `
    -QtPrefix $qtPrefix -BuildRoot $buildRoot
powershell -NoProfile -File windows/scripts/Test-NetworkPrototype.ps1 `
    -QtPrefix $qtPrefix -BuildRoot $buildRoot
powershell -NoProfile -File windows/scripts/Test-AppsPrototype.ps1 `
    -QtPrefix $qtPrefix -BuildRoot $buildRoot
```

| Check | Observed result | Evidence |
| --- | --- | --- |
| Offscreen Hypr fixture | **578 assertions**, exit 0, no Quickshell import in the state object, no staging hash mismatch, no QML diagnostics | [result](evidence/hypr-fixture-result.json), [stdout](evidence/hypr-fixture.stdout.log), [stderr](evidence/hypr-fixture.stderr.log) |
| Hypr native matrix | **4/4 runs passed**: fixture, Disabled smoke on both measured screens, M1 regression | [matrix](evidence/hypr-prototype-result.json) |
| Disabled at 150% (screen 0) | Pass; `status=disabled`, `hypr=0 dispatch=0`, no native loader, no backend, no original component, no dispatch, no refusal | [result](evidence/hypr-prototype-result.json), [stdout](evidence/hypr-disabled-screen0.stdout.log), [png](evidence/hypr-disabled-screen0.png) |
| Disabled at 175% (screen 1) | Pass; same disabled invariants on the negative-origin secondary | [result](evidence/hypr-prototype-result.json), [stdout](evidence/hypr-disabled-screen1.stdout.log), [png](evidence/hypr-disabled-screen1.png) |
| Original M1 bar/session regression | Pass; no Hyprland backend marker in its log | [result](evidence/m1-regression.stdout.log), [png](evidence/m1-regression.png) |
| Network prototype regression | **6/6 runs passed** (fixture, 2 screens x Disabled/ReadOnly, M1) | [result](evidence/network-prototype-result.json) |
| Apps prototype regression | **8/8 runs passed** (fixture, 2 screens, search, frequency reads, M1) | [result](evidence/apps-prototype-result.json) |
| Desktop identity before/after | Monitors, work areas, taskbar state, Explorer and non-`qs` process set unchanged | [before](evidence/desktop-before.json), [after](evidence/desktop-after.json) |
| Static staged check | `qmllint` over all 15 staged Hypr/prototype files reported no syntax or type errors. Remaining warnings are analyzer limits: `Loader.item` inferred as `QObject`, palette members on `var`, the `StyledWindow` `margins` attached scope, and the installed `Caelestia.I18n` qmldir listing a missing `Tr.qml`. | [qmllint output](evidence/qmllint-staged.txt) |

The fixture's stderr contains the expected `console.warn` lines for every
refusal case; that is the adapter's refusal evidence, not a test failure.

Auxiliary offscreen checks (not committed scripts): the staged `M3Shapes`
stand-in instantiated and read all 20 enum values the original `Workspace.qml`
references, and a `Brightness.Monitor`-typed property resolved and accepted
`null` with the staged adapter. Neither check loads Quickshell or touches the
desktop.

## Untested and limits

- **All native `Observe` and `Dispatch` behavior is untested.** The original
  workspace/active-window components have only been compiled (staged and
  `qmllint`) and their facade has only been exercised against the fake backend.
  The orchestrator's live run still has to prove monitors/workspaces/toplevel
  mapping, the original components' rendering and bindings, component loading
  after `nativeInitialized`, and the global-focus behavior on real monitors.
- Every allowlisted dispatch form and the `killwindow` → `closewindow`
  translation were checked against the recording fake only. No real virtual
  desktop was created or switched, no window was moved and no window was
  closed.
- `togglefloating`, `pin`, `dpms`, `focusmonitor` and the other Hyprland-only
  commands are refused by design, not implemented.
- Special-workspace UI is only proven inactive; no active special workspace can
  exist on the pinned backend.
- Per-monitor workspace ownership cannot be shown truthfully without a backend
  change; the archive records the limitation, not a fix.
- The external `M3Shapes` module is approximated and the prototype selects the
  original `Text` display type. The default `Shapes` indicator path is not
  rendered or validated.
- Native input on the loaded workspaces indicator (clicking a workspace or
  scrolling) is not exercised; smoke is no-input and `Dispatch` native is
  forbidden in this archive.
- Tiling construction (M3-2 stages 4-8), fitting-failure UI and the full M3
  scenario matrix remain untouched.

## Orchestrator live runs (2026-10-25, ~20:01-20:08)

Run on the shared desktop by the orchestrator as the single controller, at
`4242820e` with the shared build (backend pin `1401042`). ksg-shell was
running; it was not stopped for these stages because no tiler was constructed.

### Stage 1/2: Observe smoke, both monitors

```powershell
Start-ShellPrototype.ps1 -QtPrefix <Qt 6.11.2> -BuildRoot <shared build> -Hypr -HyprMode Observe -Smoke -ScreenIndex 0
Start-ShellPrototype.ps1 ... -Hypr -HyprMode Observe -Smoke -ScreenIndex 1
```

- The first run failed only because the settled check read
  `state.nativeInitialized`, which the snapshot records as `initialized`
  (fixed in `4242820e`). Both monitors then passed.
- Backend: 2 monitors, 1 workspace, 6 toplevels, focused monitor
  `MAG321UX OLED`; original `Workspaces` rendered 5 slots with workspace 1
  active, `ActiveWindow` rendered, special workspaces inactive.
- `Get-DesktopState.ps1` before/after: identical apart from the capture time.
  No `qs` process remained. `rescueParked` acts only on windows carrying the
  `QuickshellTilingParked` property, so ksg-shell windows are out of scope.
- Visual gap: the workspace labels render as tofu. The upstream defaults are
  Nerd Font glyphs (`occupiedLabel`/`activeLabel` `\U000F0BAF`), and no Nerd
  Font is installed or bundled. Packaging (M4) must ship a symbols font or
  the Windows config must choose labels that the bundled fonts cover.

### Stage 3: Dispatch, live (user authorized)

`-Hypr -HyprMode Dispatch -ScreenIndex 0`, then a click on workspace 2 in the
original indicator (one background click and one foreground click).

- The adapter behaved as designed: `commandsSent=2`, `lastDispatch="workspace 2"`,
  no refusals.
- The backend did not create or switch a desktop.
  `VirtualDesktopAccessor.dll` is absent, so creation falls back to a
  synthetic Ctrl+Win+D chord. No new desktop appeared (registry `Desktops`
  entries unchanged before/after; `workspaceCount` stayed 1), but every
  normal window on both monitors was minimized, which is the Win+D
  show-desktop effect. Whether the chord lost its Ctrl modifier or another
  keyboard hook (ksg-shell) intercepted it is not established.
- Cleanup: the orchestrator restored Dia, ZCode and T3 Code (the pre-test
  foreground) with `ShowWindowAsync(SW_RESTORE)`. Windows Terminal and Steam
  were left minimized because their pre-test state was not recorded. One
  stray `Ctrl+Win+F4` and one `Win+D` were sent during diagnosis; with a
  single desktop the former is a no-op.

**Decision:** workspace creation and switching must not use synthetic
shortcuts. Stage 3 dispatch requires `VirtualDesktopAccessor.dll`; without
it the adapter refuses workspace dispatch with a clear reason. Shipping the
accessor is an M4 packaging item, and the synthetic-chord fallback is a
backend defect to fix or disable in the fork.

## Follow-up: desktop-control gate (2026-10-25)

The root adapter on this branch now refuses every `workspace`/`movetoworkspace`
form unless the backend reports `desktopControlSupported === true`. The property
is feature-detected with `typeof`, so the current pin (which lacks it) refuses
with reason `desktop-control-unavailable` and the text
`Switching workspaces needs VirtualDesktopAccessor.dll.` `killwindow` →
`closewindow` is not gated. The offscreen fixture covers absent, false, true and
a runtime flip; `Test-HyprService.ps1` passes with 640 assertions, and
`Test-HyprPrototype.ps1` passes its 4-run Disabled-only matrix. The backend fork
branch `windows/m3-desktops-accessor-only` (commit `084d23f`) removes the
synthetic chord: switch/create/ensure refuse without the accessor, waiters
complete false, and the Hyprland singleton exposes the capability. The root
gitlink, `windows/sources.lock.json` and the pinned backend revision are
unchanged, so this branch refuses workspace dispatch until a later pin update
ships the accessor-backed capability.
