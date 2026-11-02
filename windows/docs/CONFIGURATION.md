# Configuration reference

Back to the [Caelestia for Windows user guide](USER-GUIDE.md).

Caelestia reads its main configuration from:

```text
%LOCALAPPDATA%\caelestia-windows\config\shell.json
```

Like upstream Linux Caelestia, **only add the options you want to customize**. Any omitted option uses its built-in default, which keeps your configuration forward-compatible when defaults are tuned across updates. Do not add unknown top-level keys (such as `tiling` or `keybinds`) to `shell.json`: `Caelestia.Config` validates the schema strictly and quarantines unrecognized fields.

---

## Per-monitor overrides

You can override layout and panel options for a specific monitor by placing a `shell.json` file at:

```text
%LOCALAPPDATA%\caelestia-windows\config\monitors\<monitor_name>\shell.json
```

Use the exact Qt `ShellScreen.name` returned in `windows[].screen` by the installed `Start-Caelestia.ps1 -Command State`. This avoids confusing native device identifiers with Qt display names.

For example, to auto-hide the bar on a secondary monitor:

```json
{
    "bar": {
        "persistent": false
    }
}
```

### Options that ignore per-monitor overrides

The following global options are read only from the root `%LOCALAPPDATA%\caelestia-windows\config\shell.json` and ignored in per-monitor files:

- `appearance`: `anim.*`, `transparency.*`
- `bar.tray`: `hiddenIcons`, `iconSubs`
- `bar.workspaces`: `ignoredTags`, `specialWorkspaceIcons`, `windowIcons`, `workspaceIcons`
- `dashboard`: `mediaUpdateInterval`, `resourceUpdateInterval`
- `general`: `apps.*`, `battery.*`, `idle.*`, `logo`
- `launcher`: `actionPrefix`, `actions`, `enableDangerousActions`, `favouriteApps`, `hiddenApps`, `specialPrefix`, `useFuzzy.*`, `vimKeybinds`
- `nexus`: `networkRescanInterval`
- `notifs`: `actionOnClick`, `defaultExpireTimeout`, `expire`, `fullscreen`, `fullscreenExpireTimeout`
- `paths`: `lyricsDir`, `wallpaperDir`
- `services`: `audioIncrement`, `brightnessIncrement`, `clockFormat`, `dataUnits`, `defaultPlayer`, `gpuType`, `lyricsBackend`, `maxVolume`, `playerAliases`, `sensorUnits`, `smartScheme`, `visualiserBars`, `weatherLocation`, `weatherUnits`
- `utilities`: `toasts.*`, `vpn.*`
- `windows`: `clipboard.*`, `focusFollowsMouse.*`, `tiling.*` (Windows extensions)

---

## Key sections in `shell.json` and Windows differences

### `appearance` and `border`

Controls scaling, rounding, spacing, padding, fonts, animation durations, transparency, and the outer screen frame border.

- **Bundled fonts:** `GoogleSansFlex` (headline, title, body, label), `Rubik` (clock, workspaces), and `Material Symbols Rounded` (icons) are bundled and loaded into the Caelestia process automatically—you do not need to install them into `C:\Windows\Fonts`.
- **Monospace font (`appearance.font.mono`):** Defaults to `"CaskaydiaCove NF"`. Install Cascadia Code Nerd Font in Windows or change `appearance.font.mono.family` to `"Cascadia Mono"` or `"Consolas"`.
- **Transparency (`appearance.transparency`):** Set `"enabled": true` to use semi-transparent surfaces (`base`: `0.85`, `layers`: `0.4`). Works whether Windows system transparency effects are on or off.
- **Dynamic color schemes:** The profile-local pinned Caelestia CLI generates Material You palettes. `services.smartScheme` selects smart mode/variant. Python and a first-launch download are required; failure retains the fixed palette. Wallpaper Engine previews drive the same generator.
- **Expressive Material 3 shapes:** The native `M3Shapes` QML plugin (`windows/deps/m3shapes`) is compiled and staged on Windows, providing authentic `M3Shapes.MaterialShape` ambient media shapes, cover-art masking, loading indicators, and morph animations.

### `bar`

Controls the left vertical bar, workspaces indicator, active window title, system tray, clock, and status icons.

```json
{
    "bar": {
        "persistent": true,
        "showOnHover": true,
        "dragThreshold": 20,
        "scrollActions": {
            "workspaces": true,
            "volume": true,
            "brightness": true
        },
        "popouts": {
            "activeWindow": true,
            "tray": true,
            "statusIcons": true
        },
        "workspaces": {
            "shown": 5,
            "activeIndicator": true,
            "occupiedBg": false,
            "showUnoccupied": true,
            "perMonitor": true,
            "showWindows": true,
            "maxWindowIcons": 5,
            "activeTrail": false,
            "displayType": "shapes",
            "label": "  ",
            "occupiedLabel": "󰮯",
            "activeLabel": "󰮯",
            "capitalisation": "preserve",
            "workspaceIcons": [],
            "windowIcons": [
                {
                    "regex": "steam(_app_(default|[0-9]+))?",
                    "icon": "sports_esports"
                }
            ]
        },
        "activeWindow": {
            "compact": false,
            "inverted": false,
            "showOnHover": true
        },
        "tray": {
            "background": false,
            "recolour": false,
            "compact": false,
            "iconSubs": [],
            "hiddenIcons": []
        },
        "clock": {
            "background": false,
            "showDate": false,
            "showIcon": true
        },
        "statusIcons": [
            { "id": "lockStatus", "enabled": false },
            { "id": "audio", "enabled": true },
            { "id": "microphone", "enabled": false },
            { "id": "kbLayout", "enabled": false },
            { "id": "network", "enabled": true },
            { "id": "bluetooth", "enabled": true },
            { "id": "battery", "enabled": true }
        ],
        "entries": [
            { "id": "logo", "enabled": true },
            { "id": "workspaces", "enabled": true },
            { "id": "spacer", "enabled": true },
            { "id": "activeWindow", "enabled": true },
            { "id": "spacer", "enabled": true },
            { "id": "tray", "enabled": false },
            { "id": "clock", "enabled": true },
            { "id": "statusIcons", "enabled": true },
            { "id": "power", "enabled": true }
        ],
        "excludedScreens": []
    }
}
```

**Windows differences:**

- `bar.workspaces.shown` (clamped `1..20`) also sets `Hyprland.workspaceLimit` on the Windows backend: numeric workspace switches and relative scrolling create missing virtual desktops up to this count, while any existing virtual desktops above `shown` remain addressable and are never deleted automatically.
- `bar.workspaces.specialWorkspaceIcons` and `showWindowsOnSpecialWorkspaces` have no effect because Windows virtual desktops do not have Hyprland `special:` scratchpads.
- `bar.entries` `tray`: disabled by default until tray icons respond to clicks reliably. Set `enabled` to `true` to show it.
- `bar.tray`: Right-clicking a tray item opens the application's native Win32 context menu rather than an inline QML `TrayMenu`.
- `bar.statusIcons`: `"audio"`, `"network"`, `"bluetooth"`, and `"battery"` are supported out of the box. `"lockStatus"`, `"microphone"`, and `"kbLayout"` default to disabled because the Windows backend does not provide Hyprland keyboard/lock state.

### `launcher` and `paths`

Controls the bottom application and action launcher drawer.

```json
{
    "launcher": {
        "enabled": true,
        "showOnHover": false,
        "maxShown": 7,
        "maxWallpapers": 9,
        "specialPrefix": "@",
        "actionPrefix": ">",
        "enableDangerousActions": false,
        "dragThreshold": 50,
        "vimKeybinds": false,
        "favouriteApps": [],
        "hiddenApps": [],
        "useFuzzy": {
            "apps": false,
            "actions": false,
            "schemes": false,
            "variants": false,
            "wallpapers": false
        }
    },
    "paths": {
        "wallpaperDir": "~/Pictures/Wallpapers",
        "lyricsDir": "~/Music/lyrics/",
        "sessionGif": "root:/assets/kurukuru.gif",
        "mediaGif": "root:/assets/bongocat.gif",
        "noNotifsPic": "root:/assets/dino.png"
    }
}
```

**Windows differences:**

- **App catalog:** Enumerates Windows `shell:AppsFolder` and Start menu shortcuts. Launch counts are stored in `%LOCALAPPDATA%\caelestia-windows\state\apps-frequencies.json`.
- **Wallpapers:** `paths.wallpaperDir` defaults to the `Wallpapers` subfolder of the Windows Pictures known folder (for example `%USERPROFILE%\Pictures\Wallpapers`, or a Pictures folder redirected to OneDrive). An explicit `paths.wallpaperDir` or the `CAELESTIA_WALLPAPER_DIR` environment variable still wins. Known Folders are resolved once at startup, so a folder redirection changed while the shell is running takes effect after a restart. Selecting a wallpaper in `> wallpaper` applies it to the Windows desktop via `Quickshell.Windows.Wallpaper`.
- **Actions (`launcher.actions`):** Session actions in the launcher (`Shutdown`, `Reboot`, `Logout`, `Lock`, `Sleep`) route through the Windows session service allowlist; arbitrary Linux shell commands (`systemctl`, `loginctl`, `caelestia` CLI) are translated if they match the session allowlist or refused without running a detached process.

### `dashboard` and `services`

Controls the top dashboard drawer and platform service intervals/units.

```json
{
    "dashboard": {
        "enabled": true,
        "showOnHover": true,
        "showDashboard": true,
        "showMedia": true,
        "showPerformance": true,
        "showWeather": true,
        "mediaUpdateInterval": 500,
        "resourceUpdateInterval": 1000,
        "dragThreshold": 50,
        "performance": {
            "showBattery": true,
            "showGpu": true,
            "showCpu": true,
            "showMemory": true,
            "showStorage": true,
            "showNetwork": true
        }
    },
    "services": {
        "weatherLocation": "",
        "weatherUnits": "Auto",
        "sensorUnits": "Celsius",
        "dataUnits": "Binary",
        "clockFormat": "Auto",
        "gpuType": "Auto",
        "visualiserBars": 60,
        "audioIncrement": 0.05,
        "brightnessIncrement": 0.1,
        "maxVolume": 1.0,
        "smartScheme": true,
        "defaultPlayer": "Spotify",
        "playerAliases": [
            { "from": "com.github.th_ch.youtube_music", "to": "YT Music" }
        ]
    }
}
```

**Windows differences:**

- **Media (`Players`):** Backed by Windows GSMTC (`GlobalSystemMediaTransportControlsSessionManager`). Per-player volume, window raise/quit, and URI opening are not part of GSMTC.
- **Audio (`maxVolume`):** Capped at `1.0` (100%) by Windows Core Audio.
- **Volume step (`audioIncrement`):** Defaults to `0.05` (5%) for scrolling and shell-owned volume keys, including microphone and app-volume sliders. Set `services.audioIncrement` or use Settings > Services > Volume step to override it; existing explicit values are preserved.
- **Audio visualizer:** `Caelestia.Windows.Audio` supplies WASAPI loopback analysis to the original `Audio.cava` and `Audio.beatTracker` contracts. Lyrics remain unavailable.
- **Profile picture:** Clicking the avatar in the dashboard opens a file picker. The image is copied to `profile-picture` in the shell's state folder (not `~/.face`) and shown ahead of the Windows account picture, which is never changed.
- **CPU temperature:** Windows exposes no unprivileged CPU die temperature. The dashboard reads it from [LibreHardwareMonitor](https://github.com/LibreHardwareMonitor/LibreHardwareMonitor) when it is running elevated with its remote web server on `127.0.0.1:8085`, using the signed [PawnIO](https://pawnio.eu/) driver. Without it the card shows "Unavailable". Setup, once: `winget install namazso.PawnIO` and `winget install LibreHardwareMonitor.LibreHardwareMonitor`, enable Options > Remote Web Server, and start it at sign-in with a scheduled task that runs with highest privileges. LibreHardwareMonitor 0.9.6 ignores its `listenerIp` setting and listens on all interfaces, so add an inbound Windows Firewall block rule for TCP 8085. Loopback traffic is not filtered, so the shell still reads it. Nothing here is installed or configured by the shell.

### `notifs`, `sidebar`, `osd`, and `utilities`

```json
{
    "notifs": {
        "expire": true,
        "fullscreen": "On",
        "defaultExpireTimeout": 5000,
        "fullscreenExpireTimeout": 2000,
        "clearThreshold": 0.3,
        "expandThreshold": 20,
        "actionOnClick": false,
        "groupPreviewNum": 3,
        "openExpanded": false
    },
    "osd": {
        "enabled": true,
        "hideDelay": 2000,
        "enableBrightness": true,
        "enableMicrophone": false
    },
    "sidebar": {
        "enabled": true,
        "showOnHover": false,
        "minHoverThreshold": 200,
        "dragThreshold": 80
    },
    "utilities": {
        "enabled": true,
        "maxToasts": 4,
        "quickToggles": [
            { "id": "wifi", "enabled": true },
            { "id": "bluetooth", "enabled": true },
            { "id": "dnd", "enabled": true }
        ]
    }
}
```

**Windows differences:**

- **Notification mirroring:** Local notifications are persisted to `state\notifs.json`. Mirrored Windows system toasts require one-time user consent in the notification center and are not written to disk (Windows owns their lifetime).
- **Utilities cards and quick toggles:**
  - Quick toggles are limited to `wifi`, `bluetooth`, and `dnd` (Linux `vpn` and quick-toggle `recorder` are hidden).
  - The **Keep-awake (Idle inhibit)** card holds `SetThreadExecutionState` in a helper child process while enabled.
  - The **Screen recorder** card uses `ffmpeg` (`gdigrab`) when `ffmpeg.exe` is on `PATH` and writes fullscreen recordings to `%USERPROFILE%\Videos\Caelestia\recording_<timestamp>.mp4`.

### `session`, `general`, and `lock`

- `session.commands`: Accepts canonical action names (`["logout"]`, `["poweroff"]` / `["shutdown"]`, `["hibernate"]`, `["reboot"]`, `["lock"]`, `["suspend"]`, `["firmware"]`). Only allowlisted session actions execute; arbitrary commands are ignored for safety.
- `general.apps` and `general.idle`: Linux terminal/explorer app arrays (`foot`, `thunar`) and Linux `dpms`/`idle` command arrays are not used on Windows.
- `lock`: Ignored on Windows; locking always invokes the native Windows lock screen (`Win+L`).

Wallpaper Engine settings live in `config/windows.json` under
`windows.wallpaperEngine`: `enabled` defaults to `"auto"`, `picker` accepts
`"engine"`, `"files"` or `"both"`, and `monitor` defaults to `"Monitor0"`.
The background yields completely while Wallpaper Engine owns the desktop.

Windows banner replacement is also configured in `config/windows.json`:

```json
{
  "windows": {
    "notifications": {
      "replaceSystemBanners": true,
      "keepSystemBanners": ["Example.App_123!App"]
    }
  }
}
```

`replaceSystemBanners` defaults to `true`; set it to `false` to leave Windows
banners alone. It takes effect only while system mirroring is active and
Windows has granted access. `keepSystemBanners` defaults to an empty list and
contains exact, case-insensitive Windows app user model IDs (AUMIDs), not app
display names. Windows system toasts matching `Windows.SystemToast.*` and
`Windows.Defender.SecurityCenter` are always excluded. Changes are watched.
For an app not yet present in Windows notification settings, the first
notification can still produce a native banner before its setting is changed.
The journal in `state\banner-suppression.json` records previous `ShowBanner`
values for recovery; user changes made while suppression is active are kept.
The setting does not turn on Focus or remove notifications from Action Center.
Actual immediate Windows banner behavior still needs live verification.

### `background`

Controls the desktop wallpaper surface, desktop clock, and desktop audio visualizer:

```json
{
    "background": {
        "enabled": true,
        "wallpaperEnabled": true,
        "desktopClock": {
            "enabled": false,
            "scale": 1.0,
            "position": "bottom-right",
            "invertColors": false,
            "background": {
                "enabled": false,
                "opacity": 0.7,
                "blur": true
            },
            "shadow": {
                "enabled": true,
                "opacity": 0.7,
                "blur": 0.4
            }
        },
        "visualiser": {
            "enabled": false,
            "autoHide": true,
            "blur": false,
            "rounding": 1,
            "spacing": 1
        }
    }
}
```

**Windows differences:**

- Embedded into the Windows desktop (`Progman` / `WorkerW`, including the Windows 11 24H2 child `WorkerW` hierarchy) via `Quickshell.Windows.DesktopLayer`.
- Supports placing the surface either behind desktop icons (`Behind`, default) or above desktop icons (`Replace`) without altering Explorer's persistent icon settings.
- Supports static wallpaper images with original shader transitions; video wallpapers are not supported because the portable build excludes Qt Multimedia.
- `background.visualiser` loads when an `Audio.cava` provider is present from the native WASAPI analysis plugin.

---

## Tiling and gaps configuration

The Windows extension `windows.tiling` is validated by the tiling facade and
watched through `GlobalConfig`. Defaults are disabled, Observe mode when enabled,
5 DIP inner gaps per window side (10 total), 10 DIP outer gaps, 20 DIP outer
gaps for a single tiled window, and `borderColours: true`. Example:

```json
{"windows":{"tiling":{"enabled":false,"mode":"observe","gapsIn":5,"gapsOut":10,"singleWindowGapsOut":20,"borderColours":true,"include":["exe:notepad.exe"],"exclude":[],"float":["title:*Dialog*"],"monitors":{"*DISPLAY2":false}}}}
```

Rules are wildcard arrays or semicolon-separated strings. `exe:`, `class:` and
`title:` select individual window facts. `float` and disabled-monitor patterns
are exclusions and win over inclusions. Interactive requires a non-empty include
list; live changes stop the session before applying new rules/gaps.
`singleWindowGapsOut` replaces `gapsOut` when exactly one window is tiled on a
monitor/workspace, excluding minimized and maximized windows. Maximized windows
continue to fill the Windows work area. `borderColours` applies scheme primary
and dim onSurfaceVariant borders on Windows 11 build 22000+, following focus
and scheme changes. Colours use upstream 0xe6/0x11 alpha blended against surface.
Disabling colouring/tiling, leaving management or normal shell exit restores
the system default border. Older Windows skips colouring.
See [the full schema](../services/tiling/README.md). Nexus exposes these tiling
and focus-follows-mouse options on its **Window management** page.

Explicit launcher switches override environment variables, which override profile
values. `CAELESTIA_WINDOWS_TILING=off|observe|interactive`,
`CAELESTIA_WINDOWS_TILING_INCLUDED` and `CAELESTIA_WINDOWS_TILING_EXCLUDED`
remain available. Production accepts `-TilingMode`, `-TilingIncluded` and
`-TilingExcluded`; omitted switches allow the profile to apply. Smoke forces off.

The underlying `Quickshell.Windows.Tiling` singleton exposes the following layout and gap properties:

- `enabled` (`bool`, default `false`)
- `layout` (`string`, default `"dwindle"`): `"dwindle"`, `"master"`, or `"scrolling"`
- `gapsIn` (`int`, default `5`): Inner inset per tiled window side in DIPs, 10 total between windows
- `gapsOut` (`int`, default `10`): Outer gap to the monitor work area in DIPs
- `singleWindowGapsOut` (`int`, default `20`): Outer gap with exactly one tiled window
- `borderColours` (`bool`, default `true`): Enable managed-window DWM border colours
- `activeBorderColour`, `inactiveBorderColour` (`color`): Supplied live by the facade from the scheme; unset native colours use the system default
- `preserveSplit` (`bool`, default `true`)
- `smartSplit` (`bool`, default `false`)
- `forceSplit` (`int`, default `0`): `0` (follow cursor/auto), `1` (left/top), `2` (right/bottom)
- `defaultSplitRatio` (`double`, default `1.0`, range `0.1`–`1.9`)
- `masterNewStatus` (`string`, default `"slave"`): `"master"`, `"slave"`, or `"inherit"`
- `masterNewOnTop` (`bool`, default `false`)
- `masterOrientation` (`string`, default `"left"`): `"left"`, `"right"`, `"top"`, `"bottom"`, `"center"`
- `masterFactor` (`double`, default `0.55`, range `0.1`–`0.9`)
- `scrollingColumnWidth` (`double`, default `0.5`, range `0.1`–`1.0`)
- `scrollingCenter` (`string`, default `"overflow"`): `"never"`, `"always"`, `"on-overflow"` / `"overflow"`

The table above lists native backend defaults, also used by the Windows facade.
Layout selection remains a backend option outside this profile schema.

---

## Clipboard history configuration

The `caelestia:clipboard` picker is backed by Windows' native clipboard history.
`windows.clipboard` in `shell.json` gates it; defaults are enabled with no key
bound.

```json
{"windows":{"clipboard":{"enabled":true}}}
```

| Field | Type | Default | Meaning |
| --- | --- | --- | --- |
| `enabled` | bool | `true` | Construct the native clipboard service and allow the picker to open. |

Disabling the option shuts the native backend down and destroys it instead of
merely hiding the picker: the worker thread stops, the WinRT event
subscriptions are revoked, a pending paste is cancelled, retained history and
preview ownership are cleared, no clipboard history is read and the global
shortcut is a no-op. Changes reload live. The shell never enables Windows
clipboard history or changes its settings; when Windows has it off, the picker
offers a button that opens `ms-settings:clipboard`. Password-manager
exclusions, pinned items, size limits and sync remain Windows' decisions.
Preview images and explicitly opened text files are written only inside the
instance's own directory, `<cacheRoot>\clipboard\<pid>-<random>` under the
Quickshell cache directory, and that one directory is deleted on shutdown. See
[the clipboard notes](../services/clipboard/README.md) for the shortcut, IPC
target and remaining live verification.

Add the key bind separately; binding `Super+V` replaces Windows' own Win+V panel
for that chord. See [KEYBINDS.md](KEYBINDS.md).

---

## Focus follows mouse configuration

`windows.focusFollowsMouse` applies Windows' X-Mouse focus tracking while the
shell runs. It is off by default and does not touch the Windows-level setting
until enabled.

```json
{"windows":{"focusFollowsMouse":{"enabled":true,"delay":100,"raise":false}}}
```

| Field | Type | Default | Meaning |
| --- | --- | --- | --- |
| `enabled` | bool | `false` | Apply focus tracking while the shell runs. |
| `delay` | int | `100` | Milliseconds before focus changes, clamped to 0-5000. |
| `raise` | bool | `false` | Bring the focused window to the top. |

The shell reads the current Windows values before the first change and
restores them when the option is disabled or the shell exits cleanly. A reload's
replacement QML generation shares the process-wide baseline with the old one, so
restarting the shell does not lose the originals. The baseline and the values
the session applies are saved to `runtime\focus-follows-mouse-recovery.json` in
the profile before the first change, and live delay or raise changes rewrite
the applied values. After a supervisor restart following a crash, the baseline
is used only while the system still holds the recorded applied values; if the
user changed the Windows setting while the shell was down, the file is
discarded and the live values become the baseline, so a clean exit does not
restore stale values. Writes do not use `SPIF_UPDATEINIFILE`, so the stored
Windows preference is unchanged; after a crash or forced kill the recovery file
(or the next sign-in) restores it. Changes reload live.
If the option is disabled, the shell never reads or writes the system setting,
so a user who enables X-Mouse in Windows keeps it.

---

## Advanced token configuration (`shell-tokens.json`)

> [!CAUTION]
> Only edit `shell-tokens.json` if you want to customize internal base dimensions, corner radii, font sizes, or animation bezier curves. Invalid token values can break panel layout calculations.

You can place overrides in `%LOCALAPPDATA%\caelestia-windows\config\shell-tokens.json` (or per-monitor in `config\monitors\<monitor_name>\shell-tokens.json`). The scale multipliers in `shell.json` (`appearance.rounding.scale`, `appearance.spacing.scale`, `appearance.padding.scale`, `appearance.font.scale`, `appearance.anim.durations.scale`) multiply against these base token values.
