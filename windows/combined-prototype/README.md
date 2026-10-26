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

## Takeover

Taskbar takeover is opt-in. `windows.hideTaskbar` defaults to `false` and
`windows.restartOnCrash` defaults to `true` in the JSON configuration read at
supervisor startup:

```json
{"windows":{"hideTaskbar":true,"restartOnCrash":true}}
```

The prototype writes these platform settings to its isolated
`config/windows.json`. They are consumed by the supervisor, separate from
upstream's compiled `shell.json` schema, so an existing portable build does not
warn about an unknown `windows` option. Production should pass its platform
settings file as `-ConfigPath`.

For the combined prototype, use `-HideTaskbar`. `-Takeover` starts the watchdog
without hiding the taskbar; `-NoRestartOnCrash` disables crash relaunch. Keep
staging, profiles and logs in a writable `-RunRoot` when reusing a shared build:

```powershell
powershell -NoProfile -File windows/scripts/Start-ShellPrototype.ps1 `
    -QtPrefix "$env:LOCALAPPDATA\caelestia-dev\Qt\6.11.2\msvc2022_64" `
    -BuildRoot D:\AiStack\caelestia-windows\windows\.local\build `
    -RunRoot "$PWD\windows\.local\takeover" -Combined -HideTaskbar
```

Production integration calls `Start-DesktopShell.ps1` with its existing
`System.Diagnostics.ProcessStartInfo`, a fresh private `-StateDirectory`, and
the platform `-ConfigPath`. Optional `-StdoutPath` and `-StderrPath` capture shell
logs. Use `-RestoreWorkAreas` only if this shell directly changes work areas
outside the backend's AppBar API. Stale AppBars owned by the shell automatically
enable work-area restoration; otherwise the supervisor leaves work areas alone.
The function returns `Watchdog` (a process), `StatusPath`, and
`StateDirectory`. The watchdog owns launching the actual shell process, so there
is no launch-before-watch race and it survives termination of the launcher.
Do not daemonize the supplied command. No new QML singleton or backend pin is
required, and the production entry retains ownership of AppBar, background and
tiling creation.

The launcher forwards `PATH` and `CAELESTIA_*`, `QS_*`, `QT_*`, `QML*` variables
from `StartInfo`; other environment variables are inherited normally rather
than persisted. The watchdog sets `QS_DISABLE_CRASH_HANDLER=1` in the shell
child to prevent the backend's independent crash relauncher from bypassing the
three-crash limit. It leaves service write/consent gates to the caller.
Keep the state directory outside the repository when using a production profile.

The helper is a hidden Windows PowerShell STA process with a WinForms message
loop, compiled from `DesktopTakeover.cs`. It uses `SW_HIDE` on every
`Shell_TrayWnd` and `Shell_SecondaryTrayWnd`, without changing auto-hide settings
during takeover. Its hidden top-level HWND receives `TaskbarCreated`; a 250 ms
timer also catches delayed secondary taskbars and Explorer re-showing windows.
Normal exit restores saved taskbar visibility, taskbar flags and each monitor's
work area when the shell owned a reservation/change, then exits without
restarting. With hiding off it makes no taskbar visibility/flag changes.
Changed monitor layouts fall back to
current monitor rectangles minus the visible real taskbar. SW_HIDE alone does
not release Explorer's work-area reservation; AppBar placement remains the
production/AppBar controller's responsibility.

On nonzero shell exit the helper removes only that process's stale registrations
from the backend's `HKCU\Software\Quickshell\AppBars` table and restores the
desktop before any relaunch. Dead shell processes lose their native windows,
including background children of WorkerW. The helper redraws the desktop without
destroying Explorer's shared WorkerW/Progman windows or touching another live
shell. Relaunch waits 2 then 4 seconds; three consecutive lifetimes
under 30 seconds give up. A lifetime of 30 seconds resets the quick-crash count.
There is one supervisor per Windows session.

`desktop-before.json` is persisted before launching/hiding. `watchdog.json`
reports `phase`, `shellPid`, `watchdogPid`, `exitCode` and restart policy.
`taskbar-actions.jsonl` records the helper's HWND/owner, requested visibility and
immediate observation for its hide/restore calls. These are runtime recovery
files, not a validation archive. Stop cleanly through the shell's own quit
command; killing its `qs.exe` is treated as a crash.

Recovery, without restarting Explorer:

```powershell
powershell -NoProfile -File windows/scripts/Restore-Desktop.ps1
```

Recovery asks the session's active supervisor to stop its owned shell and restore
the desktop, then shows real taskbars, disables auto-hide, removes stale AppBars,
and resets each work area from its physical monitor rectangle minus the real
taskbar. It never removes live registrations belonging to another process.
`-SnapshotPath <state-directory>\desktop-before.json` instead restores exact
saved visibility/flags/work areas, including originally hidden taskbars.
`-RestartExplorer` explicitly permits restarting Explorer and affecting its
existing windows; recovery never does that by default. Another live taskbar
controller can immediately overwrite recovery, so production must keep only one
controller active. Per-monitor work-area recovery follows
[Microsoft's SPI_SETWORKAREA API](https://learn.microsoft.com/en-us/windows/win32/gdi/multiple-monitor-system-metrics).

The short `Test-DesktopTakeover.ps1 -QtPrefix ... -BuildRoot ...` check runs the
combined shell for ten seconds, requests clean Qt.quit, then hard-kills one new
owned instance with restart disabled. It asserts per-HWND hide/restore requests
against the supervisor's own snapshot and verifies both owned shells/watchdogs
exit. It does not assert exclusive control of a desktop shared with other tests.
Explorer restart, real AppBar/background crash cleanup and stable exclusive
takeover require the integrated production shell's live acceptance test.

## Available components

- Original bar logo, clock, tray, status icons, popouts, session drawer and OSD.
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
- Expressive M3 shape outlines and morphing require the native M3Shapes plugin,
  which is absent from the supplied build. A combined-only round-surface shim
  keeps the original layout and children; it does not claim the original shapes.
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
