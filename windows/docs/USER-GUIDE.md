# Caelestia for Windows user guide

Caelestia for Windows brings the original [Caelestia Shell](https://github.com/caelestia-dots/shell) QtQuick/QML desktop interface to Windows 11 on top of the Windows Quickshell backend (originally built for [ii-windows](https://github.com/nunreasonable/ii-windows)).

If you have riced Hyprland with Caelestia on Linux—or customized Windows with tools like Komorebi, GlazeWM, Yasb, `ksg-shell`, or Seelen—this guide covers how to install, configure, and troubleshoot the shell without digging into repository internals.

Detailed reference pages:

- [Configuration reference (`shell.json` and tiling)](CONFIGURATION.md)
- [Keybinds reference (`keybinds.json` and shortcuts)](KEYBINDS.md)

---

## What it is

Caelestia for Windows replaces the day-to-day Windows shell chrome (`explorer.exe` taskbar, Start menu, Action Center, and manual window snapping) while keeping the Windows Desktop Window Manager (DWM) in charge of application rendering and composition.

It runs the original Caelestia QML components, Material 3 Expressive shapes (`M3Shapes`), shaders, and spring/bezier motion curves natively on Windows, providing:

- **Left vertical bar:** App launcher button (logo), workspace indicators, active window title, system tray icons, clock, status icons (audio, Wi-Fi/Ethernet, Bluetooth, battery), status popouts, and power button. In full-screen shell mode, the bar registers a native Windows AppBar so maximized and tiled windows stop at the bar edge.
- **Launcher:** Instant app search over Windows `AppsFolder` and Start menu shortcuts (using Caelestia's original `fzf` smart-case and `fuzzysort` ranking), command actions (`>`), built-in math evaluator (`> calc`), and wallpaper switcher (`> wallpaper`).
- **Dashboard:** Four-tab top drawer with user profile, calendar, weather forecast, media player controls (via Windows GSMTC), and live hardware performance graphs (CPU, GPU, RAM, storage, and network throughput sparklines).
- **Desktop background:** Original Caelestia wallpaper surface (with shader transitions), desktop clock, and audio visualizer layer embedded directly into the Windows `Progman`/`WorkerW` desktop plane (either behind or above Explorer desktop icons).
- **Notifications and sidebar:** Toast popups, core shell toasts, and a right-edge notification history drawer. Supports local shell notifications by default and opt-in Windows system toast mirroring.
- **On-screen display (OSD) and utilities:** Volume and hardware monitor brightness sliders, quick toggles (Wi-Fi, Bluetooth, Do Not Disturb), keep-awake (idle inhibit), fullscreen `ffmpeg` screen recorder, and a session menu (lock, sign out, sleep, hibernate, reboot, shut down).
- **Window tiling:** Automatic DWM window tiling (`dwindle`, `master`, and `scrolling` layouts) with configurable inner/outer gaps, window inclusion/exclusion rules, and automatic floating with toast explanations when an app refuses to fit its tile.
- **Workspaces on virtual desktops:** Maps Caelestia's workspace bar and workspace dispatchers onto Windows 11 virtual desktops.

---

## Requirements

- **Operating system:** Windows 11 64-bit (x64). Native virtual desktop switching, window-to-workspace moves, and `WorkerW` desktop background embedding are verified on Windows 11 24H2 build families `26100`, `26200`, and `26300` (using an in-process COM provider—no third-party `VirtualDesktopAccessor.dll` download is required on supported 24H2 builds). `TODO(verify): confirm whether earlier Windows 11 builds (such as 22H2/23H2 builds 22621/22631) are supported for bar/services with workspace dispatch disabled.`
- **GPU and display:** Any Direct3D 11-capable GPU. Caelestia renders hardware-accelerated QtQuick 6 scenes and HLSL shaders via Direct3D 11. Works with Windows transparency effects turned on or off, and supports mixed-DPI multi-monitor setups (validated at 100%, 150%, and 175% scaling, including negative secondary monitor coordinates).
- **Permissions:** Standard user account (**no administrator privileges required**). Everything installs per-user under `%LOCALAPPDATA%`. Caelestia does not patch system files, inject DLLs into `explorer.exe`, or require UAC elevation.
- **Single active tiler:** If you enable Caelestia's window tiler, you must stop other tiling window managers (Komorebi, GlazeWM, FancyZones, `ksg-shell`, etc.) first.
- **Optional `ffmpeg` for screen recording:** The utilities screen-recorder card uses `ffmpeg.exe` (`gdigrab`) if `ffmpeg` is available on your `PATH`. Without `ffmpeg`, the rest of the shell works normally and the recorder card reports `Unavailable`.
- **Building from source (optional):** If you are compiling from a Git checkout instead of using a prebuilt package, see [NATIVE-BUILD.md](../NATIVE-BUILD.md) for the Visual Studio 2022 Build Tools, Qt 6.11.2 (`msvc2022_64`), and `clang-cl` 20.1.8 setup.

---

## Install, uninstall, and autostart

Build first using [NATIVE-BUILD.md](../NATIVE-BUILD.md). The repository installer packages that build into a per-user installation; it does not launch the shell.

### Install

From PowerShell (no admin prompt needed), run `Install-Caelestia.ps1` from the repository or release folder:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\windows\scripts\Install-Caelestia.ps1
& "$env:LOCALAPPDATA\Programs\caelestia-windows\Start-Caelestia.ps1"
```

Supported flags: `-BuildRoot`, `-QtPrefix`, `-VCRuntimeRoot`, `-Prefix`, `-ProfileRoot`, and opt-in `-Autostart`. `BuildRoot` defaults to this checkout's `windows/.local/build`; Qt is read from its build record when omitted.

For monitors sharing an edge, `windows.innerEdgeHoverWidth` in
`config/shell.json` sets the additional OSD and utilities hover strip in
logical pixels. It defaults to 12, accepts 0 to disable it, and is capped at
48. Outer desktop edges keep their normal trigger sizes.

What the installer does:

1. Copies the packaged runtime (`qs.exe`, Qt 6.11.2 runtime DLLs, Caelestia and `M3Shapes` QML plugins, staged QML tree, bundled Rubik / Material Symbols Rounded / Google Sans Flex fonts, and license notices) into `%LOCALAPPDATA%\Programs\caelestia-windows`.
2. Records the profile path, defaulting to `%LOCALAPPDATA%\caelestia-windows`. First launch creates its directories and seeds `config/shell.json`, `config/keybinds.json`, and `config/windows.json` without overwriting existing files. A Start-menu shortcut launches the installed script.
3. Leaves Windows autostart **off by default** unless you opt in.

### Opt-in autostart

Autostart is strictly opt-in so a fresh install cannot lock you into a broken session.

To enable autostart at sign-in during installation or afterward:

```powershell
# Enable autostart at Windows sign-in
powershell -NoProfile -ExecutionPolicy Bypass -File .\windows\scripts\Install-Caelestia.ps1 -Autostart
```

`-Autostart` creates a per-user `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` entry named `CaelestiaWindows` (temporary/custom prefixes use a stable hash suffix).

To disable autostart without uninstalling:

```powershell
# Disable autostart while keeping Caelestia installed
Remove-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name CaelestiaWindows -ErrorAction SilentlyContinue
```

The command above applies to the default prefix. Custom prefixes use the hash-suffixed Run entry shown by `Get-CaelestiaIntegration` in `Caelestia-InstallCommon.ps1`. There is no `-AutostartOnly` uninstall flag.

### Uninstall

To stop Caelestia, restore the Windows taskbar and work area, remove autostart, and uninstall the runtime:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\windows\scripts\Uninstall-Caelestia.ps1
```

Uninstall supports `-Prefix` and `-Purge`. It quits only that installation through IPC, removes its Start-menu shortcut and autostart entry, and preserves the profile by default. `-Purge` also removes the recorded profile.

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

### Running from a developer build (combined preview)

For a developer preview from [NATIVE-BUILD.md](../NATIVE-BUILD.md), launch:

```powershell
powershell -NoProfile -File windows/scripts/Start-ShellPrototype.ps1 `
    -QtPrefix "$env:LOCALAPPDATA\caelestia-dev\Qt\6.11.2\msvc2022_64" `
    -Combined -Live
```

- Omit `-Live` to run in read-only observation mode.
- Add `-Background` (and optionally `-DesktopIcons Behind` or `-DesktopIcons Replace`) to enable the desktop wallpaper surface and desktop clock.
- Add `-Tiling -TilingMode Observe` or `-Tiling -TilingMode Interactive` (with `-TilingIncluded` set) to run the M3 tiling slice inside the combined preview.

---

## First run and where config lives

### Directory layout

All user files live under `%LOCALAPPDATA%\caelestia-windows` (`C:\Users\<You>\AppData\Local\caelestia-windows`):

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

The first launch provisions `scheme/venv` inside this profile with pinned Python
packages and the Caelestia CLI. Python is an accepted runtime dependency;
`-SkipSchemeRuntime` keeps the fixed palette. Wallpaper Engine is detected
automatically, supplies the launcher picker and palette preview, and retains
ownership of the desktop background. The desktop clock defaults off.

### What to expect on first launch

1. **Bar and work area:** The vertical bar appears along the left edge of your screen. When full-screen shell mode is active, Caelestia reserves the bar's width via a Windows AppBar so maximized and tiled windows do not sit underneath the bar. Taskbar hiding is off by default. Opt in with `{"windows":{"hideTaskbar":true,"restartOnCrash":true}}` in `config/windows.json`, then quit and start the shell. While the taskbar is hidden, the supervisor consumes Explorer's taskbar shortcuts (Win+T, Win+Shift+T, Win+B, Win+digit, Win+Shift+digit, Win+Ctrl+digit, Win+Alt+digit and Win+Alt+Enter) so they cannot reveal it; a lone Win tap and Win+L keep working. Crash restart defaults on; `Restore-Desktop.ps1` provides emergency recovery.
2. **Opening drawers with the mouse:**
   - **Left edge hover/drag:** Shows or pins the bar (when `bar.persistent` is `false`).
   - **Top edge hover/drag:** Opens the **Dashboard** (user card, calendar, weather, media player, system performance).
   - **Bottom edge drag or clicking the top-left logo:** Opens the **Launcher**.
   - **Right edge drag:** Opens the **Notification sidebar** and **Utilities** drawer.
   - **Bottom-left power button:** Opens the **Session** menu.
   - **Clicking outside or pressing `Escape`:** Dismisses the active drawer and returns keyboard focus to your previous window.
3. **Notification mirroring consent:** Caelestia never triggers a Windows permission prompt at startup. An existing Allowed grant is discovered automatically. Otherwise, to mirror Windows notifications into Caelestia's popups and sidebar, open the right-edge notification sidebar and click **Request access** once. While mirroring is active, Caelestia requests per-app native banner suppression by default, leaving notifications in Windows Action Center. The original settings are journaled and restored on quit, mirror deactivation, or crash recovery, except where you changed a setting yourself. System toasts and Windows Defender are excluded, and the first toast from a newly seen app may also show a native banner. Set `windows.notifications.replaceSystemBanners` to `false` or list AUMIDs in `windows.notifications.keepSystemBanners` in `config/windows.json` to keep native banners. See the [configuration reference](CONFIGURATION.md). Immediate application of Windows' setting and end-to-end delivery still require live verification.

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
  - `> wallpaper` opens the horizontal wallpaper carousel reading images from `paths.wallpaperDir` (defaults to `%USERPROFILE%\Pictures\Wallpapers`, or override via `CAELESTIA_WALLPAPER_DIR`). Note: the carousel displays an odd number of wallpapers at a time, so keep 1 or 3+ images in the folder.
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

The top-right quota/agents drawer from the custom Linux overlay is ported with
the original components, layout and motion. Hover the **top-right strip** to
open it; it closes when the pointer leaves, when a fullscreen application
appears, or when the shell loses its focus grab. Like the Linux source there is
no bar entry and no default keybind.

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

No Python is needed to display quota. The drawer reads the summary with QML's
`XMLHttpRequest`, maps providers to chips, accounts to rows and quota windows
to meters, and shows `todayCostUsd` in the "Usage today" disclosure. Refreshes
follow `refreshIntervalMs` but never run faster than the manager's `ttlMs`;
only one request is in flight and it aborts after 15 seconds. The last good
summary is cached at `cache\quota-summary.json` in the profile (display names,
windows, status and cost only, no endpoint or key) so the previous reading
appears instantly on start.

If a refresh fails, the last good summary stays on screen behind the single
"Quota refresh failed. Showing saved data." line. Per-account token ledgers,
the per-model token table, balance, cooldown timestamps and the old saved
records under `state\omarchy\agents\usage` are not part of CPA Manager's
summary and are no longer shown. The bolt button still runs the upstream
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
(`WM_SYSCOMMAND` / `SC_MONITORPOWER = 2`) after a 500 ms delay. It is not a
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

The bar popout wrapper still supports upstream's detached mode: when a popout requests it, the wrapper opens this window on the requested page instead of an inline overlay. The staged Windows audio and Bluetooth popouts currently show their content attached (the Bluetooth popout offers the Windows Settings action instead), so no shipped control requests it yet.

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

Unmodified upstream files are staged directly. Only files that need a Windows service or type live under `windows/combined-prototype/adapters/modules/nexus/` (Bluetooth, network, audio controls, wallpaper picker, apps, services, about, the shared network and audio-device lists, the page container and registries, `NexusState`, `WindowFactory` and the Windows-only Window management page), each with a header or inline comment that states exactly what changed and why. See [CONFIGURATION.md](CONFIGURATION.md) for the `shell.json` schema.

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

- If a window's minimum size is larger than its assigned tile (`min-size`), if it repeatedly fights repositioning (`off-target`), or if it does not respond to move requests (`unresponsive`), Caelestia **floats the window automatically** instead of overlapping neighbors or entering an infinite resize loop.
- If a window settles slightly off its target frame after the correction limit (`correction-limit`), Caelestia leaves it in place with a small gap rather than jittering.
- Whenever a window cannot be tiled cleanly, Caelestia displays a rate-limited toast (`Couldn't tile <App>`) explaining the exact reason.
- **DPI-unaware windows:** The integrated backend includes the DPI-unaware placement fix; mixed-DPI live tiling acceptance remains separate from loading smoke.
- **Administrator (elevated) windows:** Because Caelestia runs as a standard user without admin rights, Windows User Interface Privilege Isolation (UIPI) prevents Caelestia from moving or closing elevated windows (such as an Administrator PowerShell or Registry Editor). Elevated windows remain unmanaged/floating.

### 4. System tray interception and native context menus

On Linux, StatusNotifierItem (`SNI`) apps send icon pixmaps and semantic `dbusmenu` trees over DBus directly to the bar. On Windows, `explorer.exe` owns the notification area (`Shell_TrayWnd` / `TrayNotifyWnd`):

- **Tray hook:** To show live tray icons in Caelestia's bar, the backend uses a tray hook (`QS_WINDOWS_TRAY_HOOK=1`, enabled in Live mode) to observe Explorer's tray items. When running in read-only modes with the hook disabled (`QS_WINDOWS_TRAY_HOOK=0`), the tray appears empty.
- **Native popup menus:** Windows tray icons draw their own Win32 popup menus when clicked rather than exporting a menu structure (`hasMenu` is `true`, `menu` is `null`). Clicking or right-clicking a tray icon in Caelestia invokes the application's native context menu (`display()`) rather than Caelestia's QML `TrayMenu` popout.
- **No scroll actions on tray icons:** Win32 tray icons do not have a standard scroll-wheel protocol, so scrolling over a tray item is a no-op.

### 5. Other service differences

- **Keep-awake and screen recorder (`utilities`):**
  - Keep-awake holds `SetThreadExecutionState(ES_CONTINUOUS | ES_DISPLAY_REQUIRED | ES_SYSTEM_REQUIRED)` in a helper process that exits automatically when toggled off or when Caelestia closes, replacing Wayland's `IdleInhibitor`.
  - The screen recorder card runs `ffmpeg -f gdigrab` (when `ffmpeg.exe` is on `PATH`) and saves fullscreen recordings to `%USERPROFILE%\Videos\Caelestia\recording_<timestamp>.mp4`. Region capture, audio capture, and pause are not supported on Windows.
- **Audio volume cap:** Windows Core Audio scalar volume ranges from `0%` to `100%` (`0.0`–`1.0`). Setting `services.maxVolume` above `1.0` in `shell.json` will not over-amplify past 100% as PipeWire does on Linux.
- **Brightness routes:** Uses WMI/ACPI (laptop panels), `\\.\LCD`, or DDC/CI (external monitors). If a monitor does not support DDC/CI or WMI, the brightness slider disables itself cleanly rather than silently applying a software gamma tint (software gamma dimming is off unless explicitly opted into via `CAELESTIA_WINDOWS_BRIGHTNESS_SOFTWARE=1`).
- **Wi-Fi passwords and Bluetooth PIN pairing:** Connecting to an already-saved Wi-Fi profile or confirm-only Bluetooth device works directly from the bar popout. Connecting to a new password-protected Wi-Fi network or pairing a Bluetooth device that requires PIN entry delegates to Windows Settings (`ms-settings:network-wifi` / `ms-settings:bluetooth`) so Caelestia never handles raw credentials. Note: Windows requires **Location services** to be enabled for apps to read Wi-Fi SSIDs; if Location permission is off, the network popout reports `location-denied` and hides the SSID list.
- **Calculator:** Uses a built-in math expression parser (arithmetic, exponents, parentheses, `pi`/`e`, and standard trig/log functions) plus a button to launch Windows Calculator, rather than Linux `libqalculate` unit conversions.

---

## Troubleshooting

### Where logs live

- **Installed shell:** Check `%LOCALAPPDATA%\caelestia-windows\logs\` (`shell.stdout.log` and `shell.stderr.log`; supervisor state and logs are under `runtime/supervisor-<id>/`).
- **Prototype / source builds:** Logs, JSON run summaries, and screenshots are written under `windows\.local\build\logs\` (and `windows\.local\build\shell-runs\`).
- **Inspecting live desktop state:** Run the included read-only diagnostic script from the repo to inspect monitor work areas, DPI scaling, taskbar auto-hide flags, and running shell PIDs:
  ```powershell
  powershell -NoProfile -File .\windows\scripts\Get-DesktopState.ps1
  ```

### How to quit or restart Caelestia

- **Restart / reload config:** Editing `shell.json` or `keybinds.json` hot-reloads automatically.
- **Quit cleanly:**
  - In the combined preview, close the **Caelestia Preview Control** window or click its **Exit preview** button.
  - Run `& "$env:LOCALAPPDATA\Programs\caelestia-windows\Start-Caelestia.ps1" -Command Quit` (or `Restart` / `State`). All calls select the exact installed QML path.
  - From PowerShell, you can stop the Quickshell process at any time:
    ```powershell
    Stop-Process -Name qsw, qs -ErrorAction SilentlyContinue
    ```

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
