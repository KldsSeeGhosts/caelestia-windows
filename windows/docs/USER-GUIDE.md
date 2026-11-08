# Caelestia for Windows user guide

Caelestia for Windows brings the original [Caelestia Shell](https://github.com/caelestia-dots/shell) QtQuick/QML desktop interface to Windows 11 on top of the Windows Quickshell backend (originally built for [ii-windows](https://github.com/nunreasonable/ii-windows)).

If you have riced Hyprland with Caelestia on Linux—or customized Windows with tools like Komorebi, GlazeWM, Yasb, `ksg-shell`, or Seelen—this guide covers how to install, configure, and troubleshoot the shell without digging into repository internals.

Detailed reference pages:

- [Configuration reference (`shell.json` and tiling)](CONFIGURATION.md)
- [Keybinds reference (`keybinds.json` and shortcuts)](KEYBINDS.md)

---

## What it is

Caelestia for Windows provides a full QtQuick desktop shell alongside or in place of the standard Windows shell chrome (`explorer.exe` taskbar, Start menu, Action Center, and manual window snapping—with taskbar hiding and automatic window tiling opt-in) while keeping the Windows Desktop Window Manager (DWM) in charge of application rendering and composition.

It runs the original Caelestia QML components, Material 3 Expressive shapes (`M3Shapes`), shaders, and spring/bezier motion curves natively on Windows, providing:

- **Left vertical bar:** App launcher button (logo), workspace indicators, active window title, system tray icons, clock, status icons (audio, Wi-Fi/Ethernet, Bluetooth, battery), status popouts, and power button. The audio popout follows upstream: output/input devices, master volume, and **Open settings** for Nexus Audio. App-volume controls live in **Audio > App volumes**, not in the popout. In full-screen shell mode, the bar registers a native Windows AppBar so maximized and tiled windows stop at the bar edge.
- **Launcher:** Instant app search over Windows `AppsFolder` and Start menu shortcuts (using Caelestia's original `fzf` smart-case and `fuzzysort` ranking), command actions (`>`), built-in math evaluator (`> calc`), and wallpaper switcher (`> wallpaper`).
- **Dashboard:** Four-tab top drawer with user profile, calendar, weather forecast, media player controls (via Windows GSMTC), and live hardware performance graphs (CPU, GPU, RAM, storage, and network throughput sparklines).
- **Desktop background:** Original Caelestia wallpaper surface (with shader transitions), desktop clock, and audio visualizer layer embedded directly into the Windows `Progman`/`WorkerW` desktop plane (either behind or above Explorer desktop icons).
- **Notifications and sidebar:** Toast popups, core shell toasts, and a right-edge notification history drawer. Supports local shell notifications by default and opt-in Windows system toast mirroring.
- **On-screen display (OSD) and utilities:** Volume and hardware monitor brightness sliders, quick toggles (Wi-Fi, Bluetooth, Do Not Disturb), keep-awake (idle inhibit), fullscreen `ffmpeg` screen recorder, and a session menu (lock, sign out, sleep, hibernate, reboot, shut down, and **Switch back to Windows**).
- **Window tiling:** Automatic DWM window tiling (`dwindle`, `master`, and `scrolling` layouts) with configurable inner/outer gaps, window inclusion/exclusion rules, and automatic floating with toast explanations when an app refuses to fit its tile.
- **Workspaces on virtual desktops:** Maps Caelestia's workspace bar and workspace dispatchers onto Windows 11 virtual desktops.

---

## Running windows

A running-app pill below the workspace switcher provides access to open windows,
including minimized windows. It does not replace the active-window title or
preview. The pill is absent when no windows are open.

Click an app icon to restore/focus its window. If the app has several windows,
click to choose by title and virtual desktop. Right-click any app icon to open
its window chooser with Minimize and Close actions. Escape or a click on the
bar outside the chooser dismisses it (other desktop clicks use native popup
focus dismissal); it starts on the first window each time. Close uses the
application's normal close behavior, including save prompts; it does not
terminate a process.
Apps on other desktops remain reachable, while tray-only apps stay in the tray.

The pill has a bounded height. Scroll over it to reach additional applications;
this does not trigger workspace or volume shortcuts. Alt+Tab and Win+Tab retain
their native Windows behavior.

## Requirements

- **Operating system:** Windows 11 64-bit (x64). Native virtual desktop switching, window-to-workspace moves, and `WorkerW` desktop background embedding are verified on Windows 11 24H2 build families `26100`, `26200`, and `26300` (using an in-process COM provider—no third-party `VirtualDesktopAccessor.dll` download is required on supported 24H2 builds). On earlier Windows 11 builds, the bar, drawers, and services run with virtual-desktop workspace dispatch disabled.
- **GPU and display:** Any Direct3D 11-capable GPU. Caelestia renders hardware-accelerated QtQuick 6 scenes and HLSL shaders via Direct3D 11. Works with Windows transparency effects turned on or off, and supports mixed-DPI multi-monitor setups (validated at 100%, 150%, and 175% scaling, including negative secondary monitor coordinates).
- **Permissions:** Standard user account (**no administrator privileges required**). Everything installs per-user under `%LOCALAPPDATA%`. Caelestia does not patch system files, inject DLLs into `explorer.exe`, or require UAC elevation.
- **Single active tiler:** If you enable Caelestia's window tiler, you must stop other tiling window managers (Komorebi, GlazeWM, FancyZones, `ksg-shell`, etc.) first.
- **Optional `ffmpeg` for screen recording:** The utilities screen-recorder card uses `ffmpeg.exe` (`gdigrab`) if `ffmpeg` is available on your `PATH`. Without `ffmpeg`, the rest of the shell works normally and the recorder card reports `Unavailable`.
- **Building from source (optional):** If you are compiling from a Git checkout instead of using a prebuilt package, see [NATIVE-BUILD.md](../NATIVE-BUILD.md) for the Visual Studio 2022 Build Tools, Qt 6.11.2 (`msvc2022_64`), and `clang-cl` 20.1.8 setup.

---

## Install, uninstall, and autostart

For a downloaded, prebuilt product, follow [Install a Windows release](INSTALL-RELEASE.md).
It needs no Qt SDK, compiler, Git or Python for the basic shell. The developer
instructions below instead require a build from [NATIVE-BUILD.md](../NATIVE-BUILD.md).
Both install paths preserve the profile and do not launch the shell by default.

### Install

From PowerShell (no admin prompt needed), run `Install-Caelestia.ps1` from the source repository:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\windows\scripts\Install-Caelestia.ps1
& "$env:LOCALAPPDATA\Programs\caelestia-windows\Start-Caelestia.ps1"
```

Supported flags: `-BuildRoot`, `-QtPrefix`, `-VCRuntimeRoot`, `-Prefix`, `-ProfileRoot`, opt-in `-Autostart`, opt-in `-DesktopShortcut`, and `-NoIntegration` for a disposable prefix with no per-user entries. `BuildRoot` defaults to this checkout's `windows/.local/build`; Qt is read from its build record when omitted.

For monitors sharing an edge, `windows.innerEdgeHoverWidth` in
`config/shell.json` sets the additional OSD and utilities hover strip in
logical pixels. It defaults to 12, accepts 0 to disable it, and is capped at
48. Outer desktop edges keep their normal trigger sizes.

What the installer does:

1. Copies the packaged runtime (`qs.exe`, Qt 6.11.2 runtime DLLs, Caelestia and `M3Shapes` QML plugins, staged QML tree, bundled Rubik / Material Symbols Rounded / Google Sans Flex fonts, and license notices) into `%LOCALAPPDATA%\Programs\caelestia-windows`.
2. Records the profile path, defaulting to `%LOCALAPPDATA%\caelestia-windows`. First launch creates its directories and seeds `config/shell.json`, `config/keybinds.json`, and `config/windows.json` without overwriting existing files. Start-menu launch and switch-back entries and a Settings > Apps uninstall entry are registered; `-DesktopShortcut` adds a desktop shortcut. None of them opens a terminal window.
3. Leaves Windows autostart **off by default** unless you opt in.

### Start, switch back to Windows, and uninstall without a terminal

Installation registers three per-user entrypoints. They start `conhost.exe
--headless` with Windows PowerShell, so no console window appears and no
VBScript host is used. `-ExecutionPolicy Bypass` is passed only to that single
process; your execution policy is never changed.

- **Start:** Start menu > **Caelestia Windows** starts the installed shell
  through `Start-Caelestia.ps1`. The optional desktop shortcut does the same.
- **Switch back to Windows:** Start menu > **Caelestia - Switch back to Windows**
  quits this installation, restores the native taskbar and work areas, and offers
  to turn autostart off. It reuses `Start-Caelestia.ps1 -Command Quit` and
  `Restore-Desktop.ps1`, so it does not depend on the shell answering and also
  works when the shell is hung. Start Caelestia again with the launch entry.
- **Uninstall:** Settings > Apps > Installed apps > **Caelestia for Windows** >
  Uninstall. See [Uninstall](#uninstall) below.

> Screenshot placeholder: Start menu showing "Caelestia Windows" and
> "Caelestia - Switch back to Windows". To be added after live desktop
> acceptance.

> Screenshot placeholder: "Switch back to Windows" autostart dialog. To be added
> after live desktop acceptance.

> Screenshot placeholder: Settings > Apps > Installed apps with the Caelestia for
> Windows uninstall action. To be added after live desktop acceptance.

The installed `.ps1` files are unsigned. Under App Control or Smart App
Control, Windows may block the launcher or action scripts until
[issue #20](https://github.com/KldsSeeGhosts/caelestia-windows/issues/20)
provides publisher signing; this is not a trust exemption. The entries fail
closed when policy blocks them, and the PowerShell commands in this guide still
work. Smart App Control and SmartScreen also judge the unsigned
`qs.exe` and `caelestia-capture.exe`.

### Opt-in autostart

Autostart is strictly opt-in so a fresh install cannot lock you into a broken session.

To enable autostart at sign-in during installation or afterward:

```powershell
# Enable autostart at Windows sign-in
powershell -NoProfile -ExecutionPolicy Bypass -File .\windows\scripts\Install-Caelestia.ps1 -Autostart
```

`-Autostart` creates a per-user `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` entry named `CaelestiaWindows` (temporary/custom prefixes use a stable hash suffix). The value starts Caelestia through the same hidden launcher as the Start-menu entry, so sign-in does not flash a console window.

To disable autostart without uninstalling, answer **Yes** in the "Switch back to Windows" dialog, or remove the Run value:

```powershell
# Disable autostart while keeping Caelestia installed
Remove-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name CaelestiaWindows -ErrorAction SilentlyContinue
```

The shell also offers this while leaving: **Switch back to Windows** in the
session menu or **Nexus > Services** quits Caelestia, restores the Windows
taskbar and desktop through the existing supervisor, and can turn off this
installation's autostart entry at the same time. The choice is off by default.
If that entry cannot be removed, Caelestia still quits and restores the desktop,
then reports which entry remains and where to remove it.

The command above applies to the default prefix. Custom prefixes use the hash-suffixed Run entry shown by `Get-CaelestiaIntegration` in `Caelestia-InstallCommon.ps1`. The Apps & features key uses the same prefix-derived name. There is no `-AutostartOnly` uninstall flag.

### Uninstall

From Settings > Apps > Installed apps > **Caelestia for Windows** > Uninstall.
One native dialog asks whether to also delete settings and profile data; **No**
is the default, so configuration and logs are kept for a later reinstall. The
equivalent command, for scripted or advanced use, is:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\windows\scripts\Uninstall-Caelestia.ps1
```

Uninstall supports `-Prefix`, `-Purge`, and `-AskPurge` (the Settings dialog).
It quits only that installation through IPC, restores the native desktop, removes
its Start-menu launch and switch-back entries, the optional desktop shortcut, its
autostart entry and its Apps & features entry, and preserves the profile by
default. `-Purge` also removes the recorded profile.

Windows update trust data under `%LOCALAPPDATA%\caelestia-update-trust` is always
kept, including with `-Purge`. The client records the newest signed update
metadata it has accepted there so a rollback or a reinstall cannot roll update
security back to older metadata; remove it manually only if you understand that
consequence.

This is a developer install path. The downloaded release registers the same
entries; see [Install a Windows release](INSTALL-RELEASE.md).

### Migrating from `ksg-shell`

If you previously used `ksg-shell`, you can preview or import your supported bar and OSD preferences from `%APPDATA%\com.ksg.shell\settings.json` into `%LOCALAPPDATA%\caelestia-windows\config\shell.json` using `windows/scripts/Import-KsgShellSettings.ps1`:

```powershell
# Preview mapped settings without writing any files
powershell -NoProfile -File .\windows\scripts\Import-KsgShellSettings.ps1 -Summary

# Write to your Caelestia config (backs up an existing shell.json when -Force is passed)
$config = Join-Path $env:LOCALAPPDATA 'caelestia-windows\config\shell.json'
powershell -NoProfile -File .\windows\scripts\Import-KsgShellSettings.ps1 -OutFile $config -Force
```

Disable `ksg-shell`'s tiler and exit `ksg-shell` before starting Caelestia in full shell or tiling mode.

### Running a developer build

Build and run the isolated production smoke using
[NATIVE-BUILD.md](../NATIVE-BUILD.md), then follow the
[production install instructions](../shell/README.md#install-and-run).
Use a separate prefix and profile for development. The fixture-based combined
preview is retired; its old launcher fails explicitly rather than starting a
live shell with different opt-ins. Desktop takeover, autostart and tiling
remain deliberate choices.

---

## First run and where config lives

### Directory layout

All user files live under `%LOCALAPPDATA%\caelestia-windows`:

```text
%LOCALAPPDATA%\caelestia-windows\
├── config\
│   ├── shell.json                         # Main shell configuration (optional; created by user or installer)
│   ├── shell-tokens.json                  # Advanced design token overrides (optional)
│   ├── keybinds.json                      # User keybind overrides (optional)
│   └── monitors\
│       └── <monitor_name>\
│           ├── shell.json                 # Per-monitor config overrides
│           └── shell-tokens.json          # Per-monitor token overrides
├── state\
│   ├── notifs.json                        # Persisted local notification history
│   └── apps-frequencies.json              # Launcher app launch frequency counts
├── cache\
│   └── ...                                # Media artwork thumbnails, weather cache, QML cache
└── logs\
    └── ...                                # Runtime stdout/stderr logs and diagnostics
```

First launch seeds `config/shell.json`, `config/keybinds.json` and `config/windows.json`. The profile also contains `state`, `cache`, `data`, `runtime` and `logs` directories.

The launcher sets `CAELESTIA_CONFIG_DIR`, `CAELESTIA_STATE_DIR`, and `CAELESTIA_RUNTIME_DIR`; staged QML DataDir/StateDir/CacheDir pragmas and `QML_DISK_CACHE_PATH` confine the remaining paths to the recorded profile.

The installer provisions the pinned Python packages and Caelestia CLI into an
immutable generation under `scheme/runtimes/` inside this profile while the
previous version is still running. `scheme/runtime.json` is published
atomically only after the generation verifies. A profile-scoped lock serialises
installer preparation, normal starts and repairs, so two provisioners never
write at once. Activation then only starts the shell, so a cold or slow first
install does not spend its readiness budget downloading packages or roll back a
healthy launch. If preparation fails, the install continues and Caelestia
starts with the fixed palette; `logs/scheme-runtime.log` records the fallback.
A start never waits for a provisioner: if it finds one already running for the
profile (for example the installer, or another start repairing a lost Python),
that shell stays on the fixed palette until the next shell start, even after the
other run finishes. A generation is used only if it was built from exactly the
current inputs and its Python still runs; a venv whose base Python was
uninstalled is repaired by a new generation, never reused. When a check passes,
`runtime.json` records a receipt (the base interpreter's path, size and
timestamp, a hash of `pyvenv.cfg` and the generation id); when a check fails the
record is replaced with an "unavailable" one. A starting shell accepts the
record only while that receipt still matches, using file metadata alone, and
otherwise uses the fixed palette. Starting the shell never runs Python or
discovers an interpreter: the system Python that the Wallpaper Engine bridge
uses when there is no scheme runtime is found while preparing and recorded in
`runtime.json`. If nothing was recorded, that bridge is unavailable for the
start. Provisioning logs and records contain no machine paths.
Python is an accepted runtime dependency; `-SkipSchemeRuntime` skips
preparation during this install, and an existing prepared runtime is still
used. Retained payloads that predate the generation layout start with scheme
provisioning disabled during a rollback, so no activation runs pip inside the
readiness budget. A rollback target keeps its own launcher's start behaviour:
only launchers from this change onwards guarantee that no Python runs during
activation, and an older retained launcher (for example one that still
discovers a Wallpaper Engine interpreter at start) behaves as it always did.
Update and rollback select the target's scheme generation before the running
shell is stopped. That search has a 15 s budget that tries the newest generation
first and falls back to older healthy ones. When there is a previous version to
fall back to, its restore generation is selected as well with its own 15 s
budget, so the combined pre-quit work can take up to about 30 s (the second
search is skipped when both versions use the same inputs). That check is final:
if nothing could be verified in time, the shell is stopped once and starts on
the fixed palette, and nothing is probed again after it has stopped. The same
holds for recovery: the previous version's generation is decided before the
shell is stopped too, so a failed activation that falls back to it relaunches
without probing, and with nothing verified (or a busy scheme lock) it starts on
the fixed palette. If a prune cannot restore a retired generation after a late
mapping, it records the restore in `scheme/prune-restore.json`; each later prune
makes one restore attempt before any deletion, and `logs/scheme-runtime.log`
records the count. Wallpaper Engine is detected automatically, supplies the
launcher picker and palette preview, and retains ownership of the desktop
background. The desktop clock defaults off.

### What to expect on first launch

1. **Bar and work area:** The vertical bar appears along the left edge of your screen. When full-screen shell mode is active, Caelestia reserves the bar's width via a Windows AppBar so maximized and tiled windows do not sit underneath the bar. Taskbar hiding is off by default. Opt in with `{"windows":{"hideTaskbar":true,"restartOnCrash":true}}` in `config/windows.json`, then quit and start the shell. While the taskbar is hidden, the supervisor consumes Explorer's taskbar shortcuts (Win+T, Win+Shift+T, Win+B, Win+digit, Win+Shift+digit, Win+Ctrl+digit, Win+Alt+digit and Win+Alt+Enter) so they cannot reveal it; a lone Win tap and Win+L keep working. Crash restart defaults on; `Restore-Desktop.ps1` provides emergency recovery.
2. **Opening drawers with the mouse:**
   - **Left edge hover/drag:** Shows or pins the bar (when `bar.persistent` is `false`).
   - **Top edge hover/drag:** Opens the **Dashboard** (user card, calendar, weather, media player, system performance).
   - **Bottom edge drag or clicking the top-left logo:** Opens the **Launcher**.
   - **Right edge drag:** Opens the **Notification sidebar** and **Utilities** drawer.
   - **Bottom-left power button:** Opens the **Session** menu. Choosing sign out, shut down, reboot or hibernate runs it immediately, as on upstream Caelestia; there is no confirmation step. `Tab` and `Shift+Tab` stay inside the menu, and `Escape` closes it.
   - **Clicking outside or pressing `Escape`:** Dismisses the active drawer and returns keyboard focus to your previous window.
3. **Notification mirroring consent:** Caelestia never triggers a Windows permission prompt at startup. An existing Allowed grant is discovered automatically. Otherwise, to mirror Windows notifications into Caelestia's popups and sidebar, open the right-edge notification sidebar and click **Request access** once. While mirroring is active, Caelestia requests per-app native banner suppression by default, leaving notifications in Windows Action Center. The original settings are journaled and restored on quit, mirror deactivation, or crash recovery, except where you changed a setting yourself. System toasts and Windows Defender are excluded, and the first toast from a newly seen app may also show a native banner. Set `windows.notifications.replaceSystemBanners` to `false` or list AUMIDs in `windows.notifications.keepSystemBanners` in `config/windows.json` to keep native banners. See the [configuration reference](CONFIGURATION.md). Immediate application of Windows' setting and end-to-end delivery still require live verification.

### Send a real test notification

From PowerShell in your interactive Windows desktop session:

```powershell
& "$env:LOCALAPPDATA\Programs\caelestia-windows\Start-Caelestia.ps1" -Command NotifyTest
```

For a custom installation, use its `Start-Caelestia.ps1` instead. The repository
launcher `windows/scripts/Start-Caelestia.ps1 -Command NotifyTest` also works
without installing or restarting the shell.

This submits a real Windows toast under the existing **Windows PowerShell**
notification identity, with the fixed title `Caelestia test notification` and
body `This is a test notification. No user data is included.` It uses the
normal Windows toast listener, not a synthetic QML notification. PowerShell 7
hands this command to inbox Windows PowerShell with `-NoProfile`.
The command does not request permissions, enable mirroring or change notification
settings. Existing opted-in banner-replacement behavior still applies.
If Windows PowerShell notifications are disabled or
unavailable, the command reports an error and leaves them alone. A submission
message is not proof of delivery; Windows notification policy and Do not disturb
can still prevent a banner.

To test Caelestia's popup and sidebar, the shell must already be running with
notification mirroring opted in and access **Allowed** using the sidebar's
existing consent flow. Without that, the toast only exercises Windows delivery.

1. With no fullscreen app active and Caelestia's Do not disturb off, send the
   command and check for the Caelestia popup, then open the right-edge sidebar
   (`Super+N`) and find the fixed title in history. Allow a few seconds for the
   Windows listener. A native Windows banner alone does not verify Caelestia.
2. Play a fullscreen video and send another test toast without leaving fullscreen
   (for example, queue it with `Start-Sleep -Seconds 10` before the command).
   Confirm no Caelestia popup covers the video. Leave fullscreen and confirm the
   new test notification still reached sidebar history.
3. Native banners are controlled separately by Windows and Caelestia's existing
   banner-replacement settings. The first toast from a newly seen sender may
   still show a native banner. Do not treat Windows' own fullscreen suppression
   as proof of Caelestia's suppression.

Popup, sidebar history and fullscreen suppression require live Windows checks;
headless tests cannot verify delivery or appearance.

---

## Configuration

Caelestia reads `%LOCALAPPDATA%\caelestia-windows\config\shell.json`. Like upstream Caelestia, **only put the keys you want to change in `shell.json`**—omitted keys automatically fall back to defaults, and unknown keys are quarantined with a warning toast.

When you save `shell.json`, Caelestia hot-reloads it and shows a `Config loaded` toast (if `utilities.toasts.configLoaded` is enabled) or warns you if there is a JSON syntax or schema issue.

See [CONFIGURATION.md](CONFIGURATION.md) for a full annotated reference. Below are the sections that matter most on Windows.

### Minimal starter `shell.json`

```json
{
    "appearance": {
        "transparency": {
            "enabled": false,
            "base": 0.85,
            "layers": 0.4
        }
    },
    "background": {
        "enabled": true,
        "wallpaperEnabled": true,
        "desktopClock": {
            "enabled": false,
            "position": "bottom-right"
        }
    },
    "bar": {
        "persistent": true,
        "showOnHover": true,
        "workspaces": {
            "shown": 5,
            "showUnoccupied": true,
            "displayType": "shapes",
            "showWindows": true
        },
        "clock": {
            "showDate": true,
            "showIcon": true
        },
        "statusIcons": [
            { "id": "audio", "enabled": true },
            { "id": "network", "enabled": true },
            { "id": "bluetooth", "enabled": true },
            { "id": "battery", "enabled": true }
        ]
    },
    "dashboard": {
        "enabled": true,
        "showOnHover": true
    },
    "launcher": {
        "enabled": true,
        "vimKeybinds": false,
        "favouriteApps": ["Windows Terminal", "Firefox"]
    },
    "services": {
        "weatherLocation": "",
        "weatherUnits": "Auto",
        "clockFormat": "Auto",
        "defaultPlayer": "Spotify"
    },
    "paths": {
        "wallpaperDir": "~/Pictures/Wallpapers"
    }
}
```

### Bar entries (`bar`)

- `bar.entries`: Reorder or toggle `"logo"`, `"workspaces"`, `"spacer"`, `"activeWindow"`, `"tray"`, `"clock"`, `"statusIcons"`, and `"power"`.
- `bar.statusIcons`: Enable or reorder status icons. On Windows, `"audio"`, `"network"`, `"bluetooth"`, and `"battery"` are backed by native Windows services. `"lockStatus"`, `"microphone"`, and `"kbLayout"` default to disabled because the Windows backend does not emit Hyprland keyboard/lock input events.
- `bar.workspaces`: Controls how many workspaces are shown (`shown`: `5`, which also sets the `1..20` ceiling for creating new virtual desktops on numeric/relative workspace switches), whether empty ones stay visible (`showUnoccupied`: `true`), and how indicators render (`displayType`: `"shapes"` or `"Text"`). Note that `bar.workspaces.perMonitor` only affects bar display—Windows virtual desktops switch globally across all monitors.
- `bar.tray`: Controls system tray icon rendering (`recolour`, `compact`, `hiddenIcons`, `iconSubs`).

### Launcher (`launcher` and `paths`)

- **Apps:** Indexed automatically from Windows `shell:AppsFolder` and Start menu directories. Use `launcher.favouriteApps` to pin apps to the top and `launcher.hiddenApps` (exact names or regexes) to hide clutter like uninstallers.
- **Search prefixes:** Type `@` (`launcher.specialPrefix`) to filter by category/field, or `>` (`launcher.actionPrefix`) to run shell actions:
  - `> calc 2*(3+4)^2` evaluates math expressions (click or press `Enter` to copy the result, or click the calculator icon to open Windows Calculator).
  - `> wallpaper` opens the horizontal wallpaper carousel reading images from `paths.wallpaperDir` (defaults to the `Wallpapers` subfolder of the Windows Pictures known folder, so a OneDrive-redirected Pictures folder works; override with `paths.wallpaperDir` or `CAELESTIA_WALLPAPER_DIR`). Note: the carousel displays an odd number of wallpapers at a time, so keep 1 or 3+ images in the folder.
  - `> light` / `> dark` switches color mode; `> scheme` / `> variant` selects color schemes using the profile-local pinned Caelestia CLI generator. Python and network access are required for its first-launch provision.
- **Vim navigation:** Set `"vimKeybinds": true` under `launcher` (and `session`) to navigate lists with `Ctrl+J`/`Ctrl+K` or `Tab`.

### Dashboard and desktop background (`dashboard`, `background`, and `services`)

- **Dashboard:** Toggle individual tabs with `showDashboard`, `showMedia`, `showPerformance`, and `showWeather`. Under `dashboard.performance`, toggle `showBattery`, `showGpu`, `showCpu`, `showMemory`, `showStorage`, and `showNetwork`. On desktops without a battery or sensors that do not report temperatures without a kernel driver, Caelestia cleanly displays absent/unavailable states instead of fake zeros.
- **Background:** Configure `background.wallpaperEnabled`, `background.desktopClock` (`enabled`, `scale`, `position`), and `background.visualiser` using the native WASAPI loopback provider. Static wallpaper images are supported with shader transitions; video wallpapers are not supported because the portable build excludes native Qt Multimedia.
- **Weather:** Set `services.weatherLocation` to a city or coordinates, or leave `""` for automatic IP geolocation.

### Tiling and gaps

Caelestia's Windows backend includes a native DWM tiler (`Quickshell.Windows.Tiling`) supporting three layouts:

- `"dwindle"` (default): Binary space partitioning that alternates split directions as you open windows.
- `"master"`: Master-stack layout (`masterFactor`: `0.55`, `masterOrientation`: `"left"`, `"right"`, `"top"`, `"bottom"`).
- `"scrolling"`: Niri/PaperWM-style horizontal scrolling strip (`scrollingColumnWidth`: `0.5`, `scrollingCenter`: `"overflow"`).

Tiling defaults off. Configure `windows.tiling` in `config/shell.json` or in Nexus under **Window management**:

```json
{"windows":{"tiling":{"enabled":false,"mode":"observe","gapsIn":5,"gapsOut":10,"singleWindowGapsOut":20,"borderColours":true,"include":["exe:notepad.exe"],"exclude":[],"float":["title:*Dialog*"],"monitors":{}}}}
```

Set `enabled=true` and choose `observe` or `interactive` after reviewing the
application allowlist. Interactive requires a non-empty `include`. Rules accept
arrays or semicolon-separated wildcards; `exe:`, `class:` and `title:` select
specific window facts. Monitor-name wildcards map to booleans. Exclude, float
and disabled-monitor rules take precedence. Changes reload live. The KSG importer
maps its gap and padding preferences, defaulting to 10/10 DIPs, and selects Observe.
`gapsIn` defaults to 5 DIPs per window side, making 10 DIPs between windows;
explicit saved values keep their existing meaning. `gapsOut` defaults to 10 DIPs.
`singleWindowGapsOut` defaults to 20 DIPs when only one window is tiled on a
monitor/workspace. Minimized and maximized windows do not count; maximizing
still fills the Windows work area.

`borderColours` defaults to true on Windows 11 build 22000+. Focused windows use
the scheme primary; other managed windows use dim onSurfaceVariant. The upstream
alpha values are blended against surface. Colours follow focus and scheme
changes and return to the system default when disabled, unmanaged or on normal
shell exit. Older Windows skips colouring. These settings reload live.
See [the complete tiling schema](../services/tiling/README.md).

To rearrange tiles, drag a window by its title bar or with Super+drag; both
work the same way. Release in the middle of another tile to swap the two, or
near one of its edges to put the window on that side (dwindle only; master
and scrolling always swap). While you drag, a tinted outline shows exactly
where the window will land, with a swap, split or move marker on it, and a
thin one shows where the other window goes. The release does what the
outline last showed. Releasing on the window's own slot or the bar puts it
back; releasing on another monitor's empty area moves it there. See
[dragging tiled windows](../services/tiling/README.md#dragging-tiled-windows).

Windows shell windows are recognised generically, and the taskbar's tool,
no-activate and owned rules keep transient overlays out of the tracked-app list.
If a third-party shell's popup still appears as an app or gets tiled, add it to
`windows.shellSurfaces.extra` in `config/shell.json`, for example
`{"windows":{"shellSurfaces":{"extra":["exe:some-shell.exe"]}}}`. Selectors use
the tiling dialect (unprefixed rules match executable or class, and `screen:` is
rejected) and apply live; the list is empty by default. See
[shell-surface selectors](CONFIGURATION.md#shell-surface-selectors).

Production supports `-TilingMode Disabled|Observe|Interactive`, `-TilingIncluded`
and `-TilingExcluded`. Explicit switches override environment, which overrides
profile values. Without an override, the profile applies. Smoke forces tiling off.
Native layout choices remain backend options; this profile schema configures
admission and gaps.

### Focus follows mouse

`windows.focusFollowsMouse` applies Windows' X-Mouse focus tracking only while
the shell runs. It is off by default, so the Windows-level setting is left
alone.

```json
{"windows":{"focusFollowsMouse":{"enabled":true,"delay":100,"raise":false}}}
```

`delay` is milliseconds before focus changes (0-5000, default 100); `raise`
brings the focused window to the top (default false). Changes reload live. The
shell records the current Windows values before its first change and restores
them when the option is turned off or the shell quits cleanly. The baseline is
kept across a live reload and saved under the profile's `runtime` directory
before any change, so the supervisor's restart after a crash can still restore
the values instead of leaving tracking on. The values are never written to the
user profile, so a crash or forced kill cannot leave the stored preference
changed; the next sign-in restores it. To migrate from the
old system-wide setup, enable this option and turn off Windows' own X-Mouse
setting (Settings > Accessibility > Mouse > "Activate a window by hovering over
it with the mouse").

### Clipboard history

`caelestia:clipboard` opens Caelestia's Material 3 clipboard picker over
**Windows' native clipboard history**. There is no separate capture store, so
the ordering, password-manager exclusions, pinned items, size limit and sync are
the same as Win+V. Search, text and image previews, arrow/Page/Home/End
navigation, `Delete` to remove an entry and a confirmed Clear All work as on
Linux. The picker restores focus to the application you came from and pastes
with a marked Ctrl+V when you press `Enter`. The destination is fixed when the
picker opens: if that window is gone, another application took focus, focus did
not return, or a modifier key (for example the Super you used to open the
picker) is still held, the paste is cancelled instead of injecting into the
wrong window or sending Win+Ctrl+V. `Shift+Enter` copies without pasting.

The feature is enabled by default (`windows.clipboard.enabled` in
`shell.json`) but **has no default key**. Add one yourself:

```json
{
    "extends": "defaults",
    "binds": [
        {
            "keys": "Super+V",
            "action": "global",
            "name": "caelestia:clipboard",
            "description": "Open clipboard history"
        }
    ]
}
```

Binding `Super+V` replaces Windows' own Win+V panel for that chord. The picker
can also be opened over IPC: `ipc call clipboard toggle`, `open`, `close` or
`state` against the installed shell.

If Windows clipboard history is off, Caelestia shows that honestly and offers a
button to open **Settings > System > Clipboard**. It never turns the setting on
for you and never logs clipboard contents. If Windows refuses history access to
the shell process, the picker says so instead of showing an empty list as if it
succeeded. Image previews and an explicitly opened text file are written only
inside the instance's own `cache\clipboard\<pid>-<random>` folder and that
folder is removed on shutdown. If a held modifier or a lost destination window
prevents the automatic paste after the item was copied, a Caelestia toast says
"Copied. Press Ctrl+V to paste". See
[the clipboard notes](../services/clipboard/README.md) for exact behaviour and
what still needs live verification.

### CPA quota drawer (Windows)

The top-right quota/agents drawer from the custom Linux overlay is ported and
redesigned after OpenUsage. Hover the **top-right strip** to open it; it closes
when the pointer leaves, when a fullscreen application appears, or when the
shell loses its focus grab. Like the Linux source there is no bar entry and no
default keybind.

The drawer has two views, chosen with the switch at the top (the choice lasts
until the shell restarts; it starts on **All Usage**):

- **All Usage** lists every provider in one scroll. Each provider has a bold
  title and a card. Each account shows its label and plan, then one row per
  quota window: the window name, a bar of what is **left**, the percentage and
  the time until it resets (`4h 10m`, `6d 23h`). A bar turns red at 10% left
  or less. The card ends with that provider's spend for Today, Yesterday and
  the Last 30 Days (API-equivalent cost from CPA Manager's usage analytics). A
  stale, reconnect or disabled account says so in one line above its rows.
- **Priority** is one card with each account's most constrained window, least
  left first, across all providers: what runs out first.

The footer shows when the next update is due. Its round `...` button opens a
menu with **Refresh now** and **Keepalive**. From the keyboard, Tab moves
through the two views, the scrolling content (arrows, Page Up/Down, Home and End
scroll it) and the `...` button; in the menu use Up and Down, Return or Enter,
and Escape.

#### Turning the drawer off

Not everyone uses AI services. In **Nexus > Services**, the **Agent usage panel**
switch (stored as `windows.quota.enabled` in `shell.json`) is on by default.
Switch it off and the drawer never opens, the top-right strip no longer reacts
to the pointer, and the shell makes no CPA request and runs no timer for it; an
open drawer closes at once. It applies immediately, with no restart. Switch it
on again and the last reading is there straight away. The switch only narrows
what the config below allows: it never turns the drawer on without a
`cpa-agents.json`.

The drawer is **opt-in**: nothing requests anything unless a CPA management
config exists. It reads CPA Manager's own pre-aggregated quota summary from:

```text
GET <baseUrl>/v0/management/quota/summary
Authorization: Bearer <adminKey>
```

The config file is:

```text
%LOCALAPPDATA%\caelestia-windows\config\cpa-agents.json
```

```json
{"baseUrl": "https://your-cpa-host", "adminKey": "<management key>"}
```

`CAELESTIA_CONFIG_DIR` (the shell profile) is used when set, and
`CAELESTIA_CPA_CONFIG` can name another file. The shell reads the file into
memory to build the request; the key, the response body, emails and account ids
are never logged. Keep the key out of commits, screenshots and issue reports.

Optional drawer settings live beside `shell.json` in `quota.json`. Every value
is optional and matches the Linux schema:

```json
{
    "enabled": true,
    "geometry": {"width": 384, "height": 520},
    "refreshIntervalMs": 60000
}
```

With `cpa-agents.json` present the drawer enables automatically. Set
`"enabled": false` to keep the config but hide the drawer, or provide
`quota.json` without `cpa-agents.json` to show the "not configured" empty state.

#### Detailed usage via CLIProxyAPI

Stock CLIProxyAPI has no quota summary. When the summary answers 404, or when
**Detailed usage via CLIProxyAPI** is on in **Nexus > Services**
(`windows.quota.cpaHub`, off by default), the drawer reads each Codex, Claude
and Antigravity login on the hub through its management `api-call`, with the
same `cpa-agents.json`. That adds token history by day with Top Models, and
Limit Resets with their expiry times. It needs Python, runs a small helper only
while the panel is on, reads each account at most every 5 minutes, and never
claims a reset. The hub's management key goes over plain http only when the
host's addresses are all on this PC, the local network or Tailscale, and only
with the switch on. If the hub rejects the key, the drawer stops asking, even
after a restart, until you update `adminKey` in `cpa-agents.json`. Hub mode calls the vendors' internal usage
endpoints and sends their own clients' headers, which their terms may not
allow; see [the port notes](../quota/README.md#hub-mode-cliproxyapi).

Summary mode needs no Python. The drawer reads the summary with QML's
`XMLHttpRequest`, maps providers to sections, accounts to blocks and quota
windows to rows, and reads each provider's spend from the usage analytics. Refreshes
follow `refreshIntervalMs` but never run faster than the manager's `ttlMs`;
only one request is in flight and it aborts after 15 seconds. The last good
summary is cached at `cache\quota-summary.json` in the profile (display names,
windows, status and cost only, no endpoint or key) so the previous reading
appears instantly on start.

If a refresh fails, the last good summary stays on screen behind the single
"Quota refresh failed. Showing saved data." line. Per-account token ledgers,
the per-model token table, balance, cooldown timestamps and the old saved
records under `state\omarchy\agents\usage` are not part of CPA Manager's
summary and are no longer shown. The **Keepalive** menu entry still runs the upstream
optional keepalive helper; that is an explicit request that sends real
keepalive traffic to CPA, needs Python and the CPA inference key
(`CPA_API_KEY` in the environment, or the Linux `environment.d/cpa.conf`
fallback), and is not run during smoke or by the shell at startup.

See [the port notes](../quota/README.md) for the source mapping and what is and
is not verified.

### Turning the display panels off

`ipc call displays off` (or your own `ipc` keybind, see
[KEYBINDS.md](KEYBINDS.md#3-ipc--call-a-caelestia-ipchandler)) asks the shell's
own window to switch the physical panels off with Windows display power
(`WM_SYSCOMMAND` / `SC_MONITORPOWER = 2`). On a keybind, the keyboard hook waits
for every key of the triggering chord to be released; other input first cancels
it. A direct IPC call has no chord and sends at once. It is not a
display-topology disable: it changes no resolution, scale, desktop coordinate or
window position and stores no setting. Normal input wakes the panels, but
keep-awake, remote input or background activity can also wake them. This path
has been tested with fakes only; whether Windows keeps both monitors in the
topology must be verified live, and physically powering a monitor off may still
remove it.

### Per-monitor configuration

To override settings on a specific display, create:

```text
%LOCALAPPDATA%\caelestia-windows\config\monitors\<monitor_name>\shell.json
```

Run the installed `Start-Caelestia.ps1 -Command State` and use each `windows[].screen` value, which is the exact Qt `ShellScreen.name` used by configuration.

---

## Default keybinds

On Linux, Caelestia relies on Hyprland's `hyprland.conf` / `keybinds.lua` to bind keys to `global` shortcuts and `hyprctl dispatch`. On Windows, `shell.json` does not store keybinds; instead, the Quickshell backend runs its own `HotkeyManager` (`Quickshell.Windows.Hotkeys`), which reads defaults from `defaults/windows/keybinds.json` and your personal overrides from `%LOCALAPPDATA%\caelestia-windows\config\keybinds.json`.

The following table comes from the merged `defaults/windows/keybinds.json`. Window/tiling/workspace dispatch chords are not assigned by default. `caelestia:nexus` and `caelestia:clipboard` are registered but intentionally unbound; add your own `global` binds for them (see [KEYBINDS.md](KEYBINDS.md#1-global--trigger-a-caelestia-customshortcut)). Binding `Super+V` to the clipboard replaces Windows' Win+V panel for that chord.

| Action | Default keys | Target |
| --- | --- | --- |
| Toggle the launcher (lone Super tap) | `Super` (tap on release) | `caelestia:launcher` |
| Toggle the launcher, dashboard, OSD and utilities together | `Super+K` | `caelestia:showall` |
| Toggle the dashboard | `Super+Shift+D` | `caelestia:dashboard` |
| Toggle the notification sidebar | `Super+N` | `caelestia:sidebar` |
| Toggle utilities | `Super+Shift+U` | `caelestia:utilities` |
| Toggle the session menu (Ctrl+Alt+Delete is reserved by Windows) | `Ctrl+Alt+End` | `caelestia:session` |
| Clear all notifications | `Ctrl+Alt+C` | `caelestia:clearNotifs` |
| Toggle do not disturb | `Super+Shift+N` | `caelestia:toggleDnd` |
| Play or pause the active player | `Ctrl+Super+Space` | `caelestia:mediaToggle` |
| Play or pause the active player | `XF86AudioPlay` | `caelestia:mediaToggle` |
| Next track | `Ctrl+Super+Equal` | `caelestia:mediaNext` |
| Next track | `XF86AudioNext` | `caelestia:mediaNext` |
| Previous track | `Ctrl+Super+Minus` | `caelestia:mediaPrev` |
| Previous track | `XF86AudioPrev` | `caelestia:mediaPrev` |
| Stop the active player when it supports stop | `Ctrl+Super+Backspace` | `caelestia:mediaStop` |
| Stop the active player when it supports stop | `XF86AudioStop` | `caelestia:mediaStop` |
| Raise the default output volume | `XF86AudioRaiseVolume` | `caelestia:volumeUp` |
| Lower the default output volume | `XF86AudioLowerVolume` | `caelestia:volumeDown` |
| Mute or unmute the default output | `XF86AudioMute` | `caelestia:volumeMute` |
| Mute or unmute the default output | `Super+Shift+M` | `caelestia:volumeMute` |
| Raise the active display brightness | `Ctrl+Alt+Page_Up` | `caelestia:brightnessUp` |
| Lower the active display brightness | `Ctrl+Alt+Page_Down` | `caelestia:brightnessDown` |
| Lock Windows | `Super+L` | `rundll32.exe user32.dll,LockWorkStation` |

For custom keybind syntax (`global`, `dispatch`, `ipc`, `exec`, `key`, `reload`, and `extends: "defaults"`), see [KEYBINDS.md](KEYBINDS.md).

---

## Nexus settings (Windows)

Nexus is upstream Caelestia's settings app (`modules/nexus/`), the successor to the old control center. It runs on Windows as a **detached top-level window**: a normal DWM window with native per-monitor DPI, a minimum size, its own title, and destroy-on-close. The Windows tiler never manages it, because the backend refuses every window owned by the shell process.

Open it from:

1. the `caelestia:nexus` global shortcut — registered but not bound by default; add a `global` bind in `config/keybinds.json`;
2. the utilities drawer's **settings** quick toggle.

The bar popout wrapper supports upstream's detached mode: the audio popout's **Open settings** button opens Nexus on **Audio**, where **App volumes** opens the existing mixer. As on upstream, the mixer lists individual audio streams; an application with multiple sessions can appear more than once. The Bluetooth popout instead offers the Windows Settings action.

Nexus writes the global `Caelestia.Config` layer, so every change lands in `%LOCALAPPDATA%\caelestia-windows\config\shell.json` and applies live; the settings file watcher also reloads the window when you edit that file by hand. Only schema keys are written, so no option is quarantined.

Nexus edits that global file, not per-monitor overlays. If a value is overridden in `config/monitors/<name>/shell.json`, the monitor override keeps winning on that monitor; edit the monitor file to change it there.

### Page support on Windows

| Page | Status | What works, and what Windows owns |
| --- | --- | --- |
| Wallpaper & style | Works | Wallpaper preview, "Wallpapers" (browse/random, featured, local files, Wallpaper Engine items), plus the display-wallpaper and transparency toggles, all persisted to `shell.json`. The dark-theme toggle drives the generated colour scheme through the same scheme generator Linux uses, so that state lives in the scheme output rather than in `shell.json`. Upstream's "Colours" page is a placeholder. |
| Network | Partially supported | Wi-Fi on/off, the visible network list with signal and security, connect to saved or open networks, disconnect, forget a saved profile, and honest states for "no adapter" and "location denied". New password-protected networks, VPN profiles, static IP/DNS and the wired adapter details live in Windows Settings; the page links to `ms-settings:network`. |
| Connected devices (Bluetooth) | Partially supported | Radio on/off, paired-device list, connect/disconnect, forget, per-device battery and address, and a gated pair request. Discoverable, pairable, trusted, blocked and wake settings are not exposed by the backend and are shown disabled; a PIN or passkey prompt is completed in Windows Settings (`ms-settings:bluetooth`). |
| Audio | Works | Output and input volume/mute, device pickers and per-app volumes, through the same WASAPI/PipeWire-compatible facade the bar popout uses. Needs the audio observation and control opt-ins, which a normal Live start enables; a bounded read-only run shows the devices but refuses every write. |
| Panels (Dashboard, Taskbar, Launcher, Sidebar, Utilities, plus the workspace/active-window/tray/status-icon/clock sub-pages) | Works | Writes the same `bar`, `dashboard`, `launcher`, `sidebar` and `utilities` keys as Linux and applies them live. Linux-only entries stay inert on Windows: `specialWorkspaceIcons`, and the `lockStatus` / `microphone` / `kbLayout` status icons. |
| Window management | Works | Tiling enable, Observe/Interactive mode, the tiling-list count, border colours, the three gaps, and focus-follows-mouse enable/delay/raise persist to `windows` in `shell.json`. Tiling changes apply live; the focus-follows-mouse values take effect once the shell includes the focus-follows-mouse service. The include/exclude/float/monitor rules themselves stay in `shell.json`. |
| Apps | Partially supported | "All apps" browses the Windows `shell:AppsFolder` + Start-menu catalog and sets favourites and hidden apps for the launcher, when the app catalog is enabled for the run. Upstream's default-application pickers write `general.apps.*`, which Windows does not use, so they are replaced by a link to `ms-settings:defaultapps`. |
| Services | Works, one row unavailable | Poll intervals, input increments, visualiser bars, smart scheme, default player and GPU override persist and apply live. Lyrics are not available on Windows, so the lyrics-backend select states that instead of offering a dead choice. |
| Language & region | Works | UI language, temperature/data/clock units, and the upstream weather-location placeholder. |
| About | Partially supported | Hero, shell and Qt versions, hostname, platform, board and uptime. Upstream's Linux distro/kernel/firmware rows and the `quickshell` / `caelestia` CLI probes are omitted because those values do not exist on this port. |
| Updates, Plugins | Not implemented upstream | Caelestia itself shows "under construction"; the entries stay in the navigation with that state. |

### Windows adapter boundary

Unmodified upstream files are staged directly. Only files that need a Windows service or type live under `windows/shell/adapters/modules/nexus/` (Bluetooth, network, audio controls, wallpaper picker, apps, services, about, the shared network and audio-device lists, the page container and registries, `NexusState`, `WindowFactory` and the Windows-only Window management page), each with a header or inline comment that states exactly what changed and why. See [CONFIGURATION.md](CONFIGURATION.md) for the `shell.json` schema.

The Windows-only **Window management** page exposes `windows.tiling` (`enabled`, `mode`, `gapsIn`, `gapsOut`, `singleWindowGapsOut`, `borderColours`) and `windows.focusFollowsMouse` (`enabled`, `delay`, `raise`). The include, exclude, float and monitor rules remain in `shell.json` as described in [CONFIGURATION.md](CONFIGURATION.md#tiling-and-gaps-configuration).

---

## What differs from Linux Caelestia and why

Because Windows 11 uses the Desktop Window Manager (DWM) and Win32/WinRT APIs rather than a Wayland compositor that Caelestia controls directly, several behaviors differ intentionally from Linux Hyprland:

### 1. Windows lock screen instead of Caelestia's custom lock surface

On Linux, Caelestia renders its own `ext-session-lock-v1` lock surface (`modules/lock/`) and authenticates via PAM, `fprintd`, or Howdy. On Windows, the secure desktop (`Winlogon` / `LogonUI.exe`) is isolated by the OS kernel, and any user-space window can be bypassed or killed if used as a lock screen.

- Locking from Caelestia's session menu or launcher (`Lock`) calls `LockWorkStation()` (`Quickshell.Windows.Session.lock()`), handing off immediately to the native Windows lock screen and Windows Hello.
- The `lock` section in `shell.json` is ignored on Windows.

### 2. Virtual desktops for workspaces

On Hyprland, each monitor has independent workspaces and named `special:` scratchpad workspaces. On Windows, workspaces map onto native Windows 11 Virtual Desktops:

- **Global across monitors:** Switching to workspace 2 switches all connected monitors to virtual desktop 2, because Windows virtual desktops span the entire desktop session. Every monitor's bar indicator reflects the same active global workspace.
- **No `special:` scratchpad workspaces:** `togglespecialworkspace` and `cycleSpecialWorkspace` are safe no-ops on Windows.
- **In-process COM desktop control on Windows 11 24H2:** Switching workspaces (`workspace <n>`, `workspace r+1`/`r-1`, `workspace name:<name>`), creating missing desktops up to `bar.workspaces.shown` (clamped `1..20`), and moving windows (`movetoworkspace <n>`) use an in-process COM provider verified for Windows 11 24H2 build families `26100`, `26200`, and `26300`. On unsupported Windows builds where the COM interface GUIDs do not match, workspace dispatch is refused safely rather than injecting synthetic keyboard shortcuts.

### 3. Apps that resist tiling float automatically

A Wayland compositor can tell a client what size to render at and clip its surface. On Windows, applications manage their own Win32 `WM_GETMINMAXINFO` constraints, DWM invisible shadow borders, and modal resize loops:

- If a window's minimum size is larger than its assigned tile (`min-size`), it **stays tiled** at its larger size, like Hyprland: it is anchored at its tile, kept inside the screen's work area, and overlaps its neighbour until the tile has room again (for example when a neighbour closes). A window too large for the whole work area starts at the work area's leading edge and overflows past the far edge.
- If a window is slow to accept a move (`unresponsive`), it keeps its tile and moves there when it catches up.
- If a window keeps moving away from its tile (`off-target`), Caelestia floats it. It gets one fresh attempt when you move it to another monitor or desktop, or when a neighbour closes. Choosing to tile it yourself (`togglefloating`/`settiled`) always wins.
- If a window settles slightly off its target frame after the correction limit (`correction-limit`), Caelestia leaves it in place with a small gap rather than jittering.
- Whenever a window cannot be tiled cleanly, Caelestia displays a rate-limited toast explaining the reason.
- **DPI-unaware windows:** The integrated backend includes the DPI-unaware placement fix; mixed-DPI live tiling acceptance remains separate from loading smoke.
- **Administrator (elevated) windows:** Because Caelestia runs as a standard user without admin rights, Windows User Interface Privilege Isolation (UIPI) prevents Caelestia from moving or closing elevated windows (such as an Administrator PowerShell or Registry Editor). Elevated windows remain unmanaged/floating.

### 4. System tray interception and native context menus

On Linux, StatusNotifierItem (`SNI`) apps send icon pixmaps and semantic `dbusmenu` trees over DBus directly to the bar. On Windows, `explorer.exe` owns the notification area (`Shell_TrayWnd` / `TrayNotifyWnd`):

- **Tray hook:** To show live tray icons in Caelestia's bar, the backend uses a tray hook (`QS_WINDOWS_TRAY_HOOK=1`, enabled in Live mode) to observe Explorer's tray items. When running in read-only modes with the hook disabled (`QS_WINDOWS_TRAY_HOOK=0`), the tray appears empty.
- **Native popup menus:** Windows tray icons draw their own Win32 popup menus when clicked rather than exporting a menu structure (`hasMenu` is `true`, `menu` is `null`). Clicking or right-clicking a tray icon in Caelestia invokes the application's native context menu (`display()`) rather than Caelestia's QML `TrayMenu` popout.
- **No scroll actions on tray icons:** Win32 tray icons do not have a standard scroll-wheel protocol, so scrolling over a tray item is a no-op.

### 5. Other service differences

- **Keep-awake and screen recorder (`utilities`):**
  - Keep-awake holds a native `PowerCreateRequest` for display and system availability, replacing Wayland's `IdleInhibitor`. The request is owned by the shell process: toggling it off clears it, and Windows drops it when Caelestia closes.
  - The screen recorder card runs `ffmpeg -f gdigrab` (when `ffmpeg.exe` is on `PATH`) and saves fullscreen recordings to `%USERPROFILE%\Videos\Caelestia\recording_<timestamp>.mp4`. Region capture, audio capture, and pause are not supported on Windows.
- **Audio volume cap:** Windows Core Audio scalar volume ranges from `0%` to `100%` (`0.0`–`1.0`). Setting `services.maxVolume` above `1.0` in `shell.json` will not over-amplify past 100% as PipeWire does on Linux.
- **Brightness routes:** Uses WMI/ACPI (laptop panels), `\\.\LCD`, or DDC/CI (external monitors). If a monitor does not support DDC/CI or WMI, the brightness slider disables itself cleanly rather than silently applying a software gamma tint (software gamma dimming is off unless explicitly opted into via `CAELESTIA_WINDOWS_BRIGHTNESS_SOFTWARE=1`).
- **Wi-Fi passwords and Bluetooth PIN pairing:** Connecting to an already-saved Wi-Fi profile or confirm-only Bluetooth device works directly from the bar popout. Connecting to a new password-protected Wi-Fi network or pairing a Bluetooth device that requires PIN entry delegates to Windows Settings (`ms-settings:network-wifi` / `ms-settings:bluetooth`) so Caelestia never handles raw credentials. Note: Windows requires **Location services** to be enabled for apps to read Wi-Fi SSIDs; if Location permission is off, the network popout reports `location-denied` and hides the SSID list.
- **Calculator:** Uses a built-in math expression parser (arithmetic, exponents, parentheses, `pi`/`e`, and standard trig/log functions) plus a button to launch Windows Calculator, rather than Linux `libqalculate` unit conversions.

---

## Troubleshooting

### Where logs live

- **Installed shell:** Check `%LOCALAPPDATA%\caelestia-windows\logs\` (`shell.stdout.log` and `shell.stderr.log`; supervisor state and logs are under `runtime/supervisor-<id>/`).
- **Source builds:** Build logs are under `<BuildRoot>\logs\`. Public smoke keeps its temporary run directory on failure. Keep diagnostic output outside the source checkout.
- **Inspecting live desktop state:** Run the included read-only diagnostic script from the repo to inspect monitor work areas, DPI scaling, taskbar auto-hide flags, and running shell PIDs:
  ```powershell
  powershell -NoProfile -File .\windows\scripts\Get-DesktopState.ps1
  ```

### How to quit or restart Caelestia

- **Restart / reload config:** Editing `shell.json` or `keybinds.json` hot-reloads automatically.
- **Quit cleanly:**
  - Run `& "$env:LOCALAPPDATA\Programs\caelestia-windows\Start-Caelestia.ps1" -Command Quit` (or `Restart` to reload / `State` to query status). All calls target the exact installed QML path; `Quit` stops the supervisor and restores the Windows taskbar and work area cleanly.
  - Avoid killing `qs.exe` directly with `Stop-Process -Name qsw, qs`: when `restartOnCrash` is enabled in `windows.json`, the background supervisor treats an unexpected `qs.exe` exit as a crash and restarts the shell automatically. Always use `Start-Caelestia.ps1 -Command Quit` to exit.

### Restoring the taskbar, work area, or off-screen windows after a crash

If `qs.exe` is force-killed or crashes, the Windows backend is designed to self-heal on the next launch, and every change can also be reversed manually:

1. **Shrunk monitor work area (stale AppBar strip on the left):**
   - **Automatic fix:** Start Caelestia again (even briefly) and close it cleanly. On startup, the backend runs `WinAppBar::removeStale()`, which checks `HKCU\Software\Quickshell\AppBars`, removes any `SHAppBarMessage(ABM_REMOVE)` registrations left behind by dead PIDs, and restores your full monitor work area.
   - **Manual fix:** Restart Windows Explorer (`Stop-Process -Name explorer` in PowerShell) or sign out and back in.
2. **Missing or stuck auto-hide Windows taskbar:**
   - **Automatic fix:** The backend tracks taskbar auto-hide ownership in `HKCU\Software\Quickshell` (`TaskbarAutoHideOwned`) and automatically releases stale auto-hide 15 seconds after startup if taskbar takeover is off.
   - **Manual fix:** If the taskbar window (`Shell_TrayWnd`) was hidden during a crash, restore it and clear the ownership marker in PowerShell:
     ```powershell
     Remove-ItemProperty -Path 'HKCU:\Software\Quickshell' -Name 'TaskbarAutoHideOwned' -ErrorAction SilentlyContinue
     Stop-Process -Name explorer
     ```
     Then toggle **Settings → Personalization → Taskbar → Taskbar behaviors → Automatically hide the taskbar** if auto-hide is still enabled.
3. **Windows missing after a crash while tiling across workspaces:**
   - When the tiler parks windows off-screen, it attaches a `QuickshellTilingParked` Win32 window property atom storing the window's original restore rectangle.
   - **Automatic fix:** Launch Caelestia again (even with tiling in `observe` mode). `TilingManager::rescueParked()` runs automatically on construction and moves all parked windows back onto the visible monitor work area.
4. **Dimmed screen (software gamma):**
   - If you opted into software brightness dimming (`CAELESTIA_WINDOWS_BRIGHTNESS_SOFTWARE=1`) and the process was hard-killed, launching and cleanly quitting Caelestia (or locking/unlocking Windows with `Win+L`) restores the default gamma ramp.

### Running alongside another tiler is unsupported

Do **not** enable Caelestia's tiler while another tiling window manager (Komorebi, GlazeWM, FancyZones, `ksg-shell`, or another Quickshell instance) is actively tiling your desktop:

- While Caelestia uses a session mutex (`tiler-mutex-held`) to block a second Quickshell tiler from starting, external tilers do not share this mutex.
- Two active tilers will fight over `SetWindowPos` and foreground focus on every window event, causing windows to flicker, lose focus, or hit Caelestia's `off-target` / `correction-limit` guards and float.
- Either stop your existing tiler before enabling Caelestia tiling, or keep Caelestia's tiler set to `off` if you only want Caelestia's bar, launcher, dashboard, and notifications.

---

## Credits and licenses

The interface comes from Caelestia Shell and m3shapes. Windows platform support
comes from nunreasonable's Windows Quickshell backend, built for ii-windows,
and outfoxxed's Quickshell. This port adds Windows adapters, tooling and plugin
changes. ii-windows was a packaging reference only; no code was copied.

See the [three-layer credits and AI-assistance disclosure](../README.md#credits-and-attribution)
and [third-party notices](../../THIRD-PARTY-NOTICES.md) for every project's
source, copyright, license and notice location. Installed shell notices are
under `<Prefix>\licenses\`; colour-generation package notices stay in the
profile-local Python virtual environment. Python is required for colour
generation. Fonts are loaded into the process, not installed into Windows.
