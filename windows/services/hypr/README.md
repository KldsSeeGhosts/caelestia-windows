# Windows Hyprland service adapter

M3-2 stages the `Hypr` singleton that Caelestia's bar workspace and active-window
components consume. It is not a compositor and does not implement tiling. It
projects the pinned Windows backend's Hyprland-shaped read model and applies a
strict dispatch allowlist.

| file | role |
| --- | --- |
| `HyprService.qml` | pure state object: backend projection, global-focus limitation, dispatch allowlist/refusals, special-workspace no-ops |
| `NativeHyprBackend.qml` | thin wrapper that imports `Quickshell.Hyprland`; loaded by URL only after the observation opt-in |
| `Hypr.qml` | singleton facade staged at `services/Hypr.qml`; keeps the surface the original modules consume, owns the environment opt-ins and the native `Loader` |

## Opt-ins

Both are child-process environment variables; the launcher writes both
explicitly so an inherited value cannot enable Hyprland.

- `CAELESTIA_WINDOWS_HYPR=1` observes `monitors`, `workspaces`, `toplevels`,
  `focusedMonitor`, `focusedWorkspace`, `activeToplevel` and `monitorFor()`.
  With this opt-in absent, the facade resolves no native type and exposes empty
  models and a null focused monitor, exactly like the M1 contract adapter.
- `CAELESTIA_WINDOWS_HYPR_DISPATCH=1` additionally permits the allowlisted
  dispatch forms. It is only set for `-HyprMode Dispatch` outside `-Smoke`, and
  dispatch is refused unless **both** opt-ins are set.

## Startup effects

Loading `NativeHyprBackend.qml` references the Quickshell Hyprland singleton.
That constructs `HyprlandIpc`: `WindowTracker` (WinEvent hooks, a sweep timer),
`VirtualDesktops` (COM, registry watcher, accessor load), the dispatcher,
input-mask watchers, screen/model sync and an `openwindow` event per tracked
window. Constructing a `HyprlandToplevel` also calls
`TilingManager::instance()`, which runs `rescueParked()` and registers the quit
handler even though tiling stays disabled. These are process-wide side effects
and the reason the import is isolated behind the opt-in. No `Tiling`,
`WindowManager` or `Taskbar` object is constructed by this adapter.

## Global focus per monitor (explicit limitation)

The pinned backend binds every monitor's `activeWorkspace` and every workspace's
`monitor` to the single global focused workspace/monitor
(`monitor.cpp:22-24`, `workspace.cpp:23`). The facade therefore does not claim
per-monitor ownership: `workspaceForMonitor(monitor)` returns the global focused
workspace for every monitor, and the prototype documents that all monitors show
the same active workspace. The fixture asserts this equality for each monitor.

## Dispatch policy

`dispatch(request)` is the only path to `backend.dispatch()`. Observation and
dispatch must both be enabled. The request must be a string of at most 96
characters, with no control characters, quotes, backslashes, semicolons,
backticks, `$`, pipes, `&`, `<` or `>`. Only these forms are forwarded:

| request | backend action | notes |
| --- | --- | --- |
| `workspace <1-9999>` | `workspace <n>` | numeric desktops |
| `workspace r+1`, `workspace r-1` | unchanged | controlled relative step |
| `workspace name:<safe-name>` | unchanged | backend resolves existing names only; `[A-Za-z0-9_.-]{1,64}` |
| `movetoworkspace <1-9999>,address:0x<hex>` | unchanged (address lowercased) | one selector, no follow-up command |
| `killwindow address:0x<hex>` | `closewindow address:0x<hex>` | documented graceful-close downgrade: `WM_CLOSE`, not a force-kill |
| `togglespecialworkspace <safe-name>` | consumed | no-op; Windows has no special workspaces |

Everything else is refused before the backend call with a `console.warn` and a
`lastRefusal` object (`request`, `reason`, `text`, `sequence`). Reasons:
`dispatch-disabled`, `unavailable`, `not-string`, `invalid`, `unsupported`,
`injection`, `too-long`. `toggleSpecial()` and `cycleSpecialWorkspace()` are
always consumed as no-ops. `lastDispatch`, `lastDispatchKind`, `commandsSent`,
`refusals`, `consumed` and `dispatchSequence` record what happened. A request is
not a result: the backend's `dispatch` is void and cannot confirm success.

## Facade surface

The facade keeps the members the audited original modules read:
`toplevels`, `workspaces`, `monitors`, `usingLua`, `activeToplevel`,
`focusedWorkspace`, `focusedMonitor`, `activeWsId`, `monitorFor()`,
`dispatch()`, `focusWorkspace()`, `toggleSpecial()`, `cycleSpecialWorkspace()`,
`trimWsName()`, `toplevelsForWs()`, `isToplevelIgnored()`, `monitorNames()`,
`reloadDynamicConfs()`, `configReloaded`, `lastSpecialWorkspace`, `options`,
`extras`, `devices`, `keyboard`, `capsLock`, `numLock`, `defaultKbLayout`,
`kbLayoutFull`, `kbLayout` and `kbMap`.

The keyboard fields are truthful unavailable defaults: the Windows backend
supplies no keyboard state. `extras` exposes no-op `refreshOptions()`/
`batchMessage()` and `options` is empty because there is no Hyprland
configuration socket. `configReloaded` is never emitted because the backend
never emits `configreloaded`. `monitors`, `workspaces` and `toplevels` pass the
backend `ObjectModel` objects through unchanged, so the original components'
typed `HyprlandMonitor`/`HyprlandWorkspace`/`HyprlandToplevel` properties still
work without upstream type changes.

## Validation

`windows/scripts/Test-HyprService.ps1` stages only `HyprService.qml` and
`HyprServiceTest.qml` into Qt's offscreen `qml.exe`. It rejects Quickshell
imports, staging hash mismatches and QML diagnostics. The fixture's fake backend
covers default-off construction, observation mapping, the global-focus model,
every allowlisted form and translation, every refused/malformed/injected form,
special-workspace no-ops and dispatch gating. `Test-HyprPrototype.ps1` adds the
native Disabled smoke and the M1 regression.
