# Combined shell prototype

The bounded Windows host stages the original Caelestia bar, dashboard, launcher,
utilities, notification history, popups and toasts over the reviewed facades in
`windows/services`. Configuration and state stay in the isolated combined profile.

## Launch

```powershell
powershell -NoProfile -File windows/scripts/Start-ShellPrototype.ps1 `
    -QtPrefix "$env:LOCALAPPDATA\caelestia-dev\Qt\6.11.2\msvc2022_64" `
    -BuildRoot D:\AiStack\caelestia-windows\windows\.local\build -Combined -Live
```

Omit `-Live` for read-only observation. The control window labels the mode and
provides panel buttons, screen selection, wallpaper selection and preview exit.
Hover the top edge for the dashboard, bottom edge for the launcher, and right
edge for notification history. The logo also opens the launcher. Full screen is
an explicit control-window toggle; it does not reserve work area or start tiling.

`-Live` enables the existing audio, hardware brightness, media, Wi-Fi, Bluetooth,
power-profile, app-launch, tray activation and session action gates. It also
enables the tray hook. Notification mirroring, Windows dismissal and app-open
are permitted, but listener access is requested only by the history panel's
explicit button. No access request happens at startup. Destructive session
buttons create a pending request; Confirm/Cancel appear in the control window.
Commands remain confined to the session adapter allowlist.

`-Combined -Smoke` and `-Combined -Live -Smoke` both suppress native writes,
launches, session dispatch, tray interception and notification mirroring. They
load all dashboard tabs, utilities, history, the launcher, status popouts,
notifications and a toast, and exit. The supplied build is reused unchanged.

## Available components

- Original bar logo, clock, tray, status icons, popouts, session drawer and OSD.
- Material 3 Expressive shapes: the original `M3Shapes.MaterialShape` item from
  the pinned `windows/deps/m3shapes` plugin supplies ambient media background
  shapes, cover-art masking, expressive loading indicators and morph animations.
  No round-surface substitute remains. Windows resolves `m3shapesplugin.dll`'s
  dependent `m3shapes.dll` from PATH, so the launcher adds the module directory
  (`install/qml/M3Shapes`) to the child's DLL search path.
- All four original dashboard tabs: Dashboard, Media, Performance and Weather.
  The dashboard contains the original user/date/calendar/weather/resource/media
  layout. Performance reads CPU, RAM, GPU and volumes from the backend's
  `SystemMonitor`, and network throughput from `SystemStats`, with original
  network sparklines. Missing temperatures display Unavailable. Dashboard content
  scales down to fit the bounded host. Weather retains upstream HTTP requests
  and uses only profile-local cache storage.
- Original utilities wrapper and quick-toggle layout, limited to Wi-Fi,
  Bluetooth and shell-local do-not-disturb. Hardware controls follow their
  facade's availability and write gate.
- Original sidebar notification history, grouping, dismissal and mirror-access
  UI, plus original notification popups and core `Toaster` rendering.
- Original launcher search, keyboard navigation, app rows, action rows and
  wallpaper carousel. Type `>` for actions, `> calc 2*(3+4)^2` for arithmetic,
  or `> wallpaper ` to browse images in `%USERPROFILE%/Pictures/Wallpapers`.
  Set `CAELESTIA_WALLPAPER_DIR` before launching to use another folder. The
  Choose wallpaper action/control-window button opens a native image picker.
  Applying a wallpaper uses the existing `Quickshell.Windows.Wallpaper` API and
  requires Live controls. Highlighting an image never applies it.
- Calculator supports arithmetic, powers, parentheses, pi/e and basic math
  functions. Clicking/accepting copies the result in Live mode. Its external
  calculator button opens Windows Calculator in Live mode.

## Still unavailable, and why

- Workspaces, ActiveWindow, tiling, Hypr dispatch and AppBar are outside this
  implementation. Their existing adapters are unchanged.
- Dynamic schemes and variants require the upstream `caelestia scheme` CLI and
  matugen. Neither exists in the supplied runtime. Scheme/variant searches have
  no generated entries, and action descriptions identify the missing generator.
  Wallpaper changes therefore retain the fixed Caelestia palette.
- Lyrics, beat tracking and audio visualisation depend on excluded upstream
  native services. Cover art, metadata, player selection and transport remain.
- Profile picture editing is unavailable; its click reports this in a toast.
- Idle inhibition lacks a lifetime-scoped inhibition API in the existing backend.
  Recorder, VPN and Linux-specific quick toggles are hidden.
- Qalculate is excluded from the portable build. The arithmetic provider is a
  small expression parser, without Qalculate's units or arbitrary expressions.
- Hardware and backend capability limits still apply: missing DDC/WMI brightness
  routes, unavailable sensors, denied network access and notification-listener
  permission are not treated as successful operations. Software gamma remains
  off. Tray contents depend on the Live hook and actual native observation.

## Staging boundaries

`Stage-ShellPrototype.ps1` unions the M1 manifest, service slice manifests and
`combined-prototype/sources.json`. Combined overrides are explicit. Battery,
Bluetooth and Tray facades retain their `Windows*` staged names to avoid QML
component/singleton name collisions. Dashboard statistics fill the upstream
`Caelestia.Services` contracts using Windows APIs already in the backend; the
unbuilt Linux native services are never imported. Combined-only adapters replace
Linux process calls in profile pictures, calculator, wallpaper and launcher
providers. Other prototype entry points retain their existing sources and gates.

This remains a prototype. Smoke validates loading and layout without exercising
real writes, destructive actions, tray interception or notification consent.
