# Combined shell prototype

For the all-monitor production entry and per-user installation, see
[the Windows shell entry](../shell/README.md).

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
an explicit control-window toggle. It reserves the bar's width on the left and
the configured border thickness on the other three edges through four native
AppBars. These release when full screen is turned off, an application enters
fullscreen, or the host exits. Tiling defaults off; profile configuration or explicit switches can enable it.
See [the tiling schema](../services/tiling/README.md) for live reload, typed rules
and gap defaults (5 DIPs per inner side, 10 outer, 20 outer for a single tile).

Build with [NATIVE-BUILD.md](../NATIVE-BUILD.md) from this checkout. Build and
launch default to this checkout's `windows/.local/build`; `-BuildRoot` overrides
that path.

When reusing a build, pass `-RunRoot` to put stages, profiles and logs in a
separate directory without writing into `-BuildRoot`. Each concurrent run
should have its own run root.

`Measure-ShellRuntime.ps1 -QtPrefix <Qt> -BuildRoot <build> -RunRoot <new-directory>`
runs a 20-minute read-only profile on screen 1. It samples private bytes,
working set, handles, GDI/USER objects, threads and CPU every 15 seconds. Two
minutes idle at each end bracket four cycles of dashboard tabs, launcher
scrolling, popouts, utilities, history and OSD, with an action every 10 seconds.
CPU is recorded both as one-core utilization and divided by logical processor
count. `-RuntimeProbe` disables pointer interaction and focus acquisition in
this instance, so outside clicks cannot dismiss the IPC-driven panels. The
`prototype` target exposes `showPanel(name, tab)` and `scrollLauncher(index)`;
these only change local UI state. The harness targets its own child PID and
stops only that process. This is resource profiling, not an input acceptance test.

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

## Keyboard shortcuts

The staged shell instantiates the original `GlobalShortcut` daemon over the
Windows backend's native hotkey manager. `defaults/windows/keybinds.json` is
the default Windows map and mirrors Caelestia's Hyprland binds where Windows
allows it: a lone Super tap opens the launcher, Super+K shows all panels,
Super+Shift+D opens the dashboard, Super+N the sidebar, Super+Shift+U
utilities, Ctrl+Alt+End the session menu (Ctrl+Alt+Delete is reserved), Ctrl+Alt+C
clears notifications, Super+Shift+N toggles do not disturb, Ctrl+Super+Space and
the media keys control playback, the XF86 volume keys control the output,
Ctrl+Alt+Page Up/Down adjust brightness, and Super+L locks Windows. The media,
volume and brightness actions still require the matching Live control gate;
in read-only observation they are inert rather than failing a native route.

A lone Super tap is delivered by a low-level keyboard hook, which also keeps the
Start menu from opening while the shell owns the tap. Other combinations use
`RegisterHotKey`, falling back to the same hook where Windows reserves them; the
hook is only installed while at least one hook-backed bind exists. Both the
registered hotkeys and the hook are removed when the shell exits, so the Start
menu works normally again.

When the supervisor hides the taskbar (`-HideTaskbar` or
`windows.hideTaskbar`), it also consumes Explorer's taskbar chords with its own
low-level hook: Win+T, Win+Shift+T, Win+B, Win+digit, Win+Shift+digit,
Win+Ctrl+digit, Win+Alt+digit and Win+Alt+Enter. The hook runs on a dedicated
message-loop thread, is installed before the shell starts so the shell's hook
still clears the lone-Super tap first, and is active only while the supervised
shell process runs. After a consumed chord the next Win release is masked with
qs.exe's 0xE8/`0x5153484B` convention, and injected or remapped chords are
consumed unless they carry that marker. A lone Super tap and Super+L remain the
shell's bindings, and Win+A/Win+N are untouched.

To change the map, place a `keybinds.json` in the shell configuration directory
(`CAELESTIA_CONFIG_DIR`, next to `shell.json`) or at
`%LOCALAPPDATA%\caelestia\windows\keybinds.json`. Start from
`{"extends": "defaults", "binds": [...]}` and override a default entry with
`"base": "global:caelestia:launcher"`, or set
`CAELESTIA_WINDOWS_KEYBINDS` to an explicit file for isolated runs. Changes are
watched and reload the binds without restarting the shell.

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

## Dynamic colours and the profile-local scheme runtime

`Start-ShellPrototype.ps1 -Combined` calls `Install-SchemeRuntime.ps1`, which
provisions `scheme/venv` under the combined profile (never the repository or the
user's ordinary Python packages) with `pillow==13.0.0`,
`materialyoucolor==3.0.4` and the upstream `caelestia` CLI pinned at
`5e804b10`. The installer also places a Windows `fcntl` shim in the venv and
copies `win_scheme.py` into the profile. Use `-SkipSchemeRuntime` to skip
provisioning and the generator entirely. A failed provision is cached in
`scheme/runtime.json`; delete that file or run `Install-SchemeRuntime.ps1
-ProfileRoot <profile> -Force` to retry.

`win_scheme.py` imports the CLI's scheme/material modules but deliberately skips
its theme writer (Linux-only `fcntl`, Hyprland sockets, dconf, `/dev/pts` and
`killall`). The Windows shell is the only theme consumer. Upstream's symlink
wallpaper state is replaced with ordinary `path.txt`/`thumbnail.jpg` files
because Windows symlinks need extra privileges. All state, cache and config
writes are forced below `combined-prototype-profile`; the bridge refuses to run
without `CAELESTIA_PROFILE_ROOT`.

If provisioning or generation fails, `schemeRuntime` is false in the run result
and the shell keeps its fixed Caelestia palette. Switching variant or mode while
a static scheme is selected switches to the wallpaper-derived dynamic palette
when a wallpaper is known, so those rows always do something visible.

## Wallpaper Engine

Discovery, picker and palette matching use the running Wallpaper Engine instance.
The Caelestia desktop host, including its clock, yields while Wallpaper Engine
owns the desktop. `windows.wallpaperEngine` in `config/windows.json` defaults to
auto detection. See [the service guide](../services/wallpaperengine/README.md).
The production entry uses the same services and provisions its scheme venv under
`%LOCALAPPDATA%\caelestia-windows\scheme`; its desktop clock defaults off.

## Still unavailable, and why

- Dynamic colours require Python and a successful first-launch dependency download.
  Failed provisioning keeps the fixed palette. Only the Windows shell receives
  generated colours; Linux theme targets are not applied.
- Lyrics still require the excluded native lyrics service. Audio analysis uses
  WASAPI loopback in `Caelestia.Windows.Audio`; the original cover visualiser,
  background visualiser and beat-driven GIF consume its providers.
- Clicking the profile picture opens a file picker. The chosen image is copied to
  `profile-picture` in the shell's state folder and shown in the dashboard ahead of
  the Windows account picture. The Windows account picture is never changed.
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

## Active-window preview fixture

The Windows host reserves a 16:9 viewport within the original active-window
popout. Capture frames retain their aspect ratio inside it. This prevents
late capture dimensions from changing the popout's animation target; Linux
keeps the upstream capture-sized layout.

Run `powershell -NoProfile -File windows/scripts/Test-ActiveWindowFixture.ps1
-QtPrefix <Qt-prefix>`. On Qt 6.11.2, source base `8fcf0163`, backend
`c62451da`, the offscreen fixture passed with simulated frame sizes and source
changes. In this fixture the unreserved popout height changed from 452 to 277
DIPs, while the reserved content remained 400 by 277 DIPs. It uses the
production staging manifest and no native window observation or real capture.
It does not validate live hover, capture latency, or perceived smoothness.
