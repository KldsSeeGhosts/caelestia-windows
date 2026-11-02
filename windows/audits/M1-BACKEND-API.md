# M1 backend API audit

Date: 2026-10-25. Static source inspection only. No application, build, desktop
test, authentication change, backend edit, pin update, commit, or push was
performed for this audit.

Inspected checkout: `windows/m1-bar-drawer`, initially
`d83e065a4df4405678dfd8115062dd56211ddef4`. Quickshell gitlink and
`windows/sources.lock.json` both identify
`e8ae0ef124b1c14b547c80d00422d2ffbd423d81`. Original Caelestia baseline:
`2e1c51fa76d94457624b642c678218970aa2517a`. References below are repository
paths and 1-based source lines at inspection time. Backend paths are prefixed
with `windows/deps/quickshell/`.

Read the repository/global AGENTS instructions, `windows/README.md`, and
`windows/ROADMAP.md`. Parent owns implementation, runtime validation, and
Linear.

## Findings that block an unchanged original drawer

1. **An attached property is missing.** `ContentWindow.qml:69` assigns
   `WlrLayershell.exclusionMode`. The Windows attached object exposes only
   `layer`, `namespace`, and `keyboardFocus`
   (`src/windows/wayland/wlr_layershell.hpp:42-50`). The direct
   `PanelWindow.exclusionMode` property exists
   (`src/window/panelinterface.hpp:111-116`,
   `src/windows/panel_window.hpp:82-87`). Use the direct property in a narrow
   Windows adaptation. This is a source-level QML load blocker, not a runtime
   result. Linux's attached object does expose it
   (`src/wayland/wlr_layershell/wlr_layershell.hpp:110-115`).
2. **Do not instantiate the original outer `Drawers` for the isolated probe.**
   `modules/drawers/Drawers.qml:15-18` creates `Exclusions` alongside content.
   `Exclusions.qml:15-38` creates four `StyledWindow`s with positive
   `exclusiveZone` values. The Windows backend maps these to actual AppBar
   work-area reservations (`src/windows/panel_window.cpp:835-876`).
   A transparent/empty input mask does not prevent reservation.
3. **Focus grab is an observer plus activation attempt, not full Hyprland
   focus semantics.** Required member names match, but there is no Escape
   handling or stored previous foreground HWND in `FocusGrab`
   (`src/windows/focus_grab.hpp:21-45,57-62`,
   `src/windows/focus_grab.cpp:218-273`). The original persistent content
   window stays visible while a drawer closes, so hiding a drawer item does
   not invoke the panel's native close/focus handoff path.
4. **The original content graph is wider than one drawer.**
   `ContentWindow.qml:251-310` instantiates `Interactions`, `Panels`, and the
   original `BarWrapper`. `Panels.qml:41-154` eagerly creates all wrapper
   objects, including notifications, OSD, launcher, session, utilities,
   sidebar, popouts, and toasts. A false enabled flag or a hidden item does not
   prove these wrapper objects and their imports are inert. Preserve the
   visual components, but gate unsupported creation at a platform boundary.
5. **Native `PanelWindow` is not inert even with reservation disabled.**
   It becomes a tool/topmost window, initializes virtual desktop support,
   tries to pin its own HWND to all desktops, and routes masks through a
   process-wide low-level mouse hook. There is no panel property in this pin
   to disable its desktop pinning. Details below constrain what can honestly
   be claimed without a backend change.

## Exact original API use and Windows match

### StyledWindow

`components/containers/StyledWindow.qml:1-15` imports `Quickshell` and
`Quickshell.Wayland`, derives `PanelWindow`, sets
`WlrLayershell.namespace: caelestia-${name}`, sets transparent color, and
assigns `contentItem.Config.screen` / `contentItem.Tokens.screen` from
`screen.name`.

The Windows plugin registers `WinPanelInterface` as `PanelWindow` through
`Quickshell._WindowsOverlay` and imports that module into `Quickshell`
(`src/windows/init.cpp:184-197`). The attached namespace forwards to
`WinPanelWindow::setNamespace`
(`src/windows/wayland/wlr_layershell.cpp:31-32,42-55`).
`PanelWindow` anchors, margins, exclusion mode/zone and focusable exist on the
shared interface (`src/window/panelinterface.hpp:105-124`) and Windows proxy.
No missing namespace member was found. The Caelestia Config/Tokens attached
properties are project plugin contracts, not part of the Windows shim.

Namespace is not just an identifier: Windows layer/animation rules look up
the namespace (`src/windows/panel_window.cpp:1504-1516`); desktop embedding
also checks namespace lists (`:980-981`). Keep the test's rule source
isolated and avoid importing ii-windows policy.

### ContentWindow

All references here are in `modules/drawers/ContentWindow.qml`.

- Lines 22-36: `ShellState.forScreen(screen)`, typed `HyprlandMonitor`,
  `Hypr.monitorFor(screen)`, `monitor.lastIpcObject.specialWorkspace.name`,
  `monitor.activeWorkspace.toplevels.values`,
  `Hypr.workspaces.values`, and each toplevel's
  `lastIpcObject.fullscreen > 1`. Windows exposes the required monitor/workspace
  properties (`src/windows/hyprland/monitor.hpp:20-32`,
  `workspace.hpp:20-32`) and singleton `monitorFor` / model properties
  (`qml.hpp:21-39`). Special workspace is always synthesized as an empty name
  (`monitor.cpp:89`). Fullscreen is `2` for a detected fullscreen window,
  `1` for maximized, else `0` (`hyprland_toplevel.cpp:213-240`). These names
  therefore match, but special workspaces are not implemented by this data.
- Lines 47-59: `dragMaskPadding` depends on focus grab, popout detachment,
  special workspace and workspace toplevel count. A null monitor is treated
  like an empty desktop, enlarging the edge capture strips by configured drag
  thresholds. This matters if an M1 service adapter returns null. Choose
  padding explicitly in the Windows host; do not let missing compositor data
  expand the interactive area accidentally. If every tested panel is disabled,
  `Math.max(...[])` also needs a finite zero fallback.
- Lines 68-79: drawer namespace, unsupported attached `exclusionMode`,
  `WlrLayershell.layer` Top/Overlay, `keyboardFocus` OnDemand only for
  launcher/session, `None` otherwise, `mask`, and four edge anchors.
  Layer/focus enum values match
  (`src/windows/wayland/wlr_layershell.hpp:15-38`) and forward to the Windows
  panel (`wlr_layershell.cpp:23-39`). Top and Overlay are Windows stacking
  policies, not compositor layers. Top lowers when the panel stack marks a
  fullscreen application active; Overlay stays topmost
  (`panel_window.cpp:929-963`). Layer import parity does not validate
  fullscreen behavior across monitors.
- Lines 88-110: the misleadingly named `emptyRegion` includes notification
  and OSD rectangles; it is not necessarily empty. Normal mode uses the
  original `Regions` object.
- Lines 112-135: `HyprlandFocusGrab.active`, `.windows: [root]`, and
  `onCleared` match the compatibility QML wrapper
  (`src/windows/hyprland/qml/HyprlandFocusGrab.qml:1-3`) and native FocusGrab
  members (`focus_grab.hpp:21-45`). Activation conditions include sidebar,
  non-hover dashboard, launcher/session, and nested tray menus. Clearing
  closes all four major drawers and tray/popouts. A dashboard/sidebar grab
  still runs while the window has `keyboardFocus.None`.
- Lines 251-310: actual interactions, panel wrappers, and original bar are
  nested in the same content window. Lines 313-335 register root, interaction
  wrapper, bar, and panels with `ShellState.ComponentRef`; an isolated host
  must retain the registrations or replace their consumers intentionally.

### Drawers and screen geometry

`modules/drawers/Drawers.qml:7-24` uses `Variants`, `Screens.screens`, required
`ShellScreen modelData`, and assigns it to Exclusions and ContentWindow.
For M1 select one explicit existing `Quickshell.screens` entry and pass that
same object to host, bar, drawer, state and interactions. Do not load the
original Screens/Hypr service graph merely to select one screen.

Panel placement uses Qt logical screen geometry plus native monitor/work-area
rectangles through an origin-aware `ScreenMapper`
(`src/windows/panel_window.cpp:818-833,881-920`,
`src/windows/util.cpp:59-90`). Ignore mode uses whole screen geometry;
Normal with a negative zone also ignores zones; otherwise it uses the
Windows work area. Four anchors expand to the selected base rectangle.
Geometry and DPI changes are watched (`panel_window.cpp:763-780`).

The Hyprland-compatible monitor mixes logical `x/y` with physical width/height
and a DPR scale (`src/windows/hyprland/monitor.cpp:37-49`); do not use its
dimensions as a substitute for a ShellScreen's logical dimensions. Negative
origins and mixed DPI have implementation support, not validation evidence.
Set an explicit screen: an unassigned panel can follow the cursor/focused
screen on first show (`panel_window.cpp:621-624,642-656`).

### Interactions and input regions

`modules/drawers/Interactions.qml` contains the actual hover/drag policy.
It is a `CustomMouseArea`, which derives Qt `MouseArea`
(`components/controls/CustomMouseArea.qml:1-20`), not a Hyprland gesture API.
Required typed contracts are `ShellScreen`, `BarPopouts.Wrapper`,
`ScreenState`, local `Panels`, and `Bar.BarWrapper` (lines 13-19).
Those types constrain replacement objects: a plain anonymous Item cannot
substitute for every required property.

- Lines 27-52 calculate panel hit tests in local coordinates using bar width,
  border thickness/rounding, panel x/y/size and animated `offsetScale`.
- Lines 55-67 route bar wheel events, set `anchors.fill`, use `Qt.AllButtons`
  except fullscreen, enable hover, and capture drag origin.
- Lines 68-92 close hover panels/popouts on pointer leave, respecting shortcut
  flags.
- Lines 109-119 show the bar on hover and toggle its state by drag.
- Lines 174-200 handle session/sidebar drags and sidebar hover.
- Lines 203-231 open launcher/dashboard on hover or drag. Dashboard hover is
  explicitly configurable. Lines 233-249 handle utilities/popouts.
- Lines 253-328 maintain shortcut-to-hover transitions.

There is no Escape key handler in this file or in ContentWindow. Original
Escape behavior is local to launcher/session content
(`modules/launcher/Content.qml:87`,
`modules/session/Content.qml:108`). A dashboard-only prototype must add a
host-level close command if Escape is part of its acceptance case.
Qt key handling requires an active focusable window; an Item's focus flag
does not override a native no-focus window.

`modules/drawers/Regions.qml:18-22` defines a central rectangle with Xor.
Its nested panel rectangles use Subtract (`:24-82`). This is intentional:
core mask calculation begins with the full window rectangle for a non-Combine
root, builds the central region minus drawer rectangles, then XORs that with
the full rectangle (`src/core/region.cpp:226-250`,
`src/window/proxywindow.cpp:687-694`). The result is edge strips plus visible
panels, not a fullscreen input region. Preserve Xor/Subtract semantics and
animated mask updates; do not replace the mask with an opaque full-window
MouseArea to obtain outside clicks.

Windows clips the requested mask to window bounds
(`src/windows/panel_window.cpp:1322-1351`). For an ordinary top-layer panel,
it registers the mask with `InputMaskTracker`
(`:1147-1159`). This tracks cursor position, converts physical coordinates
relative to the native window origin by DPR, and toggles the whole HWND's
`WS_EX_TRANSPARENT` bit depending on whether the pointer is in the region
(`src/windows/input_mask.cpp:64-71,368-402`). Native `SetWindowRgn` is used
only for the embedded-above-icons case (`panel_window.cpp:1162-1181`).
This is a semantic gap from a compositor-owned input region: fast boundary
crossings and clicks, captures, hover leave/enter, rounding and mixed DPI need
runtime checks. The mouse hook posts evaluation to the GUI thread
(`input_mask.cpp:511-540`), so source inspection cannot establish race-free
click routing.

Masks start a `WH_MOUSE_LL` hook; failure falls back to 16 ms cursor polling
and cannot observe outside button presses
(`input_mask.cpp:194-195,293-299,410-435,465-491`).
An explicitly empty `Region {}` makes a panel mouse-transparent
(`:389-392`); an omitted/null mask removes routing and must not be used on a
screen-sized host. Keep the mask established before first visibility.

## Focus, dismissal and return

2026-10-25 input-gate addendum: the current pin `84604c25` in
`KldsSeeGhosts/caelestia-quickshell-windows` retains this audited baseline and
changes only `src/windows/input_mask.cpp`. Native input reproduced missed
stationary re-entry after rapid mask crossings. The hook's GUI-thread
evaluation runs after Windows can route the triggering movement to the
underlying application. The patch queues a deferred Qt enter on transparent
to interactive transition, guarded by the unchanged physical pointer,
native surface identity, current hit window, transparency and mouse buttons.
It delivers leave when routing becomes transparent. It sends no system input,
clicks, focus requests or extra hook, and changes no tiling policy. Original
Interactions also opens the configured hover bar on enter at unchanged
coordinates. The native input runner covers the resulting behavior at both
monitor DPIs. Earlier archived results continue to describe their own pins.

Qt's relevant implementation is
[processMouseEvent](https://github.com/qt/qtbase/blob/v6.11.2/src/gui/kernel/qguiapplication.cpp)
(filters unchanged-position moves) and
[QQuickDeliveryAgent](https://github.com/qt/qtdeclarative/blob/v6.11.2/src/quick/util/qquickdeliveryagent.cpp)
(enter delivers hover; leave clears it).

`keyboardFocus.None` sets `Qt::WindowDoesNotAcceptFocus` when the backing
window is connected (`src/windows/panel_window.cpp:501-505`).
`focusable: true` maps to OnDemand (`:663-668`). Updating to None can be
deferred one event-loop turn (`:1240-1264`).

OnDemand permits focus. It does not itself request activation when switched
on for an already-visible panel (`:1222-1235`). Showing a focusable panel
schedules focus on exposure (`:744-752,1267-1301`). Exclusive can additionally
retake focus after 50 ms (`:1304-1318`); avoid it for this isolated prototype.
The focus helper can call `forceForegroundWindow`, so enabling focus grab
should be tied to explicit drawer interaction, not general shell startup.

FocusGrab:

- Resolves listed objects using `ProxyWindowBase::forObject`, watches their
  visibility/window changes, and checks native owner chains
  (`src/windows/focus_grab.cpp:124-215`).
- Starts watching outside button events when active; `WindowFromPoint` and
  owner membership determine whether it clears
  (`:31-83`). Clicking outside is observed, not swallowed by FocusGrab
  (`src/windows/input_mask.cpp:525-540`).
- Clears on another process becoming foreground after a 500 ms grace period;
  ignores null and own-process foreground windows (`focus_grab.cpp:29,86-99`).
  Same-process focus changes therefore do not give a general dismissal signal.
- Skips activation for windows with `WindowDoesNotAcceptFocus` or
  `WS_EX_NOACTIVATE` (`:256-272`). A no-focus dashboard can get outside-click
  dismissal but will not receive Escape through this grab.
- Deactivation/clear only unregister watching and emit state/signals
  (`:235-254`). There is no previous foreground save/restore.

The panel has a separate handoff on **animated native window close**:
`beginClose` calls `releaseForegroundForClose`
(`src/windows/panel_window.cpp:1863`). It chooses the next activatable window
in Z order, falling back to the shell, not the actual previous window
(`:154-174,1959-1968`). Non-animated hiding bypasses that path
(`:595-611`). ContentWindow ordinarily remains visible while an Item drawer
animates closed, so neither route establishes required focus return.

Implement a small Windows host focus policy: retain a valid external HWND
before deliberate activation; request OnDemand focus only when appropriate;
on Escape close state and release focus; restore only if the probe still owns
foreground, the saved HWND remains valid/visible and the user has not already
selected another app. Never restore over an outside-click target or Alt-Tab.
The pinned QML FocusGrab API alone cannot implement exact HWND restoration.
If no narrow native helper is in scope yet, record this as an unresolved M1
gate rather than claim Windows automatically returns focus correctly.

A partial QML route exists if native tracking is deliberately enabled:
`HyprlandToplevel.wayland` exposes a Windows `Toplevel` with `activate()`
(`src/windows/hyprland/hyprland_toplevel.hpp:24`,
`src/windows/wayland/toplevel.hpp:37`). Saving a live object before activation
can identify a candidate to restore. It does not replace checking current
foreground ownership or handling a destroyed target, and enables the tracking
side effects described below. Prefer this only if those data services are
already part of the audited slice; do not enable them just for an unguarded
restore call.

## Native side effects and globals to avoid

- A panel sets `Qt::Tool | FramelessWindowHint`, topmost for Top/Overlay, and
  native `WS_EX_TOOLWINDOW` (`src/windows/panel_window.cpp:501-508,691-703`).
  This affects its own taskbar/Alt-Tab representation. It is separate from
  modifying Explorer taskbar settings.
- Panel connection instantiates `VirtualDesktops`; showing calls
  `stickToAllDesktops`, which can move its own HWND to the current desktop and
  pin it to all desktops (`:483-489,675-681,706-751`).
  VirtualDesktops initializes COM, reads desktop state, loads its accessor
  after startup and watches registry state
  (`src/windows/virtual_desktops.cpp:187-215`). There is no opt-out panel
  property among `panel_window.hpp:82-87`. A requirement for zero virtual
  desktop effects rules out this native panel path at the current pin.
- Desktop embedding is opt-in: `DesktopHost.mEnabled` defaults false
  (`src/windows/desktop_host.hpp:67`); the panel's embedding condition also
  requires Bottom/Background, no focus and no reservation
  (`panel_window.cpp:975-977`). Do not instantiate/configure DesktopLayer.
- Tiling defaults disabled (`src/windows/tiling.hpp:245`) and requires
  `setEnabled(true)` to start management (`tiling.cpp:259-272`). However,
  **merely constructing Tiling creates its manager and calls `rescueParked`**
  (`:237-257,2183-2184`). Avoid the singleton entirely, including a reassuring
  `Tiling.enabled: false` binding. `HyprlandToplevel` only checks
  `TilingManager::active()`, which does not instantiate it
  (`hyprland_toplevel.cpp:215`, `tiling.cpp:233-234`).
- Avoid Taskbar entirely. Its manager defaults disabled
  (`src/windows/taskbar.hpp:70-71`), but construction schedules stale
  auto-hide cleanup, which can change taskbar auto-hide if an ownership marker
  is present (`taskbar.cpp:196-198,234-242`). `turnOffAutoHide` explicitly
  changes settings (`:216-227`).
- Windows plugin initialization unconditionally calls
  `WinAppBar::removeStale` (`src/windows/init.cpp:171-173`), which can remove
  stale Quickshell AppBar registrations and registry entries
  (`src/windows/appbar.cpp:57-100`). A QML-only boundary cannot suppress this.
  It skips a live HWND whose PID matches. Do not claim the executable has
  absolutely no global bookkeeping effects.
- Native blur/animation infrastructure is constructed by PanelBlur
  (`src/windows/blur.cpp:1295-1296`). It watches system transparency state and
  reads shell-specific rules (`:878-902,1183-1254`).
  `QS_WINDOWS_BLUR=0` disables backend blur (`:879-885`); it does not by itself
  disable the separate panel-animation flag
  (`src/windows/blur.hpp:123-124`). Stage no inherited layer rules. Original
  Caelestia animations should drive the visuals.
- Using the Windows `Hyprland` singleton starts native window tracking,
  virtual-desktop data and global mouse button/monitor observation
  (`src/windows/hyprland/connection.cpp:112-171`). WindowTracker starts an
  event thread and deferred window scan (`window_tracker.cpp:483-526`).
  This is not enabling the tiler, but is more than a pure screen data query.
- Do not import original `services/Hypr.qml` as the M1 platform service. It
  imports excluded `Caelestia.Services`, uses `HyprKeyboard`/`HyprExtras`,
  installs dynamic bindings on completion, reads XKB Linux paths and exposes
  dispatch (`services/Hypr.qml:8,27,43-44,112-121,162-165,212-224`).
  Its monitor/model-shaped read API is much smaller than that startup graph.
- Do not run upstream `shell.qml`. It eagerly touches Notifs, Players,
  Brightness, Weather, optional VPN, and creates Background, Drawers, lock,
  area picker and daemons (`shell.qml:23-31,48-63`).

## Smallest safe platform boundary

Recommended first implementation is an **explicit bounded ordinary-window
host** in the isolated Windows stage, using the real
`modules/bar/BarWrapper.qml` / `Bar.qml` and one original drawer
Wrapper/Content. This preserves their existing layout, state and motion while
testing the service/import boundary without a screen-sized native panel.
It proves original bar/drawer loading, not native panel compatibility.

Keep platform-specific changes at the host and dependency construction
boundaries:

1. Select one ShellScreen explicitly; use isolated Config/State/runtime paths,
   fixed theme, audited unavailable service contracts and no global shortcuts.
   A read-only Hypr-shaped M1 adapter can return a typed null monitor and empty
   models; separately force finite/zero drag mask padding in that mode.
2. Retain the original bar/wrapper and drawer visuals. If choosing dashboard,
   audit/disable its face picker action: `modules/dashboard/Wrapper.qml:16-27`
   otherwise copies into the user's home and invokes `notify-send`.
   A launcher has built-in Escape but brings application/process actions; a
   session drawer has session actions. Neither is automatically a smaller
   safe service surface.
3. For the complete original Interactions object, retain its typed contracts.
   Use a staged narrow `Panels` variant that preserves aliases/geometry
   contracts but only instantiates the selected audited drawer; unsupported
   wrappers must not be created. Do not rely solely on `visible: false`.
   Alternatively extract the original content subtree with a documented
   platform host split. Do not create lookalike visual replacements.
4. The bounded host can handle Escape locally without a global keyboard hook.
   Preserve configurable original hover and drag policy in the retained
   interactions. Do not call its content load alone a full ContentWindow pass.
5. For a subsequent native panel pass, adapt the single unsupported attached
   exclusion assignment to direct `exclusionMode: ExclusionMode.Ignore`;
   skip `Drawers`/`Exclusions`; establish a sparse, bounded Region before
   showing; keep None at rest and use OnDemand only for keyboard interaction.
   Retain original Region algebra. No transparent fullscreen click catcher.
6. Native outside-click handling can use FocusGrab's observer, with the
   hook/failure limitations above. Add the narrow focus-return helper before
   claiming the keyboard gate. If pinning or executable startup cleanup is
   unacceptable for the isolated acceptance run, keep the bounded host and
   report that a separately reviewed backend opt-out is required. Do not
   silently update the pin or disable an existing tiler to work around it.

## Required later evidence, not claims of this audit

Record native source/runtime revisions, exact invocation, disabled features,
logs/screenshots and before/after taskbar/work-area state. Verify:

- No required import/property/type warnings; actual original bar and drawer
  content render, not only a wrapper with an inactive Loader.
- Configurable hover entry, transfer between bar/drawer, leave and drag work.
- Center holes pass clicks/wheel to existing applications, including a rapid
  edge crossing and click; only intended strips/drawer regions intercept.
- Outside click closes while the target application receives its click;
  same-process and owned popup behavior is understood.
- Escape closes keyboard-active content; hover opening does not steal focus;
  deliberate keyboard activation and focus return work; Alt-Tab/outside click
  never gets undone by restoration.
- Native 150%/175%, negative origins, monitor removal/transfer, transparency
  disabled, and animation mask changes preserve hit regions.
- Work area, Explorer taskbar mode, active tiler, application sessions and
  autostart remain unchanged after startup/shutdown. Account for backend
  bookkeeping and own-window virtual desktop behavior separately.

No environment report was rerun because this task changed neither dependency
pins nor setup instructions. No runtime success is inferred from source parity.
