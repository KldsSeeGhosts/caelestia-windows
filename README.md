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

1. Open [Download Caelestia](https://kldsseeghosts.github.io/caelestia-windows/#install) for the Windows x64 ZIP and its SHA-256. It is the same release offered in Nexus. See [public releases](windows/release/PUBLIC-RELEASE.md) for verification and older downloads.
2. Check the published SHA-256, unzip the archive, and double-click `Install.cmd`. The prebuilt package needs no Git, Qt SDK, compiler, or Python for basic use, though it does require Microsoft's free [Visual C++ x64 Redistributable](https://aka.ms/vc14/vc_redist.x64.exe) (14.44.35211.0 or newer).
3. Start **Caelestia** from the Start menu, or run without optional Python provisioning:

   ```powershell
   & "$env:LOCALAPPDATA\Programs\caelestia-windows\Start-Caelestia.ps1" -PreparedSchemeRuntime
   ```

- **Unsigned package:** If Smart App Control, antivirus, or an organizational policy blocks the package, do not disable your protections. See [Release installation](windows/docs/INSTALL-RELEASE.md) for verification and installation, and read the [known limitations](windows/docs/KNOWN-LIMITATIONS.md) before use.
- **Autostart, update, uninstall:** Autostart is off by default (pass `-Autostart` to enable). See [the user guide](windows/docs/USER-GUIDE.md#install-uninstall-and-autostart) for uninstall, `-Purge`, and migrating from `ksg-shell`.

</details>

<details>
  <summary><b>For AI agents (automated install or source build)</b></summary>

Use these non-interactive steps when an agent is asked to install Caelestia for Windows on a user's machine. Never disable Smart App Control, antivirus, or UAC, and never guess credentials or elevate silently.

**Option A: Install the published release**

```powershell
# From a reviewed checkout. This verifies the release and downloads the ZIP,
# but does not install it. Use a new output directory outside the checkout.
$download = Join-Path $env:TEMP ('caelestia-release-' + [guid]::NewGuid().ToString('N'))
powershell.exe -NoProfile -NonInteractive -File windows\ci\Get-NexusBootstrapRelease.ps1 -OutputDirectory $download
```

Extract the downloaded ZIP and use the printed installer command with its
authenticated manifest digest. Add `-NonInteractive` for unattended
installation. Install prerequisites or request the user's approval before
passing `-InstallPrerequisites`.

**Option B: Build and install from source**

```powershell
git clone --recurse-submodules https://github.com/KldsSeeGhosts/caelestia-windows.git
cd caelestia-windows
pwsh -NoProfile -File windows/scripts/Test-Environment.ps1 -Strict -Json
# Follow windows/NATIVE-BUILD.md to build into C:\b-caelestia, then:
pwsh -NoProfile -ExecutionPolicy Bypass -File .\windows\scripts\Install-Caelestia.ps1 -BuildRoot C:\b-caelestia
```

**Start and verify:**

```powershell
& "$env:LOCALAPPDATA\Programs\caelestia-windows\Start-Caelestia.ps1" -PreparedSchemeRuntime
& "$env:LOCALAPPDATA\Programs\caelestia-windows\Start-Caelestia.ps1" -Command State
```

</details>

## Code signing policy

Caelestia's Windows packages are unsigned. Nexus verifies which exact package
the project published and checks its hashes before installation. That does not
give the executables a Windows publisher signature. See the
[code-signing policy](windows/docs/CODE-SIGNING-POLICY.md).

## Usage

The shell adds a vertical bar on the left, a launcher, a dashboard, notifications and OSDs. Its workspaces are Windows virtual desktops. Desktop takeover, autostart, taskbar changes and window tiling are all opt-in. To control the installed instance, run the installed launcher with `-Command Restart`, `-Command Settings` or `-Command Quit`.

- [User guide](windows/docs/USER-GUIDE.md): first run, each part of the shell, and troubleshooting.
- [Keybinds](windows/docs/KEYBINDS.md): default shortcuts and `keybinds.json`.
- [Configuration](windows/docs/CONFIGURATION.md): every `shell.json` option, per-monitor overrides and tiling.
- [Windows shell entry](windows/shell/README.md): the production entry point and its install and run commands.

## Updating

Open **Settings > Updates** in Nexus and choose **Check for updates**. Nexus
offers the same version as the download page. It does not check or install
without your action. Older builds without an updater need one manual install.
See [UPDATES.md](UPDATES.md) for verification and compatibility.

To update manually, run the installer from a newer verified build. If the shell is running, add `-Restart`. The installer then stages the new version, swaps it in, restarts the shell and rolls back if the new version fails to start. Without `-Restart`, quit the shell first.

The installer keeps the previous version. Settings > Updates can roll back to it. Updates keep your configuration, state and user data. See the [release checklist](windows/docs/RELEASE-CHECKLIST.md) and the [user guide](windows/docs/USER-GUIDE.md#install-uninstall-and-autostart).

## Configuration

Configuration files live in `%LOCALAPPDATA%\caelestia-windows\config\`:

- `shell.json` for the shell, bar, launcher, dashboard and services.
- `keybinds.json` for shortcuts.
- `windows.json` for Windows-specific behavior.
- `monitors\<name>\` for per-monitor overrides.

Change settings live in [Nexus](windows/docs/USER-GUIDE.md#nexus-settings-windows), or edit the JSON files. Add only the options you want to change. The shell uses built-in defaults for everything else. The [configuration reference](windows/docs/CONFIGURATION.md) lists every option and notes which ones behave differently on Windows.

The shell owns the screenshot editor and region picker. The bundled capture helper encodes recordings.

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
