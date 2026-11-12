# Caelestia for Windows

Caelestia's desktop shell, running natively on Windows 11.

> [!NOTE]
> This is an **unofficial** Windows port of [Caelestia Shell](https://github.com/caelestia-dots/shell), built on top of the Windows Quickshell backend first created for [ii-windows](https://github.com/nunreasonable/ii-windows). It is not made or supported by soramanew, the Caelestia contributors, or outfoxxed. Please open Windows issues here rather than on the upstream Linux repos.

## Overview

Caelestia for Windows brings [Caelestia Shell](https://github.com/caelestia-dots/shell) to Windows 11 without WSL, Linux, or a replacement compositor. It keeps Caelestia's original QtQuick/QML components, `M3Shapes` expressive shapes, shaders, and spring animations, while swapping the Linux/Hyprland platform hooks for native Windows APIs through [caelestia-quickshell-windows](https://github.com/KldsSeeGhosts/caelestia-quickshell-windows) (forked from [nunreasonable/quickshell](https://github.com/nunreasonable/quickshell)).

<details>
  <summary>What is included and how it works on Windows</summary>

- **Left vertical bar and drawers:** Workspace indicators on Windows virtual desktops, active window title, system tray icons shared with Explorer, clock, status icons, popouts, notifications, OSDs, and a session menu.
- **Launcher and dashboard:** Instant search across Windows `AppsFolder` and Start menu shortcuts, command actions (`>`), calculator (`> calc`), wallpaper picker (`> wallpaper`), media controls via Windows GSMTC, calendar, weather, and hardware performance graphs.
- **Wallpaper and Material You colours:** Caelestia's wallpaper surface and shader transitions, plus dynamic Material You palettes generated from your wallpaper.
- **Built-in DWM tiling (opt-in):** `dwindle`, `master`, and `scrolling` layouts over normal Windows windows, with configurable gaps and per-app rules. Desktop takeover, taskbar hiding, and autostart all stay off until you turn them on.
- **Native Windows services:** Core Audio, WlanAPI Wi-Fi, WinRT Bluetooth, hardware/software brightness, Windows notification mirroring, and in-process virtual desktop COM control (Windows 11 24H2+).

</details>

## Install

Requirements: Windows 11 64-bit (24H2 or newer recommended for virtual desktop switching), a Direct3D 11 GPU, and a standard user account. Everything installs per user under `%LOCALAPPDATA%` with no admin rights required (unless you still need Microsoft's Visual C++ x64 Redistributable).

<details open>
  <summary><b>For humans (prebuilt release)</b></summary>

1. Download the recommended Windows x64 ZIP and its checksum from the [verified public release table](windows/release/PUBLIC-RELEASE.md) (it pins the reviewed `0.1.0-preview.2` preview rather than GitHub's generic latest release; newer development builds live on [GitHub Releases](https://github.com/KldsSeeGhosts/caelestia-windows/releases)).
2. Check the published SHA-256, unzip the archive, and double-click `Install.cmd`. The prebuilt package needs no Git, Qt SDK, compiler, or Python for basic use, though it does require Microsoft's free [Visual C++ x64 Redistributable](https://aka.ms/vc14/vc_redist.x64.exe) (14.44.35211.0 or newer).
3. Start **Caelestia** from the Start menu, or run without optional Python provisioning:

   ```powershell
   & "$env:LOCALAPPDATA\Programs\caelestia-windows\Start-Caelestia.ps1" -PreparedSchemeRuntime
   ```

- **Unsigned preview note:** Preview packages are unsigned. If Smart App Control, antivirus, or an organizational policy blocks a preview, do not disable your protections. See [Release installation](windows/docs/INSTALL-RELEASE.md) for verification, install, update, rollback, and policy limits, and read [preview limitations](windows/docs/KNOWN-LIMITATIONS.md) before use.
- **Autostart, update, uninstall:** Autostart is off by default (pass `-Autostart` to enable). See [the user guide](windows/docs/USER-GUIDE.md#install-uninstall-and-autostart) for uninstall, `-Purge`, and migrating from `ksg-shell`.

</details>

<details>
  <summary><b>For AI agents (automated install or source build)</b></summary>

Use these non-interactive steps when an agent is asked to install Caelestia for Windows on a user's machine. Never disable Smart App Control, antivirus, or UAC, and never guess credentials or elevate silently.

**Option A: Install from the verified public release (`v0.1.0-preview.2`)**

```powershell
# 1. Read windows/release/public-release.json for the exact asset URL and SHA-256
$zipUrl = 'https://github.com/KldsSeeGhosts/caelestia-windows/releases/download/v0.1.0-preview.2/caelestia-windows-0.1.0-preview.2-windows-x64.zip'
$expectedSha = 'b74649cbebd7d3e4d188f9882db8921cda9dd792344a80698969b16d53f91715'
$tmp = Join-Path $env:TEMP 'caelestia-install-preview2'
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
Invoke-WebRequest -Uri $zipUrl -OutFile "$tmp\caelestia.zip"
if ((Get-FileHash -Algorithm SHA256 "$tmp\caelestia.zip").Hash.ToLowerInvariant() -ne $expectedSha) { throw 'SHA-256 mismatch' }
Expand-Archive -Path "$tmp\caelestia.zip" -DestinationPath $tmp -Force

# 2. Verify and install per user (pass -InstallPrerequisites if VC++ x64 14.44.35211.0+ is missing and the user approves UAC)
$bundle = (Get-ChildItem -Path $tmp -Directory | Select-Object -First 1).FullName
powershell -NoProfile -ExecutionPolicy Bypass -File "$bundle\Install-CaelestiaRelease.ps1" -NonInteractive
```

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
& "$env:LOCALAPPDATA\Programs\caelestia-windows\Start-Caelestia.ps1" -PreparedSchemeRuntime
& "$env:LOCALAPPDATA\Programs\caelestia-windows\Start-Caelestia.ps1" -Command State
```

</details>

## Code signing policy

Free code signing provided by [SignPath.io](https://about.signpath.io), certificate by [SignPath Foundation](https://signpath.org).

Development (`v*-dev.*`) and preview (`v*-preview.*`, `v*-rc.*`) releases are unsigned. My plan is that stable releases (`vMAJOR.MINOR.PATCH`, 1.0.0 or newer) will be signed through SignPath Foundation once a signing pipeline exists. No release is signed today and no stable release exists. The intended signed set is only the files this project builds: Qt DLLs keep Qt's signature, M3Shapes stays third-party, `qs.exe` remains an unsigned upstream build, and `Install.cmd` and the ZIP are not signed. [CODE-SIGNING-POLICY.md](windows/docs/CODE-SIGNING-POLICY.md) lists the intended artifacts, team roles and privacy statement; [SIGNING-ROADMAP.md](windows/docs/SIGNING-ROADMAP.md) lists the pipeline work that must land first.

## Usage

The shell adds a vertical bar on the left, a launcher, a dashboard, notifications and OSDs. Its workspaces are Windows virtual desktops. Desktop takeover, autostart, taskbar changes and window tiling are all opt-in. To control the installed instance, run the installed launcher with `-Command Restart`, `-Command Settings` or `-Command Quit`.

- [User guide](windows/docs/USER-GUIDE.md): first run, each part of the shell, and troubleshooting.
- [Keybinds](windows/docs/KEYBINDS.md): default shortcuts and `keybinds.json`.
- [Configuration](windows/docs/CONFIGURATION.md): every `shell.json` option, per-monitor overrides and tiling.
- [Windows shell entry](windows/shell/README.md): the production entry point and its install and run commands.

## Updating

The recommended Preview 2 has no automatic updater. Public preview/stable downloads require manual installation. Authenticated development-channel publication is separate and does not activate preview/stable promotion. See [UPDATES.md](UPDATES.md) for current source capabilities and remaining acceptance gates.

To update manually, run the installer from a newer verified build. If the shell is running, add `-Restart`. The installer then stages the new version, swaps it in, restarts the shell and rolls back if the new version fails to start. Without `-Restart`, quit the shell first.

The installer keeps the previous version. Settings > Updates can roll back to it. Updates keep your configuration, state and user data. See the [release checklist](windows/docs/RELEASE-CHECKLIST.md) and the [user guide](windows/docs/USER-GUIDE.md#install-uninstall-and-autostart).

## Configuration

Configuration files live in `%LOCALAPPDATA%\caelestia-windows\config\`:

- `shell.json` for the shell, bar, launcher, dashboard and services.
- `keybinds.json` for shortcuts.
- `windows.json` for Windows-specific behavior.
- `monitors\<name>\` for per-monitor overrides.

Change settings live in [Nexus](windows/docs/USER-GUIDE.md#nexus-settings-windows), or edit the JSON files. Add only the options you want to change. The shell uses built-in defaults for everything else. The [configuration reference](windows/docs/CONFIGURATION.md) lists every option and notes which ones behave differently on Windows.

Screenshots and recording use the shell UI by default. To use the classic Glazier UI, set `"windows": {"capture": {"ui": "classic"}}` in `shell.json`. Explicit saved values stay unchanged.

## FAQ

**Is this the Linux version of Caelestia?** No. This repository is the Windows 11 port. It keeps Caelestia's QML interface and animations. For Linux and Hyprland, use [upstream Caelestia](https://github.com/caelestia-dots/shell).

**Do I need Hyprland, a Linux desktop or WSL?** No. The shell runs natively on Windows, and DWM composites application windows.

**Do I need administrator rights?** No. Install, update, rollback and uninstall all run per user.

**Does it replace Explorer, the taskbar or my tiler automatically?** No. Desktop takeover and tiling are opt-in, and only one tiling manager can be active at a time. See [troubleshooting](windows/docs/USER-GUIDE.md#troubleshooting).

**Does it support Windows 10?** No. It requires Windows 11 64-bit.

**How does it differ from Caelestia on Linux?** The [user guide](windows/docs/USER-GUIDE.md#what-differs-from-linux-caelestia-and-why) lists each difference, such as the lock screen, workspaces and the system tray.

**Where are the logs?** See [where logs live](windows/docs/USER-GUIDE.md#where-logs-live). Remove personal data before you share logs.

## Credits

Almost all of the UI design, QML, and animations come from other people's work. This repository connects them and adapts the platform layer for Windows 11.

- **[Caelestia Shell](https://github.com/caelestia-dots/shell)** by [@soramanew](https://github.com/soramanew) and the Caelestia contributors (GPL-3.0) — the shell UI, widgets, motion, and [m3shapes](https://github.com/soramanew/m3shapes) (Apache-2.0), plus [Caelestia CLI](https://github.com/caelestia-dots/cli) for Material You colour generation.
- **[ii-windows](https://github.com/nunreasonable/ii-windows)** and **[nunreasonable/quickshell](https://github.com/nunreasonable/quickshell)** by [@nunreasonable](https://github.com/nunreasonable) (GPL-3.0 / LGPL-3.0) — the original Windows Quickshell backend that made running QML shells natively on Windows possible, and the porting/packaging reference this project grew out of.
- **[Quickshell](https://quickshell.outfoxxed.me)** by [@outfoxxed](https://github.com/outfoxxed) and contributors (LGPL-3.0) — the QtQuick shell toolkit underneath everything.
- **[caelestia-quickshell-windows](https://github.com/KldsSeeGhosts/caelestia-quickshell-windows)** (LGPL-3.0) — our maintained fork of `nunreasonable/quickshell` with Caelestia-specific Windows fixes.
- **Bundled tools, fonts, and notices:** [Windows credits and attribution](windows/README.md#credits-and-attribution) and [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) list all copyright holders, licenses, and bundled notices.

Parts of the Windows port were written with AI assistance under my direction and review. Contributors are responsible for the code and documentation they submit.

## Documentation

- [Windows overview and architecture](windows/README.md)
- [Native Windows build instructions](windows/NATIVE-BUILD.md)
- [Milestones and acceptance criteria](windows/ROADMAP.md)
- [Source revisions](windows/sources.lock.json)
- [Contributing](CONTRIBUTING.md)
- [Release checklist](windows/docs/RELEASE-CHECKLIST.md)
