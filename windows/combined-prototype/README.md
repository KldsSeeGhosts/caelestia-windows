# Combined shell prototype

The bounded Windows host stages the original Caelestia bar, workspaces, active
window, dashboard, launcher, utilities, notification history, popups and toasts
over the reviewed facades in
`windows/services`. Configuration and state stay in the isolated combined profile.

## Desktop background

Add `-Background` to opt into the original Caelestia wallpaper surface and desktop
clock. `-DesktopIcons Behind` is the default; `-DesktopIcons Replace` draws above
the icons without changing Explorer's icon visibility setting. Both modes stay
below ordinary application windows. Exiting removes the surfaces and reveals
the existing desktop. The host never writes the Windows wallpaper at startup.

The original `background` configuration controls the wallpaper transition,
clock scale/position and per-screen enablement. The launcher creates an isolated
profile with the wallpaper and clock enabled when `-Background` is supplied.
Ordinary runs follow the enabled monitor list through the original `Variants`;
smoke restricts the background to `-ScreenIndex`.

```powershell
powershell -NoProfile -File windows/scripts/Start-ShellPrototype.ps1 `
    -QtPrefix "$env:LOCALAPPDATA\caelestia-dev\Qt\6.11.2\msvc2022_64" `
    -BuildRoot D:\AiStack\caelestia-windows\windows\.local\build `
    -RunRoot "$PWD\windows\.local\background-smoke" `
    -Combined -Background -Smoke
```

`-RunRoot` separates staging, profile state and logs from the read-only build.
With `-Background -Smoke`, the combined host performs a roughly 10-second
background/clock check instead of the longer panel sequence. Other combined
smoke invocations retain their existing panel checks.

The pinned backend already maps `WlrLayer.Background`/`Bottom` to desktop child
windows when `Quickshell.Windows.DesktopLayer.enabled` is set. It sends
`0x052C` to Progman when needed, supports both top-level WorkerW and the
24H2+ WorkerW child layout, and follows desktop/monitor changes. The Windows
wrapper enables that API only for this opt-in; without a desktop host it creates
no background surfaces.

Wallpaper pixels use the launcher's shared `Wallpapers.current`, initialized
from Windows' current wallpaper path with the bundled image as fallback.
The original `WallpaperImpl` capture and shader transitions remain in use.
The portable image adapter supports static images; video wallpapers require
the excluded native Multimedia implementation. The original visualiser is staged
behind a provider check and becomes available when `Audio.cava` is supplied.

## Launch

```powershell
powershell -NoProfile -File windows/scripts/Start-ShellPrototype.ps1 `
    -QtPrefix "$env:LOCALAPPDATA\caelestia-dev\Qt\6.11.2\msvc2022_64" `
    -Combined -Live
```

Omit `-Live` for read-only observation. The control window labels the mode and
provides panel buttons, screen selection, wallpaper selection and preview exit.
Hover the top edge for the dashboard, bottom edge for the launcher, and right
edge for notification history. The logo also opens the launcher. Full screen is
an explicit control-window toggle. It reserves the bar's width through a native
AppBar and releases that reservation when full screen is turned off or the host
exits. Tiling stays off unless separately requested.

Build with [NATIVE-BUILD.md](../NATIVE-BUILD.md) from this checkout. Build and
launch default to this checkout's `windows/.local/build`; `-BuildRoot` overrides
that path.

To observe tiling, add `-Tiling -TilingMode Observe`. To enable placement, use
an explicit application allowlist:

```powershell
powershell -NoProfile -File windows/scripts/Start-ShellPrototype.ps1 `
    -QtPrefix "$env:LOCALAPPDATA\caelestia-dev\Qt\6.11.2\msvc2022_64" `
    -Combined -Live -Tiling -TilingMode Interactive -TilingIncluded 'notepad.exe'
```

Use only one active tiling manager. `-TilingExcluded` accepts a semicolon-separated
denylist; the include list uses the same syntax. Tiling opt-ins are independent
of `-Live`; smoke reduces Interactive to Observe and never enables placement.
Fitting failures and enable refusals use the shared original toast surface.

`-Live` enables the existing audio, hardware brightness, media, Wi-Fi, Bluetooth,
power-profile, app-launch, tray activation and session action gates. It also
enables the tray hook, the keep-awake helper, the ffmpeg recorder and the
launcher's Lock action. Lock resolves through the original session adapter to
the pinned backend's `Session.lock()`, which calls Windows `LockWorkStation`;
there is no custom lock screen or credential UI. Notification mirroring, Windows
dismissal and app-open are permitted, but listener access is requested only by
the history panel's explicit button. No access request happens at startup.
Destructive session buttons create a pending request; Confirm/Cancel appear in
the control window. Commands remain confined to the session adapter allowlist.

`-Combined -Smoke` and `-Combined -Live -Smoke` both suppress native writes,
launches, session dispatch, tray interception and notification mirroring. The
utilities cards load, but the keep-awake helper and ffmpeg recorder hold no
process, which the smoke harness asserts. Smoke loads all dashboard tabs,
utilities, history, the launcher, status popouts, notifications and a toast,
and exits. The notification popup/history check injects an in-process fixture
through the notification service. It never sends through the session bus,
whose existing owner may be the user's running shell. This checks UI loading
and retention, not native notification delivery or mirroring.

## Available components

- Original bar logo, workspaces, active window, clock, tray, status icons,
  popouts, session drawer and OSD. Workspaces and active window observe through
  the Windows Hypr facade. Live enables native desktop selection by click and
  relative scrolling, with creation bounded by the configured workspace count.
  Both smoke modes keep dispatch off.
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
- Original utilities wrapper with the keep-awake, screen-recorder and
  quick-toggle cards. Quick toggles are limited to Wi-Fi, Bluetooth and
  shell-local do-not-disturb; hardware controls follow their facade's
  availability and write gate. Keep-awake holds
  `SetThreadExecutionState(ES_CONTINUOUS | ES_DISPLAY_REQUIRED |
  ES_SYSTEM_REQUIRED)` in a PowerShell child process that ends when the toggle
  turns off or the shell exits. The recorder drives `ffmpeg` with `gdigrab`
  when `ffmpeg` is on PATH and writes
  `%USERPROFILE%\Videos\Caelestia\recording_<timestamp>.mp4`; stopping flushes
  the MP4 through ffmpeg's stdin. Without ffmpeg the card reports Unavailable
  with that reason. Both cards are visible in every combined run but act only
  while Live controls are on, and never during smoke.
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

- Workspace dispatch remains unavailable in this host. The five visible slots
  use the original Text display; per-monitor workspace ownership is unclaimed.
- Dynamic schemes and variants require the upstream `caelestia scheme` CLI and
  matugen. Neither exists in the supplied runtime. Scheme/variant searches have
  no generated entries, and action descriptions identify the missing generator.
  Wallpaper changes therefore retain the fixed Caelestia palette.
- Lyrics, beat tracking and audio visualisation depend on excluded upstream
  native services. Cover art, metadata, player selection and transport remain.
- Profile picture editing is unavailable; its click reports this in a toast.
- Idle inhibition is not the upstream Wayland `IdleInhibitor`; Windows holds the
  execution state in a child process instead (see the utilities card above). The
  recorder supports fullscreen `gdigrab` only: region capture, audio capture and
  pause have no implemented ffmpeg route, so the card does not offer them. Its
  recordings list and delete modal are omitted with the Linux `caelestia record`
  directory layout. VPN and Linux-specific quick toggles remain hidden.
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
