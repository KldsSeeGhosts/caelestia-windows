# Combined read-only prototype

This entry point shows the port as one thing: the original Caelestia bar and
its drawers and popouts in the bounded M1 window, with every reviewed M2
Windows service plugged in at once. It stages the M1 bar/session manifest plus
all nine service slice manifests and swaps the M1 "unavailable" adapters for
the original upstream components wherever a reviewed Windows facade exists.

Everything is read-only. The launcher sets every service's observation env var
on and every control/write env var off: no volume, brightness, power-profile,
network, bluetooth or media-control writes, no app launches, no tray
activation, no notification mirroring, no session dispatch, no tiling and no
Hypr dispatch. The window keeps the M1 bounds (at most 900x620, inset 80), the
isolated profile, `-ScreenIndex`, `-Smoke` and `-Wait`.

## Live (read-only) components

- Bar: original `StatusIcons` (audio, network, bluetooth, battery icons),
  original `Tray` (facade-wired; empty because the backend tray hook stays
  off), original `OsIcon` (Caelestia vector logo; click toggles the launcher),
  original `Clock` and `Power` from M1.
- Popouts: the original `popouts/Content` loader with the original audio,
  network, bluetooth and battery popouts, each staged behind a thin combined
  adapter that applies exactly the read-only hook wiring the corresponding
  bounded slice validated.
- Session drawer (M1): observation only, empty command lists, every action
  consumed and disabled.
- OSD: the original `osd/Wrapper` with the brightness row read-only (the
  original component hides the volume rows rather than rendering a disabled
  slider, and audio controls are never enabled here).
- Notifications: the original popup list with the local delivery opt-in.
  Mirroring, Windows dismissal and app-open are forced off.
- Launcher: the original `AppList` + `SearchBar` exactly as the apps slice
  stages them (`appsOnly`), in a wrapper that keeps the original open/close
  geometry. Hover the bottom edge or click the logo.
- Dashboard: a wrapper that keeps the original geometry and hosts the original
  media `Details` panel read-only. Hover the top edge.

## Still unavailable, and why

- `Workspaces` and `ActiveWindow` (bar and popout): no reviewed Windows Hypr
  facade exists. The M1 unavailable adapters stay; the popout files are staged
  inert because the original popouts loader references their types.
- Sidebar, utilities, toasts, dashboard tabs other than media, wallpapers,
  calculator and scheme launcher rows, dynamic themes: no reviewed facade.
- Tray contents: `QS_WINDOWS_TRAY_HOOK=0` keeps the backend from enumerating
  items, so the tray renders truthfully empty; activation and the native
  context menu are separate opt-ins that stay off.
- Session actions: consumed, disabled, never dispatched.

## Adapter conflicts resolved

Every service slice manifest was unioned onto the M1 base manifest. The same
staged path was provided by more than one manifest in the following cases:

- `services/Battery.qml`, `services/Bluetooth.qml`, `services/Tray.qml` —
  the slice facades are singletons whose names collide with the original
  component types (`Battery`, `Bluetooth` popouts in the original popouts
  loader, the `Tray` bar entry) once everything is staged in one shell: QML
  resolves the plain name to the singleton, which is not creatable. The
  bounded slices avoided this with namespaced instantiation; the original
  `Bar.qml` and `popouts/Content.qml` instantiate the types plainly.
  Resolution: the three facades are staged as `WindowsBattery.qml`,
  `WindowsBluetooth.qml` and `WindowsTray.qml` in the combined stage (the
  facade files themselves are unchanged), and the combined adapters reference
  them under those names.
- `modules/bar/components/Tray.qml` — base unavailable adapter vs the tray
  slice's original. Resolution: neither is staged at that path. The original
  is staged as `TrayContent.qml` and a combined adapter at `Tray.qml` applies
  the tray slice's facade wiring (`sourceItems`, interactions and native
  menus off), because the original Bar instantiates the entry without hook
  arguments and its defaults would read the native SystemTray model directly
  with interactions enabled.
- `modules/bar/components/status/BatteryStatus.qml`,
  `modules/bar/popouts/Battery.qml`, `AudioPopout.qml`, `Network.qml`,
  `Bluetooth.qml`, `modules/osd/Content.qml` — same pattern: the slice
  originals are staged under `*Content.qml`/`OsdContent.qml` names and thin
  combined adapters at the original paths apply each slice's reviewed
  read-only hook wiring, because the original popouts loader and OSD wrapper
  instantiate them without hook arguments.
- `components/effects/ColouredIcon.qml` — the notifications slice stages a
  lightness-only adapter (its README predates `Caelestia.Images` being kept in
  the portable build); the tray slice stages the original with real dominant-
  colour analysis. Resolution: the tray slice's original is kept; the
  notifications adapter is not staged for combined.
- `services/Hypr.qml` — the M1 unavailable contract lacks the `capsLock`,
  `numLock`, `kbLayout` and `activeToplevel` members the original StatusIcons,
  LockStatus and popout types reference. Resolution: a merged combined adapter
  keeps the M1 contract and adds those members as inert values.
- `modules/bar/popouts/Wrapper.qml` — the base adapter is fully nonvisual. For
  combined it is replaced by an adapter derived from the upstream wrapper that
  keeps the original popout state, content loader and animation and removes
  only the detached winfo/nexus overlays and the Wayland focus grab, which
  have no Windows facade.
- `modules/drawers/Panels.qml` — the base adapter keeps every panel
  unavailable. The combined adapter follows the upstream file and
  instantiates the original OSD, notifications, session, launcher and
  dashboard wrappers, with `UnavailablePanel` kept for utilities, toasts and
  the sidebar.
- `modules/utilities/Wrapper.qml` — the notifications slice's inert cast
  adapter is reused unchanged; the original notifications content casts the
  utilities panel to that type.
- Identical-source duplicates (`PopoutState.qml`, `StyledSlider.qml`,
  `TextButton.qml`, `IconTextButton.qml`, `CircularIndicator.qml`,
  `CircularProgress.qml`, `Icons.qml`, `AnchorAnim.qml`, `Elevation.qml`,
  `Colouriser.qml`, `StyledListView.qml`, `StyledScrollBar.qml`, the audio
  facade files staged by both the audio and brightness slices) map the same
  source bytes; the later staging is a no-op.

## Build and launch

Build with [NATIVE-BUILD.md](../NATIVE-BUILD.md); the shared backend and
plugin build is reused unchanged. From the repository root:

```powershell
$qtPrefix = "$env:LOCALAPPDATA\caelestia-dev\Qt\6.11.2\msvc2022_64"
powershell -NoProfile -File windows/scripts/Start-ShellPrototype.ps1 `
    -QtPrefix $qtPrefix -Combined -Wait -ScaleFactor native -ScreenIndex 0
```

Hover the left edge for the bar; hover a status icon for its popout; the power
button opens the session drawer; hover the bottom edge (or click the logo) for
the launcher; hover the top edge for the media panel. Escape closes the
session drawer. `prototype.quit` IPC stops the exact instance. A local test
notification can be posted through the facade with the `prototype.notify` IPC
method.

Smoke (`-Combined -Smoke`) sets the no-input boundary, verifies the read-only
service boundary, loads every plugged-in component, exercises each popout, the
OSD, the launcher, the media panel and a local notification, captures one
screenshot per phase, prints one `CAELESTIA_COMBINED_SERVICE name=<x> ...`
line per service and exits. See
[validation/2026-10-26-combined-prototype/](../validation/2026-10-26-combined-prototype/README.md)
for recorded evidence.

## Limits

- The bar logo's click toggles the launcher through `ShellState.forActive()`,
  which resolves the first screen state while no Hypr monitor identity exists;
  on a secondary screen use bottom-edge hover instead.
- The audio popout's device selection and settings button, the network
  password dialog, bluetooth pairing and the profile selector render in their
  original disabled/read-only styling; nothing is dispatched.
- This is still the bounded M1 window, not a desktop takeover: no AppBar, no
  exclusion of other windows, no autostart, and the ksg-shell is untouched.
