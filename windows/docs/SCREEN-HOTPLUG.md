# Windows screen identity after hotplug

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

A duplicated label alone does not establish the cause of utilities clipping
or missed OSD hover input. Reuse-sensitive native geometry, input-mask and
monitor-handle cache paths refresh independently. Use the live checks below
to verify the resulting placement and input behavior.

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
| `src/windows/input_mask.cpp`, native panel input region | Logical Regions are hit-tested with a published window DPR. Refresh that snapshot after remapping; regenerate scaled HWND regions too. An old scale/bounds pair can miss a display's right-edge OSD strip while accepting input elsewhere. |
| `WindowsHover.js`, `WindowsHoverRegions.qml`, drawer Interactions/Regions | Adjacency uses object identity, coordinates, logical dimensions and DPR, not monitor names. Geometry/DPR notification recalculates shared-edge strips; window resize and mask refresh align them with the new native bounds. No hover-width or visual-design change. |
| `src/windows/hyprland/monitor.cpp`, `hyprland/connection.cpp`, Hypr adapter | Monitor names/scales/geometry and IPC metadata refresh in place. Add/remove and registry topology changes coalesce into monitor reconciliation, input-hook cursor-rectangle invalidation and focused-monitor recomputation. `monitorFor()` prefers QScreen pointer identity; its name fallback already consumes ShellScreen's corrected name. Workspace-count config reads the corrected Hyprland monitor name. |
| `src/windows/window_tracker.cpp` | Its HMONITOR-to-QScreen map previously refreshed only on add/remove. Qt may replace HMONITOR without replacing QScreen. Rebuild the map and re-observe tracked windows on registry changes, keeping fullscreen/toplevel monitor associations current. |
| `src/windows/tiling.cpp`, `tiling_scope.cpp` | Screen selectors now use corrected names and are re-evaluated. Layout ownership remains desktop GUID plus live QScreen pointer; remove the obsolete friendly-name part so a rename cannot strand the previous layout tree. Geometry/DPI changes still trigger re-layout. |
| Windows brightness facade/service, native brightness/gamma | Native name lookup and route pruning use the shared resolver. Display changes cause the adapter to reconcile its name-keyed records even if the screens array is unchanged, then requery them. Unaffected records are preserved while a separate record is created for a new display. Gamma translates a public friendly name back to the current GDI source before CreateDC. Remaining factor/ramp cache lifetime work is listed below. |
| Desktop drop, Input screen enumeration, screenshots, screen recorder, brightness probe | All native screen-name publication/selection uses the same resolver, avoiding a mismatch between QML names and native selectors. |
| `src/windows/taskbar.cpp`, `appbar.cpp`, panel AppBars | Taskbar discovery uses HWNDs/HMONITORs, not friendly names. Registry changes now schedule its existing settled rediscovery. Panel AppBars are invalidated and reserved again against the current native monitor. |
| `windows/scripts/DesktopTakeover.cs` and desktop supervisor | Monitor work-area inspection and crash cleanup use native rectangles and owned HWND/PID records, not Qt screen labels. No persisted friendly-name identity to correct and no supervisor/taskbar ownership change is needed. |
| `src/windows/animation_timing.cpp`, native Displays service | Animation watches refresh-rate signals; Displays reads Windows display-config paths independently. Neither needs the Qt friendly name. |

### Remaining follow-ups, not fixed by this PR

- `src/windows/wayland/screencopy_view.cpp:206` resolves an HMONITOR when a
  capture starts and retains it in the capture context. An already-running
  capture does not rebind when the same QScreen's native monitor changes.
  Retained capture contexts need explicit invalidation/recreation on topology
  or target-path replacement, including same-model replacement.
- `src/windows/system/gamma.hpp` factor/ramp maps were fixed by : dimming
  factors, floors, saved originals and restoration obligations are keyed by the
  opaque target identity, not by the label, and `CreateDC` resolves through the
  live screen. A target that is gone is never handed to GDI; its ramp
  restoration remains owed but cannot be written to a replacement monitor.

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

## Display identity and QML names

The friendly monitor name is a label, not an identity. `DisplayIdentity` keeps
these separate concepts:

- `deviceName`: the current GDI source, e.g. `\\.\DISPLAY1`. Qt can reuse it
  for another physical monitor, so it is only used to join a QScreen to the
  current DisplayConfig/EnumDisplayDevices record.
- `stableId`: an interface path when either API supplies one
  (`DISPLAYCONFIG_DEVICE_INFO_GET_TARGET_NAME` with
  `DISPLAYCONFIG_DEVICE_INFO_GET_SOURCE_NAME`, or EnumDisplayDevices with
  `EDD_GET_DEVICE_INTERFACE_NAME`), written as `path:...`. This is the only
  persistent identity. If neither API supplies a path, the id is explicitly
  session-local: `session:<lifetime>:target:<LUID>:<target>` or
  `session:<lifetime>:source:<GDI source>`. It is opaque, never shown in QML and
  never logged raw; every log uses `logId()`.
- `friendlyName` and `uniqueName`: the display label and the QML-facing name.

### Persisted name reservations

The profile state dir holds `screen-names.json`. It maps each **persistent**
`stableId` to its assigned name plus optional legacy metadata. The key is the
unsalted SHA-256 of the id (`sha256:<hex>`), so the file never holds an
interface path; it is stable across runs, unlike the per-process `logId()`.
Entries written with a raw `path:` key are rewritten as hashes on first read.
Names are allocated once, on first discovery:

- the plain label if no reservation already owns it case-insensitively;
- otherwise the lowest free ` (2)`, ` (3)`... suffix.

Existing assignments are never renumbered, disconnected monitors stay in the
file for good, and the file is written atomically (`QSaveFile`, temp then
replace). There is no size cap and nothing is evicted: an entry is about 100
bytes, so even thousands of monitors stay small, and a name is therefore never
handed to a different monitor, or the settings stored under it. Each entry
records the date it was last seen, for diagnostics only. A user who already has
monitor A alone keeps `X` and its settings when identical monitor B is
connected; B gets `X (2)`. Removing B never renames A, and a restart reloads the
same assignments. A genuine label that ends in `(2)` is just a label; it is
reserved exactly like any other.

If the file exists but cannot be read or parsed, it is left untouched: the
registry runs on in-memory names for that session, never saves, and logs a fixed
message without the path.

Session-local ids never enter the reservation file and get a new lifetime token
when the QScreen is replaced or its target changes behind the same GDI source.
Their names are reserved in memory for as long as the session id survives, so
unplugging one of two identical session-only monitors never renames the other;
only a new session id is allocated a name, and it avoids every persistent name.

A screen's identity is resolved once, when it is discovered, from DisplayConfig
and EnumDisplayDevices together; the interface path of either source wins. There
are no live identity upgrades. If a session-only screen later gains a path (for
example in a remote session) the registry treats it as a removal followed by an
addition: it emits `identityRetired` for the old id, and the screen then appears
under its persistent id with a name allocated like any new monitor's. The same
signal is emitted, before anything is torn down, when a screen leaves the
topology, so every id is retired the same way.

`identityRetired` is emitted while the id still resolves to the live screen.
Gamma restores the saved original ramp at that point and then drops its state;
brightness drops its route, values, queued write, busy state and settle timer.
Each bumps a per-id lifetime counter, and any worker or native call that was
started under the old lifetime is dropped when it completes: a write reports
failure once, a probe reports the request as unavailable, a read-back publishes
nothing, and a gamma call that spans a retire never records a snapshot or
ownership (a write that was already running is put back). A monitor that comes
back with the same persistent id therefore starts clean and is never left busy
by work from before it left.

`ShellScreen.name` is the unique name. It stays name-shaped for upstream QML
that compares or displays `screen.name`, but native routing resolves it through
the registry rather than comparing labels. `displayConfigurationChanged` and
the global screen list still republish after identity changes.

### Consumer list

| Consumer | Key before | After |
| --- | --- | --- |
| `src/windows/system/brightness.cpp` route, last value, generation, in-flight, settle timers | friendly name | persistent `stableId`; everything is dropped when the id is retired (removal, or another identity) and in-flight completions of the old lifetime are discarded. Probes/drives still use the live QScreen's HMONITOR |
| `src/windows/system/gamma.cpp` backlight/dim factors, floors, saved ramps, restoration set | friendly name | `stableId`; `CreateDC` resolves the live GDI source, never an opaque id. On retire the saved ramp is restored first, then the state is dropped; native calls that span a retire abort |
| `src/windows/system/night_light.cpp` | friendly name pass-through | unique name resolved by gamma |
| `src/windows/system/screenshot.cpp`, `screen_recorder.cpp`, `input.cpp`, `desktop_drop.cpp`, `tools/brightness_probe.cpp` | friendly label selection/publication | unique name, resolved through the registry; no label scan |
| `src/windows/tiling.cpp` `screen:` selectors and `tiling_scope.cpp` | friendly name | unique name; layout ownership remains desktop GUID plus QScreen pointer |
| `src/windows/hyprland/monitor.cpp` Hypr monitor emulation and `Hypr.monitorFor` | friendly name | unique name; pointer identity is still preferred |
| `src/windows/panel_window.cpp`, `hyprland/connection.cpp` logs/notifications | friendly name | redacted `logId()` or a unique QML label only |
| Plugin `Config`, `Tokens`, `PersistentState`, `RuntimeState` per-screen layers (`monitors/<name>/shell.json`, `shell-tokens.json`, `state.json`) | friendly name directory | unique name directory; explicit reservation metadata can copy a legacy plain-label layer once |
| `services/Screens.qml`, `modules/background/Background.qml`, `WindowsBackground.qml` | `GlobalConfig.forScreen(screen.name)` | same call with the unique name |
| `components/containers/StyledWindow.qml`, Nexus `WindowFactory.qml`, `LockSurface.qml` | `Config.screen: screen.name` | same, unique name selects its own layer |
| `modules/bar/BarWrapper.qml` `bar.excludedScreens` | regex against the label | regex against the unique name; an unanchored legacy label regex still matches both `Label` and `Label (2)` |
| `windows/shell/shell.json` `windows.tiling.monitors` and `include`/`exclude` `screen:` selectors | monitor label | unique name; see the exact-match rule below |
| `windows/services/brightness/*`, OSD `brightnessFeedback`, IPC `shell.panel(screenName, ...)`, Hypr monitor names | friendly name | unique name; the backend resolves it to the target |
| Wallpaper and background per-screen enablement/clock/wallpaper settings | `Config`/`Tokens` layer by name | unique name layer, with the legacy copy above |
| `windows/shell/shell.qml` `State`/`backgroundScreens` diagnostics | label | unique name (label with a suffix only on collision) |

### Tiling screen selectors are exact

`ScopeRules::compile()` uses `NonPathWildcardConversion`, so the generated
regular expression is anchored. `screen:Generic Monitor` matches **only** the
plain name; it does not match `Generic Monitor (2)`. To target a suffixed
monitor, write its exact unique name, e.g. `screen:Generic Monitor (2)`. To
target both, use a wildcard, e.g. `screen:Generic Monitor*`. The same applies to
`windows.tiling.monitors` keys, which are converted to `screen:<key>` patterns:
a legacy `Generic Monitor` key excludes only the monitor that owns the plain
name, not its suffixed sibling. Bar `excludedScreens` is a regex, so its
patterns are unanchored unless the user adds `^`/`$`.

### Legacy migration is metadata-driven

When the backend allocates a generated suffix for the first time and
`monitors/<plain label>/` already exists, the reservation records
`legacyLabel: <plain label>`. There is no string inference: a genuine label such
as `Other Monitor (2)` never triggers a copy.

The plugin's `LayerRegistry` reads that reservation by name, copies the legacy
file once, and records the completed layer in `legacyCopied` in the
reservation. A layer is identified by its storage area and file, not the file
name alone: `config/shell.json`, `config/shell-tokens.json`,
`state/persistent/state.json` and `state/runtime/state.json`, so copying one
never stops another from migrating. The old directory is never moved, rewritten
or deleted. A deleted destination is not recopied, because completion is
recorded independently of the destination.

Copy and record are one step. The record is opened for writing before the copy
and committed after it. If the commit fails, the copied file stays and the
failure is remembered for the session, so the copy is not repeated; an unreadable
record is never overwritten. Failures are logged as a count only. The logic is
inert outside Windows and without reservation metadata.

A legacy `monitors/<plain label>/` directory was shared by every monitor with
that label; it cannot reveal which physical monitor owned the settings. The copy
is a convenience so existing settings are not lost, not recovered ownership. Both
screens may start with the same settings and then diverge.

## Validation

Keep the backend gitlink and `windows/sources.lock.json` paired and run
`windows/scripts/Test-Environment.ps1 -Json` after pin changes.
Build and offscreen smoke cannot validate DWM placement, native pointer routing,
physical monitor power-cycling or Explorer work areas.

On an explicitly authorized installed build, record State, monitor layout,
logical bounds and DPR. Power-cycle or reconnect one display while the shell
remains running, without restarting between the cycle and these checks:

1. Query the installed launcher's `-Command State`. Screen identities, logical
   bounds and DPR must match the current Windows display configuration.
2. Approach each shared edge at OSD height. Check openings before crossing to
   the adjacent display, usable controls, closing after leaving and pass-through
   outside the trigger region.
3. Open each bottom-right utilities panel. Check that the complete panel is
   inside that display's bounds, with no clipping and clickable edges.
4. Confirm unaffected displays retain their names, scale, bar/borders, OSD
   hover, utilities placement and normal tiling/work areas.
5. Include same-model replacement, a position swap without removal,
   negative origins, resize and DPR-only changes where hardware permits.

Record exact revisions and before/after results outside the checkout. Crop
evidence to the behavior and exclude personal data; untested hardware is not a pass.
