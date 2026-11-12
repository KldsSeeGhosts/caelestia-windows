# Caelestia for Windows

Caelestia's desktop shell, running natively on Windows 11.

> [!NOTE]
> This is an **unofficial** Windows port of [Caelestia Shell](https://github.com/caelestia-dots/shell), built on top of the Windows Quickshell backend first created for [ii-windows](https://github.com/nunreasonable/ii-windows). It is not made or supported by soramanew, the Caelestia contributors, or outfoxxed. Please open Windows issues here rather than on the upstream Linux repos.

## Overview

Caelestia for Windows brings [Caelestia Shell](https://github.com/caelestia-dots/shell) to Windows 11 without WSL, Linux, or a replacement compositor. It keeps Caelestia's original QtQuick/QML components, `M3Shapes` expressive shapes, shaders, and spring animations, while swapping the Linux/Hyprland platform hooks for native Windows APIs through [caelestia-quickshell-windows](https://github.com/KldsSeeGhosts/caelestia-quickshell-windows) (forked from [nunreasonable/quickshell](https://github.com/nunreasonable/quickshell)).

<details>
  <summary>What is included and how it works on Windows</summary>

- **Left vertical bar and drawers:** Workspace indicators on Windows virtual desktops, active window title, running-apps switcher, system tray icons shared with Explorer, clock, status icons, popouts, notifications, OSDs, and a session menu.
- **Launcher and dashboard:** Instant search across Windows `AppsFolder` and Start menu shortcuts, command actions (`>`), calculator (`> calc`), wallpaper picker (`> wallpaper`), media controls via Windows GSMTC, calendar, weather, and hardware performance graphs.
- **Wallpaper and Material You colours:** Caelestia's wallpaper surface and shader transitions, plus dynamic Material You palettes generated from your wallpaper. Wallpaper Engine underlay integration is opt-in.
- **Built-in DWM tiling (opt-in):** `dwindle`, `master`, and `scrolling` layouts over normal Windows windows, with configurable gaps and per-app rules. Desktop takeover, taskbar hiding, and autostart all stay off until you turn them on.
- **Native Windows services:** Core Audio, WlanAPI Wi-Fi, WinRT Bluetooth, hardware/software brightness, Windows notification mirroring, in-process virtual desktop COM control (Windows 11 24H2+), and a bundled screen capture helper (`caelestia-capture.exe`).

</details>

## Install

Requirements: Windows 11 64-bit (24H2 or newer recommended for virtual desktop switching), a Direct3D 11 GPU, and a standard user account. Everything installs per user under `%LOCALAPPDATA%` with no admin rights required (unless you still need Microsoft's Visual C++ x64 Redistributable).

<details open>
  <summary><b>For humans (prebuilt release)</b></summary>

1. Grab the latest `*-windows-x64.zip` from [GitHub Releases](https://github.com/KldsSeeGhosts/caelestia-windows/releases).
2. Unzip the archive, open that folder, and double-click `Install.cmd` (or run `Install-CaelestiaRelease.ps1` in PowerShell).
   - If Microsoft's **Visual C++ x64 Redistributable** (14.44.35211.0 or newer) is missing, the installer will prompt to download and install it from Microsoft's official link, or you can install it from [aka.ms/vc14/vc_redist.x64.exe](https://aka.ms/vc14/vc_redist.x64.exe).
3. Launch **Caelestia** from the Start menu, or start it from PowerShell:

   ```powershell
   & "$env:LOCALAPPDATA\Programs\caelestia-windows\Start-Caelestia.ps1"
   ```

- **Defender / SmartScreen note:** Previews are currently unsigned, so Windows SmartScreen or Defender may warn on a new build. Click **More info → Run anyway** only after verifying the release checksum, and check [the user guide](windows/docs/USER-GUIDE.md#install-uninstall-and-autostart) for install, `-Autostart`, `-Restart`, `-Purge`, and troubleshooting.

</details>

<details>
  <summary><b>For AI agents (automated install or source build)</b></summary>

Use these non-interactive steps when an agent is asked to install or update Caelestia for Windows on a user's machine. Never disable Smart App Control, antivirus, or UAC, and never guess credentials or elevate silently.

**Option A: Install from the latest GitHub Release ZIP**

```powershell
# 1. Fetch the latest release asset URL and download to a temp folder
$tag = (Invoke-RestMethod 'https://api.github.com/repos/KldsSeeGhosts/caelestia-windows/releases?per_page=1')[0].tag_name
$ver = $tag -replace '^v', '' -replace '-development$', ''
$zipUrl = "https://github.com/KldsSeeGhosts/caelestia-windows/releases/download/$tag/caelestia-windows-$ver-windows-x64.zip"
$tmp = Join-Path $env:TEMP "caelestia-install-$ver"
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
Invoke-WebRequest -Uri $zipUrl -OutFile "$tmp\caelestia.zip"
Expand-Archive -Path "$tmp\caelestia.zip" -DestinationPath $tmp -Force

# 2. Verify and install per user (pass -Restart if Caelestia is already running)
$bundle = (Get-ChildItem -Path $tmp -Directory | Select-Object -First 1).FullName
powershell -NoProfile -ExecutionPolicy Bypass -File "$bundle\Install-CaelestiaRelease.ps1" -NonInteractive
```

If `-NonInteractive` reports a missing Microsoft Visual C++ x64 Redistributable (`14.44.35211.0+`), ask the user to approve UAC and pass `-InstallPrerequisites`, or install from `https://aka.ms/vc14/vc_redist.x64.exe` first.

**Option B: Build and install from source**

```powershell
git clone --recurse-submodules https://github.com/KldsSeeGhosts/caelestia-windows.git
cd caelestia-windows
powershell -NoProfile -File windows/scripts/Test-Environment.ps1 -Strict -Json
# Follow windows/NATIVE-BUILD.md to build into C:\b-caelestia, then:
powershell -NoProfile -ExecutionPolicy Bypass -File .\windows\scripts\Install-Caelestia.ps1 -BuildRoot C:\b-caelestia
```

**Start and verify:**

```powershell
& "$env:LOCALAPPDATA\Programs\caelestia-windows\Start-Caelestia.ps1"
& "$env:LOCALAPPDATA\Programs\caelestia-windows\Start-Caelestia.ps1" -Command State
```

</details>

## Usage and configuration

The bar sits on the left edge of your screen. Workspaces map to Windows virtual desktops, and tiling, taskbar hiding, and desktop takeover only turn on if you ask for them. To control a running instance from PowerShell, pass `-Command Restart`, `-Command Settings`, or `-Command Quit` to `Start-Caelestia.ps1`.

Configuration lives in `%LOCALAPPDATA%\caelestia-windows\config\` (`shell.json`, `keybinds.json`, `windows.json`, and `monitors\<name>\`). You can edit those files directly or change settings live in Nexus (`Settings`).

- [User guide](windows/docs/USER-GUIDE.md) — first run, what every surface does, and troubleshooting
- [Keybinds](windows/docs/KEYBINDS.md) — default shortcuts and `keybinds.json`
- [Configuration](windows/docs/CONFIGURATION.md) — `shell.json`, per-monitor overrides, and tiling
- [Build from source](windows/NATIVE-BUILD.md) — native Windows toolchain (`clang-cl`, Qt 6.11.2, Cargo)

## Credits and attribution

Almost all of the UI design, QML, and animations come from other people's work. This repository connects them and adapts the platform layer for Windows 11.

- **[Caelestia Shell](https://github.com/caelestia-dots/shell)** by [@soramanew](https://github.com/soramanew) and the Caelestia contributors (GPL-3.0) — the shell UI, widgets, motion, and [m3shapes](https://github.com/soramanew/m3shapes) (Apache-2.0), plus [Caelestia CLI](https://github.com/caelestia-dots/cli) for Material You colour generation.
- **[ii-windows](https://github.com/nunreasonable/ii-windows)** and **[nunreasonable/quickshell](https://github.com/nunreasonable/quickshell)** by [@nunreasonable](https://github.com/nunreasonable) (GPL-3.0 / LGPL-3.0) — the original Windows Quickshell backend that made running QML shells natively on Windows possible, and the porting/packaging reference this project grew out of.
- **[Quickshell](https://quickshell.outfoxxed.me)** by [@outfoxxed](https://github.com/outfoxxed) and contributors (LGPL-3.0) — the QtQuick shell toolkit underneath everything.
- **[caelestia-quickshell-windows](https://github.com/KldsSeeGhosts/caelestia-quickshell-windows)** (LGPL-3.0) — our maintained fork of `nunreasonable/quickshell` with Caelestia-specific Windows fixes.
- **Bundled tools, fonts, and notices:** [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) and [windows/README.md](windows/README.md#credits-and-attribution) list every copyright holder, license, and bundled component (including `caelestia-capture` / Glazier, Qt 6, Google Sans Flex, Rubik, Cascadia Code / Nerd Fonts, and Material Symbols).

Parts of the Windows port were written with AI assistance under the maintainer's direction and review.

## FAQ

**Is this Linux Caelestia?** No, this is the Windows 11 port. For Linux and Hyprland, use [caelestia-dots/shell](https://github.com/caelestia-dots/shell).

**Do I need Hyprland, WSL, or admin rights?** No. Everything runs natively on Windows 11 under your user account, and DWM handles window compositing.

**Does it replace Explorer, the taskbar, or my tiler automatically?** No. Desktop takeover, taskbar hiding, and window tiling are all opt-in. If you enable Caelestia's tiler, close other tilers like Komorebi, GlazeWM, or FancyZones first.

**Does it support Windows 10?** No. Windows 11 64-bit is required.

**Where are the logs?** See [where logs live](windows/docs/USER-GUIDE.md#where-logs-live). Strip any personal info before sharing them.

## Documentation

- [Windows overview and architecture](windows/README.md)
- [Native Windows build instructions](windows/NATIVE-BUILD.md)
- [Milestones and acceptance criteria](windows/ROADMAP.md)
- [Source revisions](windows/sources.lock.json)
- [Contributing](CONTRIBUTING.md)
- [Release checklist](windows/docs/RELEASE-CHECKLIST.md)

## Upstream Linux documentation

> The following is upstream Caelestia's README, preserved for Linux and Hyprland users. It does not describe this Windows port. The Windows sections above take precedence.

<h1 align=center>caelestia-shell</h1>

<div align=center>

![GitHub last commit](https://img.shields.io/github/last-commit/caelestia-dots/shell?style=for-the-badge&labelColor=101418&color=9ccbfb)
![GitHub Repo stars](https://img.shields.io/github/stars/caelestia-dots/shell?style=for-the-badge&labelColor=101418&color=b9c8da)
![GitHub repo size](https://img.shields.io/github/repo-size/caelestia-dots/shell?style=for-the-badge&labelColor=101418&color=d3bfe6)
[![Ko-Fi donate](https://img.shields.io/badge/donate-kofi?style=for-the-badge&logo=ko-fi&logoColor=ffffff&label=ko-fi&labelColor=101418&color=f16061&link=https%3A%2F%2Fko-fi.com%2Fsoramane)](https://ko-fi.com/soramane)
[![Discord invite](https://img.shields.io/badge/dynamic/json?url=https%3A%2F%2Fdiscordapp.com%2Fapi%2Finvites%2FBGDCFCmMBk%3Fwith_counts%3Dtrue&query=approximate_member_count&style=for-the-badge&logo=discord&logoColor=ffffff&label=discord&labelColor=101418&color=96f1f1&link=https%3A%2F%2Fdiscord.gg%2FBGDCFCmMBk)][discord]

</div>

https://github.com/user-attachments/assets/0840f496-575c-4ca6-83a8-87bb01a85c5f

## Components

- Widgets: [`Quickshell`](https://quickshell.outfoxxed.me)
- Window manager: [`Hyprland`](https://hypr.land)
- Dots: [`caelestia`][dots-repo]

## Installation

> [!NOTE]
> This repo is for Caelestia's desktop shell only. If you want installation instructions
> for the entire dotfiles (which include this shell), head to [the main repo][dots-repo] instead.

### Arch Linux

> [!WARNING]
> If you want to make your own changes/tweaks to the shell, do NOT edit the files installed by the AUR
> package. Instead, follow the instructions in the [manual installation section](#manual-installation).

The shell is available from the AUR as `caelestia-shell`. You can install it with an AUR helper (recommended),
like [`paru`](https://github.com/morganamilo/paru), or by manually downloading the PKGBUILD and running `makepkg -si`.

A package following the latest commit also exists as `caelestia-shell-git`. This is bleeding-edge
and likely to be unstable/have bugs. Regular users are recommended to use the stable package (`caelestia-shell`).

### Nix

You can run the shell directly via `nix run`:

```sh
nix run github:caelestia-dots/shell#with-cli
```

Or add it to your system configuration:

```nix
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixos-unstable";

    caelestia-shell = {
      url = "github:caelestia-dots/shell";
      inputs.nixpkgs.follows = "nixpkgs";
    };
  };
}
```

For full functionality, use `caelestia-shell.packages.<system>.with-cli`, which can be added to your
`environment.systemPackages`, `users.users.<username>.packages`, `home.packages` if using home-manager,
or a devshell. The `default` package does not include the CLI.
You can then run the shell with `caelestia-shell`.

For home-manager, you can also use Caelestia's Home Manager module (explained in [the configuration section](#home-manager-module)), which installs and configures the shell and CLI.

### Manual installation

Dependencies:

- [`caelestia-cli`](https://github.com/caelestia-dots/cli)
- [`quickshell-git`](https://git.outfoxxed.me/quickshell/quickshell) - this has to be the git version, not the latest tagged version
- `glibc`
- `gcc-libs`
- [`ddcutil`](https://github.com/rockowitz/ddcutil)
- [`brightnessctl`](https://github.com/Hummer12007/brightnessctl)
- [`libcava`](https://github.com/LukashonakV/cava)
- [`networkmanager`](https://gitlab.freedesktop.org/NetworkManager/NetworkManager)
- [`lm_sensors`](https://github.com/lm-sensors/lm-sensors)
- [`aubio`](https://github.com/aubio/aubio)
- [`libpipewire`](https://github.com/PipeWire/pipewire)
- [`libqalculate`](https://github.com/Qalculate/libqalculate)
- [`power-profiles-daemon`](https://gitlab.freedesktop.org/upower/power-profiles-daemon)
- [`ttf-material-symbols-variable`](https://github.com/google/material-design-icons)
- [`ttf-rubik-vf`](https://github.com/googlefonts/rubik)
- [`ttf-cascadia-code-nerd`](https://github.com/ryanoasis/nerd-fonts)
- `qt6-base`
- `qt6-declarative`
- `qt6-imageformats`
- `qt6-multimedia`
- [`qt6-m3shapes-git`](https://github.com/soramanew/m3shapes)
- [`swappy`](https://github.com/jtheoof/swappy)
- [`fish`](https://github.com/fish-shell/fish-shell)
- [`bash`](https://www.gnu.org/software/bash)

Build dependencies:

- [`cmake`](https://gitlab.kitware.com/cmake/cmake)
- [`ninja`](https://github.com/ninja-build/ninja)
- `qt6-shadertools`

> [!IMPORTANT]
> The commands below (and in the "Updating" section) assume `$XDG_CONFIG_HOME` is set.
> If it is unset, substitute it with the path to your config folder (typically `~/.config`).

To install the shell manually, install all dependencies and clone this repo to `$XDG_CONFIG_HOME/quickshell/caelestia`.
Then build and install using CMake.

```sh
cd $XDG_CONFIG_HOME/quickshell
git clone https://github.com/caelestia-dots/shell.git caelestia

cd caelestia
cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/
cmake --build build
sudo cmake --install build
```

> [!TIP]
> You can customise the installation location via the CMake flags `INSTALL_LIBDIR`, `INSTALL_QMLDIR`, and
> `INSTALL_QSCONFDIR` for the libraries (e.g. the version helper), QML plugin, and Quickshell config directories
> respectively. If you set the `INSTALL_LIBDIR` flag, the `CAELESTIA_LIB_DIR` variable must also be set to
> the same directory in your system's environment.
>
> For example, installing to `~/.config/quickshell/caelestia` for easy local changes:
>
> ```sh
> mkdir -p ~/.config/quickshell/caelestia
> cmake -B build -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/ -DINSTALL_QSCONFDIR="$HOME/.config/quickshell/caelestia"
> cmake --build build
> sudo cmake --install build
> sudo chown -R $USER ~/.config/quickshell/caelestia
> ```

## Usage

You can start the shell by running `caelestia shell -d` (preferred) or `qs -c caelestia -n -d`.
You may omit `-d` from the command to keep the shell attached to the current terminal if necessary,
though you likely want it to be detached (so it doesn't close when the terminal is closed).

If using the [Caelestia dotfiles][dots-repo], the shell will be autostarted on login
via a `hl.on("hyprland.start", ...)` function in the Hyprland config.

### Shortcuts/IPC

All keybinds are accessible via Hyprland [global shortcuts](https://wiki.hypr.land/Configuring/Basics/Binds/#dbus-global-shortcuts).
If using the [Caelestia dotfiles][dots-repo], the keybinds are already configured for you.
Otherwise, the [`keybinds.lua`](https://github.com/caelestia-dots/caelestia/blob/main/hypr/hyprland/keybinds.lua#L63-L67) file
contains an example of how to use global shortcuts.

All IPC commands can be accessed via `caelestia shell ...`, for example:

```sh
caelestia shell mpris getActive trackTitle
```

You can view the list of available IPC commands by running `caelestia shell -s`.

### PFP/Wallpapers

The profile picture for the dashboard is read from the file `~/.face`. You can set it by clicking it in the dashboard,
or by manually copying or symlinking your image to the path.

The wallpapers for the wallpaper switcher are read from `~/Pictures/Wallpapers`
by default. To change it, modify `paths.wallpaperDir` in `~/.config/caelestia/shell.json`.

To set the wallpaper, you can type `>wallpaper` in the launcher to open the wallpaper switcher.
Alternatively, you can also use `caelestia wallpaper -f <path_to_wallpaper>` to set the wallpaper directly.
Use `caelestia wallpaper -h` for more info about this command.

## Updating

### Packaged install (AUR)

If using the full dotfiles or the CLI, run `caelestia update` to perform a full system update and
update the dots.
Otherwise, if you installed the shell on its own, update your system using your AUR helper (e.g., `paru`).

### Manual install

If you installed the shell manually by cloning the repo, you can update by pulling the changes from git
in the local checkout.

For example, if you installed to `$XDG_CONFIG_HOME/quickshell/caelestia`:

```sh
cd $XDG_CONFIG_HOME/quickshell/caelestia
git pull
```

## Configuring

All configuration options belong in `~/.config/caelestia/shell.json`. This file is _not_ created by
default; you must create it manually. Options that you omit from the config file will use their default
values.

### Per-monitor configuration

You can configure per-monitor options in `~/.config/caelestia/monitors/<monitor_name>/shell.json`.
List the names of your available monitors by running:

```sh
hyprctl monitors -j | jq -r '.[].name'
```

Options set in these files will **override** the respective options in the global config. Any options not present in
per-monitor configs will inherit their values from the global config.

For example, to automatically hide the bar on the monitor named `DP-1`:

**`~/.config/caelestia/monitors/DP-1/shell.json`**

```json
{
    "bar": {
        "persistent": false
    }
}
```

> [!NOTE]
> Not all options respect per-monitor overrides. Most notably, the following options will only read
> from the global config, and ignore the respective option in per-monitor config files.
>
> <details><summary>Ignored options</summary>
>
> - `appearance`: `anim.*`, `transparency.*`
> - `bar.tray`: `hiddenIcons`, `iconSubs`
> - `bar.workspaces`: `ignoredTags`, `specialWorkspaceIcons`, `windowIcons`, `workspaceIcons`
> - `dashboard`: `mediaUpdateInterval`, `resourceUpdateInterval`
> - `general`: `apps.*`, `battery.*`, `idle.*`, `logo`
> - `launcher`: `actionPrefix`, `actions`, `enableDangerousActions`, `favouriteApps`, `hiddenApps`, `specialPrefix`, `useFuzzy.*`, `vimKeybinds`
> - `lock`: `enableFprint`, `enableHowdy`, `maxFprintTries`, `maxHowdyTries`, `triggerHowdyOnWake`
> - `nexus`: `networkRescanInterval`
> - `notifs`: `actionOnClick`, `defaultExpireTimeout`, `expire`, `fullscreen`, `fullscreenExpireTimeout`
> - `paths`: `lyricsDir`, `wallpaperDir`
> - `services`: `audioIncrement`, `brightnessIncrement`, `clockFormat`, `dataUnits`, `defaultPlayer`, `gpuType`, `lyricsBackend`, `maxVolume`, `playerAliases`, `sensorUnits`, `smartScheme`, `visualiserBars`, `weatherLocation`, `weatherUnits`
> - `utilities`: `toasts.*`, `vpn.*`
>
> </details>

### Example configuration

> [!WARNING]
> The example configuration includes **ALL** configuration options in `shell.json`. It is
> **not** recommended to copy and paste this entire configuration into `shell.json`,
> as options or their default values may change across updates, resulting in a stale config.
>
> This is meant to serve as a reference of all the available options, and you should
> <ins>only add the ones you want to change</ins> to `shell.json`.

<details><summary>Example config</summary>

```json
{
    "enabled": true,
    "appearance": {
        "deformScale": 1,
        "rounding": {
            "scale": 1
        },
        "spacing": {
            "scale": 1
        },
        "padding": {
            "scale": 1
        },
        "font": {
            "scale": 1,
            "clock": "Rubik",
            "workspaces": "Rubik",
            "headline": {
                "family": "GoogleSansFlex",
                "large": {
                    "size": 32,
                    "weight": 500,
                    "italic": false,
                    "vaxes": { "ROND": 25 }
                },
                "medium": {
                    "size": 28,
                    "weight": 500,
                    "italic": false,
                    "vaxes": { "ROND": 25 }
                },
                "small": {
                    "size": 24,
                    "weight": 500,
                    "italic": false,
                    "vaxes": { "ROND": 25 }
                }
            },
            "title": {
                "family": "GoogleSansFlex",
                "large": {
                    "size": 22,
                    "weight": 500,
                    "italic": false,
                    "vaxes": { "ROND": 25 }
                },
                "medium": {
                    "size": 16,
                    "weight": 500,
                    "italic": false,
                    "vaxes": { "ROND": 25 }
                },
                "small": {
                    "size": 14,
                    "weight": 500,
                    "italic": false,
                    "vaxes": { "ROND": 25 }
                }
            },
            "body": {
                "family": "GoogleSansFlex",
                "large": {
                    "size": 16,
                    "weight": 400,
                    "italic": false,
                    "vaxes": { "ROND": 25 }
                },
                "medium": {
                    "size": 14,
                    "weight": 400,
                    "italic": false,
                    "vaxes": { "ROND": 25 }
                },
                "small": {
                    "size": 12,
                    "weight": 400,
                    "italic": false,
                    "vaxes": { "ROND": 25 }
                }
            },
            "label": {
                "family": "GoogleSansFlex",
                "large": {
                    "size": 14,
                    "weight": 500,
                    "italic": false,
                    "vaxes": { "ROND": 25 }
                },
                "medium": {
                    "size": 12,
                    "weight": 500,
                    "italic": false,
                    "vaxes": { "ROND": 25 }
                },
                "small": {
                    "size": 11,
                    "weight": 400,
                    "italic": false,
                    "vaxes": { "ROND": 25 }
                }
            },
            "mono": {
                "family": "CaskaydiaCove NF",
                "large": {
                    "size": 16,
                    "weight": 400,
                    "italic": false,
                    "vaxes": {}
                },
                "medium": {
                    "size": 14,
                    "weight": 400,
                    "italic": false,
                    "vaxes": {}
                },
                "small": {
                    "size": 12,
                    "weight": 400,
                    "italic": false,
                    "vaxes": {}
                }
            },
            "icon": {
                "family": "Material Symbols Rounded",
                "extraLarge": {
                    "size": 36,
                    "weight": 400,
                    "italic": false,
                    "vaxes": {}
                },
                "large": {
                    "size": 24,
                    "weight": 400,
                    "italic": false,
                    "vaxes": {}
                },
                "medium": {
                    "size": 18,
                    "weight": 400,
                    "italic": false,
                    "vaxes": {}
                },
                "small": {
                    "size": 15,
                    "weight": 400,
                    "italic": false,
                    "vaxes": {}
                }
            }
        },
        "anim": {
            "durations": {
                "scale": 1
            }
        },
        "transparency": {
            "enabled": false,
            "base": 0.85,
            "layers": 0.4
        }
    },
    "general": {
        "logo": "",
        "showOverFullscreen": false,
        "mediaGifSpeedAdjustment": 300,
        "sessionGifSpeed": 0.7,
        "apps": {
            "terminal": ["foot"],
            "audio": ["pwvucontrol"],
            "playback": ["mpv"],
            "explorer": ["thunar"]
        },
        "idle": {
            "lockBeforeSleep": true,
            "inhibitWhenAudio": true,
            "inhibitWhenCharging": false,
            "timeouts": [
                {
                    "timeout": 180,
                    "idleAction": "lock",
                    "inhibitWhenAudio": false,
                    "inhibitWhenCharging": false,
                    "respectInhibitors": true
                },
                {
                    "timeout": 300,
                    "idleAction": "dpms off",
                    "returnAction": "dpms on"
                },
                {
                    "timeout": 600,
                    "idleAction": ["suspendThenHibernate"]
                }
            ]
        },
        "battery": {
            "warnLevels": [
                {
                    "level": 20,
                    "title": "Low battery",
                    "message": "You might want to plug in a charger",
                    "icon": "battery_android_frame_2"
                },
                {
                    "level": 10,
                    "title": "Did you see the previous message?",
                    "message": "You should probably plug in a charger <b>now</b>",
                    "icon": "battery_android_frame_1"
                },
                {
                    "level": 5,
                    "title": "Critical battery level",
                    "message": "PLUG THE CHARGER RIGHT NOW!!",
                    "icon": "battery_android_alert",
                    "critical": true
                }
            ],
            "criticalLevel": 3
        }
    },
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
    },
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
            "showWindowsOnSpecialWorkspaces": true,
            "maxWindowIcons": 5,
            "activeTrail": false,
            "displayType": "shapes",
            "specialDisplayType": "icons",
            "label": "  ",
            "occupiedLabel": "󰮯",
            "activeLabel": "󰮯",
            "capitalisation": "preserve",
            "workspaceIcons": [],
            "specialWorkspaceIcons": [
                {
                    "name": "special",
                    "icon": "star"
                },
                {
                    "name": "communication",
                    "icon": "forum"
                },
                {
                    "name": "music",
                    "icon": "music_cast"
                },
                {
                    "name": "todo",
                    "icon": "checklist"
                },
                {
                    "name": "sysmon",
                    "icon": "monitor_heart"
                }
            ],
            "ignoredTags": ["hide_in_bar", "xwl_popup"],
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
            {
                "id": "lockStatus",
                "enabled": true
            },
            {
                "id": "audio",
                "enabled": false
            },
            {
                "id": "microphone",
                "enabled": false
            },
            {
                "id": "kbLayout",
                "enabled": false
            },
            {
                "id": "network",
                "enabled": true
            },
            {
                "id": "bluetooth",
                "enabled": true
            },
            {
                "id": "battery",
                "enabled": true
            }
        ],
        "entries": [
            {
                "id": "logo",
                "enabled": true
            },
            {
                "id": "workspaces",
                "enabled": true
            },
            {
                "id": "spacer",
                "enabled": true
            },
            {
                "id": "activeWindow",
                "enabled": true
            },
            {
                "id": "spacer",
                "enabled": true
            },
            {
                "id": "tray",
                "enabled": true
            },
            {
                "id": "clock",
                "enabled": true
            },
            {
                "id": "statusIcons",
                "enabled": true
            },
            {
                "id": "power",
                "enabled": true
            }
        ],
        "excludedScreens": []
    },
    "border": {
        "thickness": 10,
        "rounding": 25,
        "smoothing": 20
    },
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
        },
        "actions": [
            {
                "name": "Calculator",
                "icon": "calculate",
                "description": "Do simple math equations (powered by Qalc)",
                "command": ["autocomplete", "calc"],
                "enabled": true,
                "dangerous": false
            },
            {
                "name": "Scheme",
                "icon": "palette",
                "description": "Change the current colour scheme",
                "command": ["autocomplete", "scheme"],
                "enabled": true,
                "dangerous": false
            },
            {
                "name": "Wallpaper",
                "icon": "image",
                "description": "Change the current wallpaper",
                "command": ["autocomplete", "wallpaper"],
                "enabled": true,
                "dangerous": false
            },
            {
                "name": "Variant",
                "icon": "colors",
                "description": "Change the current scheme variant",
                "command": ["autocomplete", "variant"],
                "enabled": true,
                "dangerous": false
            },
            {
                "name": "Random",
                "icon": "casino",
                "description": "Switch to a random wallpaper",
                "command": ["caelestia", "wallpaper", "-r"],
                "enabled": true,
                "dangerous": false
            },
            {
                "name": "Light",
                "icon": "light_mode",
                "description": "Change the scheme to light mode",
                "command": ["setMode", "light"],
                "enabled": true,
                "dangerous": false
            },
            {
                "name": "Dark",
                "icon": "dark_mode",
                "description": "Change the scheme to dark mode",
                "command": ["setMode", "dark"],
                "enabled": true,
                "dangerous": false
            },
            {
                "name": "Shutdown",
                "icon": "power_settings_new",
                "description": "Shutdown the system",
                "command": ["poweroff"],
                "enabled": true,
                "dangerous": true
            },
            {
                "name": "Reboot",
                "icon": "cached",
                "description": "Reboot the system",
                "command": ["reboot"],
                "enabled": true,
                "dangerous": true
            },
            {
                "name": "Logout",
                "icon": "exit_to_app",
                "description": "Log out of the current session",
                "command": ["logout"],
                "enabled": true,
                "dangerous": true
            },
            {
                "name": "Lock",
                "icon": "lock",
                "description": "Lock the current session",
                "command": ["loginctl", "lock-session"],
                "enabled": true,
                "dangerous": false
            },
            {
                "name": "Sleep",
                "icon": "bedtime",
                "description": "Suspend then hibernate",
                "command": ["suspendThenHibernate"],
                "enabled": true,
                "dangerous": false
            },
            {
                "name": "Settings",
                "icon": "settings",
                "description": "Configure the shell",
                "command": ["caelestia", "shell", "nexus", "open"],
                "enabled": true,
                "dangerous": false
            }
        ]
    },
    "lock": {
        "enabled": true,
        "useWallpaper": false,
        "recolourLogo": true,
        "enableFprint": true,
        "maxFprintTries": 3,
        "enableHowdy": true,
        "maxHowdyTries": 3,
        "triggerHowdyOnWake": true,
        "hideNotifs": false,
        "enableSessionControls": true
    },
    "nexus": {
        "wallpapersPerRow": 4,
        "networkRescanInterval": 15000
    },
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
    "services": {
        "weatherLocation": "",
        "weatherUnits": "Auto",
        "sensorUnits": "Celsius",
        "dataUnits": "Binary",
        "clockFormat": "Auto",
        "gpuType": "Auto",
        "visualiserBars": 60,
        "audioIncrement": 0.1,
        "brightnessIncrement": 0.1,
        "maxVolume": 1.0,
        "smartScheme": true,
        "defaultPlayer": "Spotify",
        "playerAliases": [
            { "from": "com.github.th_ch.youtube_music", "to": "YT Music" }
        ],
        "lyricsBackend": "Auto"
    },
    "session": {
        "enabled": true,
        "dragThreshold": 30,
        "vimKeybinds": false,
        "icons": {
            "logout": "logout",
            "shutdown": "power_settings_new",
            "hibernate": "downloading",
            "reboot": "cached"
        },
        "commands": {
            "logout": ["logout"],
            "shutdown": ["poweroff"],
            "hibernate": ["hibernate"],
            "reboot": ["reboot"]
        }
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
        "toasts": {
            "fullscreen": "off",
            "configLoaded": true,
            "chargingChanged": true,
            "gameModeChanged": true,
            "dndChanged": true,
            "audioOutputChanged": true,
            "audioInputChanged": true,
            "capsLockChanged": true,
            "numLockChanged": true,
            "kbLayoutChanged": true,
            "kbLimit": true,
            "vpnChanged": true,
            "nowPlaying": false
        },
        "vpn": {
            "enabled": false,
            "provider": [
                {
                    "name": "wireguard",
                    "interface": "your-connection-name",
                    "displayName": "Wireguard (Your VPN)",
                    "enabled": false
                }
            ]
        },
        "quickToggles": [
            {
                "id": "wifi",
                "enabled": true
            },
            {
                "id": "bluetooth",
                "enabled": true
            },
            {
                "id": "mic",
                "enabled": true
            },
            {
                "id": "settings",
                "enabled": true
            },
            {
                "id": "gameMode",
                "enabled": true
            },
            {
                "id": "dnd",
                "enabled": true
            },
            {
                "id": "vpn",
                "enabled": false
            }
        ]
    },
    "paths": {
        "wallpaperDir": "~/Pictures/Wallpapers",
        "lyricsDir": "~/Music/lyrics/",
        "sessionGif": "root:/assets/kurukuru.gif",
        "mediaGif": "root:/assets/bongocat.gif",
        "noNotifsPic": "root:/assets/dino.png",
        "lockNoNotifsPic": "root:/assets/dino.png"
    }
}
```

</details>

### Advanced configuration

> [!CAUTION]
> Do NOT change any of these options unless you know what you are doing. These options control the
> tokens used internally within the shell, and can cause visual issues if modified incorrectly.
> The available options may change or be removed without notice across versions.

A separate `~/.config/caelestia/shell-tokens.json` file allows editing the internal tokens without
touching the source code of the shell. These tokens affect the dimensions and appearance of visual elements,
including individual rounding, spacing, padding, font size, animation durations and curves, and the sizes of
certain components. The appearance scale values in `shell.json` are multiplied against these base
token values to produce the final computed values.

Per-monitor token overrides are also available at
`~/.config/caelestia/monitors/<monitor_name>/shell-tokens.json`.

### Home Manager Module

For NixOS users, a Home Manager module is also available.

<details><summary><code>home.nix</code></summary>

```nix
programs.caelestia = {
  enable = true;
  systemd = {
    enable = false; # if you prefer starting from your compositor
    target = "graphical-session.target";
    environment = [];
  };
  settings = {
    bar.statusIcons = [
      { id = "lockStatus"; enabled = true; }
      { id = "network"; enabled = true; }
      { id = "bluetooth"; enabled = true; }
      { id = "battery"; enabled = false; }
    ];
    paths.wallpaperDir = "~/Images";
  };
  cli = {
    enable = true; # Also add caelestia-cli to path
    settings = {
      theme.enableGtk = false;
    };
  };
};
```

The module automatically adds the shell to the path with **full functionality**. The CLI is not required; however, you can enable and configure it.

</details>

## FAQ

### Need help or support?

You can join the Caelestia Discord server for assistance and discussion [here][discord].

### I want to make my own changes to the Hyprland config!

Check out the configuring section on the [dots repo](https://github.com/caelestia-dots/caelestia#configuring).

### I want to make my own changes to other stuff!

See the [manual installation](#manual-installation) section for the corresponding repo.

### I want to disable \_\_\_ feature!

Please read the [configuring](#configuring) section.
If there is no corresponding option, make a [feature request](https://github.com/caelestia-dots/shell/issues/new?template=feature.yml).

### How do I make my colour scheme change to match my wallpaper?

Set a wallpaper via `>wallpaper` in the launcher or `caelestia wallpaper`, and set the scheme to the dynamic scheme via
`>scheme` in the launcher or `caelestia scheme set`, e.g.:

```sh
caelestia wallpaper -f <path_to_wallpaper>
caelestia scheme set -n dynamic
```

### My wallpapers aren't showing up in the launcher!

The launcher pulls wallpapers from `~/Pictures/Wallpapers` by default. You can change this in the config. Additionally,
the launcher only shows an odd number of wallpapers at one time. If you only have 2 wallpapers, consider getting more
(or just putting one).

## Credits

Thanks to the Hyprland Discord community (especially the homies in #rice-discussion) for all the help and suggestions
for improving these dots!

A special thanks to [@outfoxxed](https://github.com/outfoxxed) for making Quickshell and the effort put into fixing issues
and implementing various feature requests.

Another special thanks to [@end_4](https://github.com/end-4) for his [config](https://github.com/end-4/dots-hyprland)
which helped me a lot with learning how to use Quickshell.

Finally, another thank you to all the configs I took inspiration from (only one for now):

- [Axenide/Ax-Shell](https://github.com/Axenide/Ax-Shell)

## Stonks 📈

<a href="https://www.star-history.com/#caelestia-dots/shell&Date">
    <picture>
        <source media="(prefers-color-scheme: dark)" srcset="https://api.star-history.com/svg?repos=caelestia-dots/shell&type=Date&theme=dark" />
        <source media="(prefers-color-scheme: light)" srcset="https://api.star-history.com/svg?repos=caelestia-dots/shell&type=Date" />
        <img alt="Star History Chart" src="https://api.star-history.com/svg?repos=caelestia-dots/shell&type=Date" />
    </picture>
</a>

[dots-repo]: https://github.com/caelestia-dots/caelestia
[discord]: https://caelestiashell.com/discord
