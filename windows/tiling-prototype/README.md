# Windows tiling prototype (M3-2 stages 4/5 groundwork, M3-3 explanation)

This is the bounded M3 host for the tiling opt-in slice: the pure
[TilingService](../services/tiling/README.md) state, the backend `Tiling`
controller behind observe/interactive opt-ins, and Caelestia's original toast
surface explaining fitting failures. It grounds M3-2 stages 4 (tiler
constructed, disabled) and 5 (interactive on an allowlist) and the M3-3
fitting-failure explanation, without claiming any live stage: the native
harness runs Disabled mode only, and observe/interactive runs belong to the
orchestrator's live plan against a prepared desktop.

No `WindowManager`, `Taskbar`, keyboard shortcut, taskbar hook or dispatch
request is staged by this host.

## Scope

Staged original components (unmodified):

- [`modules/utilities/toasts/Toasts.qml`](../../modules/utilities/toasts/Toasts.qml)
  and `ToastItem.qml` — the original toast surface. Fitting-failure and
  enable-refusal toasts decided by the service are shown here through
  `Toaster.toast` exactly as upstream daemons show theirs; nothing is
  synthesised in Disabled runs.

Staged adapters and services:

- `windows/services/tiling/Tiling.qml` at `services/Tiling.qml` — the
  facade singleton owning the opt-ins, the native wrapper `Loader` and the
  `Toaster.toast` bridge.
- `windows/services/hypr/Hypr.qml` at `services/Hypr.qml` — the real Hypr
  facade, so failure records can resolve `appClass`/`title` when
  `CAELESTIA_WINDOWS_HYPR=1` is also set. It stays fully disabled without
  that opt-in.
- `windows/tiling-prototype/adapters/services/Notifs.qml` at
  `services/Notifs.qml` — answers the toast surface's one question
  (`hasFullscreen()`) with a truthful false; no notification daemon is
  constructed.

## Loading boundary

`shell.qml` imports no component that imports `Quickshell.Windows`. The only
file that does is `NativeTilingBackend.qml`, loaded by the facade's `Loader`
exactly when the service's `nativeRequested` flag is true — that is, never
for `off`. Constructing the backend `Tiling` singleton runs
`TilingManager::instance()` and `rescueParked()`, which can move windows a
previous run parked off-screen; observe and interactive are therefore
explicit opt-ins, and `off` resolves no native type at all.

Interactive additionally requires `CAELESTIA_WINDOWS_TILING_INCLUDED` to
name a non-empty wildcard allowlist and a backend that supports `included`.
The shared build pins the backend without that member, so interactive
truthfully refuses (status `refused`) rather than tiling every eligible
window on the desktop. Smoke runs force interactive down to observe before
anything loads.

## Opt-ins and launch

```powershell
$qtPrefix = "$env:LOCALAPPDATA\caelestia-dev\Qt\6.11.2\msvc2022_64"
# Default: no tiling controller constructed at all.
powershell -NoProfile -File windows/scripts/Start-ShellPrototype.ps1 `
    -QtPrefix $qtPrefix -Tiling -TilingMode Disabled -Smoke
# Stage 4: construct, apply options, keep enabled false.
powershell -NoProfile -File windows/scripts/Start-ShellPrototype.ps1 `
    -QtPrefix $qtPrefix -Tiling -TilingMode Observe -Wait `
    -TilingExcluded 'ksg-shell;explorer'
# Stage 5: interactive on an explicit allowlist (orchestrator live run;
# requires a backend build with `included` support and a prepared desktop).
powershell -NoProfile -File windows/scripts/Start-ShellPrototype.ps1 `
    -QtPrefix $qtPrefix -Tiling -TilingMode Interactive -Wait `
    -TilingIncluded 'fixture-app*;title:Test*' -TilingExcluded 'explorer'
```

The facade prints one
`CAELESTIA_TILING_STATUS tiling=<mode> included=<n> excluded=<n> status=<status>`
line at startup; smoke forces `-TilingMode Interactive` down to observe in
the child environment. Stop interactive runs only through the printed
`Stop-Process -Id <pid>` of the exact instance.

## Limits

- The native harness (`Test-TilingPrototype.ps1`) runs Disabled only. All
  Observe/Interactive native behavior — construction side effects, options
  application, mutex refusal, real toasts on screen, enable/disable window
  movement — is untested here and owned by the orchestrator's live runs.
- On the pinned backend the telemetry members do not exist: counts stay 0,
  `lastError` stays empty, no failure/refusal signals arrive, and
  interactive always refuses. The fixture exercises the fork shape with
  fakes; no backend rebuild is part of this slice.
- Only one tiler may be active on the desktop (KSG Shell or this one); the
  backend mutex only excludes other Quickshell tilers.
