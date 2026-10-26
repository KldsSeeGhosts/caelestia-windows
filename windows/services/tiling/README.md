# Windows tiling service

M3-2 stages 4/5 groundwork: constructing the backend's `Tiling` controller
behind bounded opt-ins, applying its options without enabling it, and
explaining fitting failures on Caelestia's original toast surface. The M3-1
audit's one-active-tiler and construction-side-effect rules apply; see
`windows/audits/M3-BACKEND-API.md` ("Tiling options and lifecycle", "Startup
effects and safety").

| file | role |
| --- | --- |
| `TilingService.qml` | pure state object: opt-in policy, interactive gating, backend projection, bounded failure list and toast decisions |
| `NativeTilingBackend.qml` | thin wrapper that imports `Quickshell.Windows` and feature-detects the allowlist/telemetry members; loaded by URL only for observe/interactive |
| `Tiling.qml` | singleton facade staged at `services/Tiling.qml`; owns the environment opt-ins, the native `Loader` and the `Toaster.toast` bridge |

## Opt-ins

Child-process environment variables; the launcher writes every one
explicitly so an inherited value cannot enable tiling.

- `CAELESTIA_WINDOWS_TILING=off|observe|interactive`, default `off`.
  `off` never imports or constructs the backend `Tiling` singleton: the
  facade's `Loader` is bound to the service's `nativeRequested` flag, which
  is false only for `off`. `observe` constructs the wrapper (which runs
  `TilingManager::instance()` and `rescueParked()`), applies `excluded` and
  `included`, and keeps `enabled` false. `interactive` additionally requests
  `enabled = true`, but only when the parsed inclusion list is non-empty AND
  the backend supports `included` (typeof feature detection); otherwise the
  status is `refused` with the reason and the tiler stays disabled. Smoke
  runs force interactive down to observe before anything loads.
- `CAELESTIA_WINDOWS_TILING_INCLUDED`, semicolon-separated wildcards in the
  backend's shared dialect (`title:` prefix selects titles; anything else
  matches app id, executable name/basename and window class). An empty list
  means "all eligible windows" on the backend, which is exactly why
  interactive refuses to enable without one: enabling would immediately lay
  out every eligible window on the desktop.
- `CAELESTIA_WINDOWS_TILING_EXCLUDED`, same dialect, always applied.
  Exclusions win over inclusions; the host process is never managed by the
  backend itself.

The backend pin (`14010429`) predates the fork branch
`windows/m3-windows-stack` (`cd170acf`) that adds `included`, `lastError`,
`managedCount`, `failedCount`, `enableRefused(reason)` and
`windowTilingFailed(address, reason)`. Everything beyond `enabled` and
`excluded` is therefore feature-detected: on the pinned build
`supportsIncluded` is false (so interactive always refuses), telemetry
properties report their defaults (`0`/empty) and no signals arrive. No
backend edit is part of this slice.

`CAELESTIA_WINDOWS_HYPR=1` observation is not required, but with it the
facade resolves each failure's `appClass`/`title` through the Hypr
toplevels; without it the toast says "a window".

## Status

`disabled` (`off`), `observing` (constructed, options applied, `enabled`
false — including interactive still waiting for or denied an enable),
`refused` (interactive blocked by policy, or the backend refused enabling:
`tiler-mutex-held`, `no-screen`), `tiling` (backend `enabled` true). The
facade prints one `CAELESTIA_TILING_STATUS tiling=<mode> included=<n>
excluded=<n> status=<status>` line at startup.

## Fitting-failure explanation

The backend emits `windowTilingFailed(address, reason)` with the address as
lowercase hex without `0x` (matching `HyprlandToplevel`) and one reason of
`min-size`, `off-target`, `correction-limit`, `unresponsive`. The service
records `{address, appClass, title, reason, time}` in a 20-entry list and
decides toasts on the original surface (`Toaster.toast` with `Toast.Warning`
or `Toast.Error`, icon `view_quilt`, copy through `Tr.tr`):

| reason | title | message |
| --- | --- | --- |
| any | `Couldn't tile <App>` (app class, else title, else `a window`) | per reason below |
| `min-size` | | `It needs more space than its tile; it was left floating.` |
| `off-target` | | `It kept moving away from its tile; it was left floating.` |
| `correction-limit` | | `It didn't fit its tile exactly, so it may leave a gap.` |
| `unresponsive` | | `It stopped responding while being placed.` |
| unknown | | `It could not be placed in its tile.` |

Rate limits: at most one toast per window address per reason per enabled
session; at most three failure toasts per ten seconds; suppressed excess
collapses into one `Some windows couldn't be tiled` toast, itself shown at
most once per ten seconds (the summary does not consume the three-toast
budget). An enable refusal emits exactly one `Tiling is off` error toast
(`Another tiling manager is already running.` / `No screen is available to
tile on.`).

## Testing

`TilingServiceTest.qml` is an offscreen fixture with fake backends in both
shapes (pinned build without the new members, fork shape with them); it
covers the mode policy, gating refusals, pattern parsing, failure records,
the list cap, every toast copy string, both rate limits, the collapse toast,
enable-refusal toasts and the count/error projection. It imports no
Quickshell or Caelestia module. Run it through
`windows/scripts/Test-TilingService.ps1`.
