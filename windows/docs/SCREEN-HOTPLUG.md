# Windows screen identity after hotplug (#88)

## Confirmed mechanism

[Qt 6.11.2's Windows screen manager](https://github.com/qt/qtbase/blob/v6.11.2/src/plugins/platforms/windows/qwindowsscreen.cpp#L836)
matches a new display snapshot to an existing screen by its GDI device name.
`QWindowsScreen::handleChanges()` updates the native HMONITOR, physical size,
geometry, available geometry, DPI, orientation, primary flag and refresh rate.
It does not replace the stored friendly name, model or serial number.
A GDI source reused for another monitor therefore retains the old Qt name.

Before this fix, `src/core/qmlscreen.cpp` forwarded `QScreen::name()` and
`qmlscreen.hpp` declared the QML name `CONSTANT`. Most native Windows consumers
also read Qt's name directly. Restarting constructs fresh Qt screens, explaining
why a clean restart corrects the names.

The duplicated label alone does not prove the cause of the reported utilities
clipping or the 0/5 Dell OSD hover result. The audit also found independent
reuse-sensitive native geometry, input-mask and monitor-handle cache paths.
This change fixes those refresh paths as well; only the live check below can
confirm the observed symptoms are gone.

## Affected consumers and refresh paths

Backend paths in this section are relative to `windows/deps/quickshell`.

| Consumer | Identity/state dependency and treatment |
| --- | --- |
| `windows/shell/shell.qml` | State output and name-targeted panel IPC now read the corrected, notifying ShellScreen name. |
| `services/Screens.qml`, `modules/background/Background.qml`, Windows background adapter | Screen enablement, background enablement and desktop-clock config use `GlobalConfig.forScreen(name)`. Name notification re-evaluates these filters/bindings. |
| `components/containers/StyledWindow.qml`, Nexus window factories, lock surface | Config and Tokens attached objects select per-monitor override trees by name. They now receive name changes on the existing screen. Config/Tokens caches remain keyed by the configured name, as intended. |
| `modules/bar/BarWrapper.qml` | Name-regex screen exclusions re-evaluate. |
| `services/ShellState.qml`, drawer `ContentWindow.qml` and `Panels.qml` | Variants, open-panel state, fullscreen state and component ownership use screen/monitor object identity. Preserve those objects instead of destroying all drawers on a rename. The correct Config/Tokens tree and Hyprland monitor metadata now refresh underneath them. |
| `src/windows/panel_window.cpp` | Panels already watched screen geometry/DPI, but same-pointer selection and unchanged logical bounds could leave native placement or mask publication unchanged. Registry events now invalidate AppBar placement and coalesce re-anchoring. The all-edge drawer resizes to the current logical screen; native bounds are reconciled through ScreenMapper even if Qt's logical rectangle did not change. Masks and their native/DPR snapshot are republished. |
| `src/windows/input_mask.cpp`, native panel input region | Logical Regions are hit-tested with a published window DPR. Refresh that snapshot after remapping; regenerate scaled HWND regions too. An old scale/bounds pair can miss the Dell's right-edge OSD strip while accepting input elsewhere. |
| PR #79 `WindowsHover.js`, `WindowsHoverRegions.qml`, drawer Interactions/Regions | Adjacency uses object identity, coordinates, logical dimensions and DPR, not monitor names. Geometry/DPR notification recalculates shared-edge strips; window resize and mask refresh align them with the new native bounds. No hover-width or visual-design change. |
| `src/windows/hyprland/monitor.cpp`, `hyprland/connection.cpp`, Hypr adapter | Monitor names/scales/geometry and IPC metadata refresh in place. Add/remove and registry topology changes coalesce into monitor reconciliation, input-hook cursor-rectangle invalidation and focused-monitor recomputation. `monitorFor()` prefers QScreen pointer identity; its name fallback already consumes ShellScreen's corrected name. Workspace-count config reads the corrected Hyprland monitor name. |
| `src/windows/window_tracker.cpp` | Its HMONITOR-to-QScreen map previously refreshed only on add/remove. Qt may replace HMONITOR without replacing QScreen. Rebuild the map and re-observe tracked windows on registry changes, keeping fullscreen/toplevel monitor associations current. |
| `src/windows/tiling.cpp`, `tiling_scope.cpp` | Screen selectors now use corrected names and are re-evaluated. Layout ownership remains desktop GUID plus live QScreen pointer; remove the obsolete friendly-name part so a rename cannot strand the previous layout tree. Geometry/DPI changes still trigger re-layout. |
| Windows brightness facade/service, native brightness/gamma | Native name lookup and route pruning use the shared resolver. Display changes cause the adapter to reconcile its name-keyed records even if the screens array is unchanged, then requery them. The MSI record is preserved while a separate Dell record is created. Gamma translates a public friendly name back to the current GDI source before CreateDC. Remaining factor/ramp cache lifetime work is listed below. |
| Desktop drop, Input screen enumeration, screenshots, screen recorder, brightness probe | All native screen-name publication/selection uses the same resolver, avoiding a mismatch between QML names and native selectors. |
| `src/windows/taskbar.cpp`, `appbar.cpp`, panel AppBars | Taskbar discovery uses HWNDs/HMONITORs, not friendly names. Registry changes now schedule its existing settled rediscovery. Panel AppBars are invalidated and reserved again against the current native monitor. |
| `windows/scripts/DesktopTakeover.cs` and desktop supervisor | Monitor work-area inspection and crash cleanup use native rectangles and owned HWND/PID records, not Qt screen labels. No persisted friendly-name identity to correct and no supervisor/taskbar ownership change is needed. |
| `src/windows/animation_timing.cpp`, native Displays service | Animation watches refresh-rate signals; Displays reads Windows display-config paths independently. Neither needs the Qt friendly name. |
| Dictation target selection | Requested screen names resolve against the corrected ShellScreen list. No screen-name cache is kept in the indicator. |

### Remaining follow-ups, not fixed by this PR

- `src/windows/wayland/screencopy_view.cpp:206` resolves an HMONITOR when a
  capture starts and retains it in the capture context. An already-running
  capture does not rebind when the same QScreen's native monitor changes.
  Retained capture contexts need explicit invalidation/recreation on topology
  or target-path replacement, including same-model replacement.
- `src/windows/system/gamma.hpp:63` and the adjacent factor/ramp maps still
  key dimming factors, floors, saved originals and restoration obligations by
  friendly name, without target-path invalidation. Same-model monitor
  replacement can reuse that name and inherit stale factors or saved ramps.
  Correct CreateDC source lookup does not fix that cache ownership issue;
  the follow-up must bind these records to physical target identity and define
  restoration behavior when the old target is gone.

A wrong per-monitor Config/Tokens tree can change drawer enablement, dimensions,
border widths and hover thresholds. Independently, a stale native placement can
clip a bottom/right anchored panel; a stale mask/DPR or monitor association can
lose a narrow edge trigger. These are plausible links to the report, not a claim
that a physical power-cycle was reproduced during implementation.

## Backend solution

`ScreenIdentityRegistry` queries active DisplayConfig source/target records.
The current GDI source links a QScreen's current HMONITOR to a target interface
path and friendly name. Metadata is not retained solely under the reusable GDI
source: the full target path participates in identity comparison, including
replacement by a same-model monitor. EnumDisplayDevices with
`EDD_GET_DEVICE_INTERFACE_NAME` supplies a fallback target path/name.

The registry watches screen add/remove, geometry/DPI changes and native display,
device, DPI and settings messages. It refreshes after Qt processes the event
and once more after 250 ms of settling. It publishes a complete snapshot before
notifying consumers. Metrics include the current native handle so a handle-only
replacement also refreshes the tracker and panels. Missing friendly metadata
preserves the last known name only when the non-empty target path matches.
An unidentified new target exposes its device path; if even the path is
unavailable, it exposes an unresolved label. Qt's stale name is never a fallback.

ShellScreen name is now notifying rather than constant. DPR has its own
notification for geometry, logical-DPI and physical-DPI changes. The global
screen list also invalidates on identity changes for imperative consumers.
Non-Windows screen names still come from Qt. Qt's own model/serial properties
are not rewritten by this fix.

## Validation and integration

- Backend topic branch is based on fork `dev` commit `f3d217f4`.
- The Caelestia gitlink and `windows/sources.lock.json` temporarily pin the
  backend topic head together. After the backend PR merges, repin both to the
  resulting fork `dev` commit before integrating the Caelestia PR.
- Build root: `C:\b-scr88s`. No live installation or shell restart.
- `screen_identity_test`: fake display-config targets, real Qt screen reuse,
  a real QML config-selection binding, unchanged MSI identity, same-name target
  path replacement, partial-metadata preservation, unresolved fallback names,
  a position swap without add/remove followed by movement inside the old cached
  cursor rectangle, negative-origin re-anchoring, resize, DPR-only notifications
  and native-region scaling. Offscreen, no HWND.
- Additional checks: brightness route, tiling manager/scope and panel-animation
  tests, Windows brightness QML fixture, shared-edge hover fixture, paired-pin
  environment validation and `git diff --check`.
- Offscreen tests cannot validate DWM placement, native pointer routing,
  physical monitor power-cycling, Explorer work areas or the installed shell.

## Exact live check still required

Use a separately authorized live installation of the paired PR build. While
the shell remains running, power the Dell S2725QS off and back on. Do not
restart the shell between the cycle and these checks.

1. Run `windows/scripts/Start-Caelestia.ps1 -Command State`. Expect one
   `DELL S2725QS` at about 2194 x 1234 logical, DPR 1.75, and one
   `MAG321UX OLED` at 2560 x 1440 logical, DPR 1.5.
2. On the Dell, approach the shared right edge at OSD height five times.
   Expect 5/5 openings before crossing onto the MSI, usable controls, closing
   after leaving, and pass-through outside the intended trigger region.
3. Open the Dell bottom-right utilities panel. Confirm the complete panel is
   inside the Dell's right/bottom bounds, with no clipping and clickable edges.
4. Confirm the MSI's name, scale, bar/borders, OSD hover and utilities placement
   are unchanged. Check its normal desktop interactions and tiling/work areas.

Record before/after State and cropped evidence without personal data. This
implementation intentionally did not power-cycle displays, drive the desktop,
install, restart the live shell, change authentication, merge or update trackers.
