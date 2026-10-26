# Windows Hyprland prototype (M3-2 stages 0-3)

This is the bounded M3-2 host for the original Caelestia bar workspace and
active-window components over the Windows `Hypr` facade. It is not a tiling
prototype: no `Tiling`, `WindowManager` or `Taskbar` object is constructed, and
no tiling option, taskbar hook or keyboard shortcut is staged.

## Scope

Staged original components (unmodified):

- [`modules/bar/components/workspaces/Workspaces.qml`](../../modules/bar/components/workspaces/Workspaces.qml)
- `Workspace.qml`, `SpecialWorkspaces.qml`, `OccupiedBg.qml`, `GapMarkers.qml`
  and `ActiveIndicator.qml` from the same directory
- [`modules/bar/components/ActiveWindow.qml`](../../modules/bar/components/ActiveWindow.qml)

The host places the workspaces indicator, an explicit inactive
`SpecialWorkspaces` instance and the vertical active-window indicator in a
bounded window of at most 620x700 logical pixels, inset 80 from the chosen
screen. Escape closes an interactive run.

The facade is staged at `services/Hypr.qml`, so the original components'
`import qs.services` and `Hypr.*` references resolve without an upstream change.
See [the service README](../services/hypr/README.md) for the property surface,
dispatch allowlist, refusals and startup side effects.

## Loading boundary

`shell.qml` imports no component that imports `Quickshell.Hyprland`. The
original components are loaded by `Loader.setSource()` only after
`Hypr.nativeInitialized` becomes true, using the small host wrappers in
`components/`:

- `WorkspacesHost.qml` injects the selected screen and lets the original
  Workspaces compute its own monitor through `Hypr.monitorFor(screen)`.
- `SpecialWorkspacesHost.qml` passes the global focused monitor.
- `ActiveWindowHost.qml` supplies the `bar`/popout host object ActiveWindow
  needs and the `Brightness.Monitor` property it declares but never reads.

With neither opt-in, no wrapper is created, the native backend loader stays
inactive, all models are empty, focused monitor/workspace are null and the
status line prints `hypr=0 dispatch=0`. The native Disabled run is the
regression proof that stage 0 is unchanged; it is the only mode this slice runs
on the desktop.

## Opt-ins and launch

```powershell
$qtPrefix = "$env:LOCALAPPDATA\caelestia-dev\Qt\6.11.2\msvc2022_64"
# Stage 0: no Hyprland import, contract-only status.
powershell -NoProfile -File windows/scripts/Start-ShellPrototype.ps1 `
    -QtPrefix $qtPrefix -Hypr -HyprMode Disabled -Smoke
# Stage 1/2: observation only, dispatch refused.
powershell -NoProfile -File windows/scripts/Start-ShellPrototype.ps1 `
    -QtPrefix $qtPrefix -Hypr -HyprMode Observe -Wait
# Stage 3: observation plus the allowlisted dispatch forms.
powershell -NoProfile -File windows/scripts/Start-ShellPrototype.ps1 `
    -QtPrefix $qtPrefix -Hypr -HyprMode Dispatch -Wait
```

`Disabled` is the default. `Observe` sets `CAELESTIA_WINDOWS_HYPR=1`.
`Dispatch` additionally sets `CAELESTIA_WINDOWS_HYPR_DISPATCH=1`; every
`-Smoke` run forces dispatch off. Every run prints exactly one
`CAELESTIA_HYPR_STATUS hypr=<0|1> dispatch=<0|1>` line.

`Observe` and `Dispatch` construct the backend's window tracker, virtual
desktop state and `TilingManager::instance()` (which runs `rescueParked()`); they
must be run only by the live M3 harness with a before/after desktop capture.
This slice records no native Observe or Dispatch result.

## Windows-local adapters

Two localized stand-ins are necessary and are not upstream component changes:

- `imports/M3Shapes/MaterialShape.qml` supplies the external `M3Shapes` module
  (`qt6-m3shapes-git`, not part of the portable build or the dependency pins)
  with the enum names and indicator properties the original `Workspace.qml`
  references. It is a plain rounded rectangle, not the upstream morphing path.
  The prototype selects the original `Text` workspace display type, so the
  shape indicator is not rendered in recorded runs.
- `adapters/services/Brightness.qml` supplies `Brightness.Monitor` for the
  original ActiveWindow's required-but-unused property. The upstream service
  starts `ddcutil`/`asdbctl` and is excluded from the portable build; this
  adapter reads and writes no display.

The prototype configuration sets `Config.bar.workspaces.showUnoccupied=true`,
`shown=5`, `displayType=Text` and `perMonitor=true` (the upstream default). It
also disables active-window hover expansion so smoke input stays bounded.

## Limitations

- Per-monitor workspace ownership is **not** claimed. The pinned backend binds
  every monitor's active workspace and every workspace's monitor to the global
  focused workspace/monitor. Every monitor shows the same active workspace and
  the fixture asserts that equality rather than inventing owners.
- Special-workspace UI is inactive. `specialWorkspace` is always empty and
  `specialWorkspace.id` is always 0, so `SpecialWorkspaces` lists nothing and
  `toggleSpecial()` is a no-op. The `togglespecialworkspace` dispatch string is
  consumed without reaching the backend.
- `killwindow` is translated to `closewindow`: a graceful `WM_CLOSE`, not
  Hyprland's force-kill. `togglefloating` and `pin` are refused because they
  require a tiler or `VirtualDesktopAccessor.dll`; `dpms`, `focusmonitor` and
  the other Hyprland-only commands are refused.
- The keyboard/`HyprExtras` members of the facade are unavailable defaults; no
  Windows keyboard state or Hyprland configuration socket is read.
- The external M3Shapes module is approximated only as described above; the
  original shape display type is not validated.
- Native `Observe` and `Dispatch` behavior, the original components against real
  monitors/windows, and every backend dispatch translation are untested by this
  slice and must not be claimed.

## Validation

```powershell
$qtPrefix = "$env:LOCALAPPDATA\caelestia-dev\Qt\6.11.2\msvc2022_64"
powershell -NoProfile -File windows/scripts/Test-HyprService.ps1 -QtPrefix $qtPrefix
powershell -NoProfile -File windows/scripts/Test-HyprPrototype.ps1 -QtPrefix $qtPrefix
```

`Test-HyprService.ps1` runs the offscreen fixture. `Test-HyprPrototype.ps1` runs
the fixture, the native Disabled smoke on every measured screen, and the
original M1 bar/session regression. It deliberately has no Observe/Dispatch
mode. Raw results are under
`windows/.local/build/hypr-validation-<timestamp>/`.
