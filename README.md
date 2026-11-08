# Caelestia for Windows

A native Windows 11 port of [Caelestia Shell](https://github.com/caelestia-dots/shell). It runs on the Windows Quickshell backend, which was first developed for [ii-windows](https://github.com/nunreasonable/ii-windows).

The port keeps Caelestia's QtQuick/QML interface, Material 3 Expressive shapes (`M3Shapes`), shaders and upstream attribution. Windows services, packaging and documentation live in [`windows/`](windows/README.md). The Quickshell backend and `M3Shapes` are pinned Git submodules, recorded in [`windows/sources.lock.json`](windows/sources.lock.json).

## Install

You need Windows 11 64-bit, a Direct3D 11 GPU and a standard user account. The shell installs per user under `%LOCALAPPDATA%` and does not need administrator rights.

1. Download the Windows x64 ZIP and its checksum from [Releases](https://github.com/KldsSeeGhosts/caelestia-windows/releases).
2. Check the published SHA-256, extract the whole ZIP and run `Install.cmd`. The prebuilt package needs no Git, Qt SDK, compiler or Python for basic use. It does need Microsoft's free x64 C++ Redistributable, version 14.44.35211.0 or newer. If it is missing, the installer links to Microsoft's official download but does not install it for you.
3. Start the shell from the Start menu. To start it without optional Python provisioning, run:

   ```powershell
   & "$env:LOCALAPPDATA\Programs\caelestia-windows\Start-Caelestia.ps1" -PreparedSchemeRuntime
   ```

Preview packages are unsigned. If Smart App Control, antivirus or an organizational policy blocks the preview, do not disable it. [Release installation](windows/docs/INSTALL-RELEASE.md) covers verification, install, update, rollback and policy limits. To build it yourself, see [build from source](windows/NATIVE-BUILD.md). Read the [preview limitations](windows/docs/KNOWN-LIMITATIONS.md) before use.

Autostart is off by default. Pass `-Autostart` to the installer to turn it on. The [user guide](windows/docs/USER-GUIDE.md#install-uninstall-and-autostart) covers requirements, uninstall, `-Purge` and migrating from `ksg-shell`.

## Code signing policy

Free code signing provided by [SignPath.io](https://about.signpath.io), certificate by [SignPath Foundation](https://signpath.org).

Development (`v*-dev.*`) and preview (`v*-preview.*`, `v*-rc.*`) releases are unsigned. The owner's decision is that stable releases (`vMAJOR.MINOR.PATCH`, 1.0.0 or newer) will be signed through SignPath Foundation once a signing pipeline exists. No release is signed today and no stable release exists. The intended signed set is only the files this project builds: Qt DLLs keep Qt's signature, M3Shapes stays third-party, `qs.exe` remains an unsigned upstream build, and `Install.cmd` and the ZIP are not signed. [CODE-SIGNING-POLICY.md](windows/docs/CODE-SIGNING-POLICY.md) lists the intended artifacts, team roles and privacy statement; [SIGNING-ROADMAP.md](windows/docs/SIGNING-ROADMAP.md) lists the pipeline work that must land first.

## Usage

The shell adds a vertical bar on the left, a launcher, a dashboard, notifications and OSDs. Its workspaces are Windows virtual desktops. Desktop takeover, autostart, taskbar changes and window tiling are all opt-in. To control the installed instance, run the installed launcher with `-Command Restart`, `-Command Settings` or `-Command Quit`.

- [User guide](windows/docs/USER-GUIDE.md): first run, each part of the shell, and troubleshooting.
- [Keybinds](windows/docs/KEYBINDS.md): default shortcuts and `keybinds.json`.
- [Configuration](windows/docs/CONFIGURATION.md): every `shell.json` option, per-monitor overrides and tiling.
- [Windows shell entry](windows/shell/README.md): the production entry point and its install and run commands.

## Updating

There is no remote update feed yet. To update, run the installer from a newer build. If the shell is running, add `-Restart`. The installer then stages the new version, swaps it in, restarts the shell and rolls back if the new version fails to start. Without `-Restart`, quit the shell first.

The installer keeps the previous version. Settings > Updates can roll back to it. Updates keep your configuration, state and user data. See the [release checklist](windows/docs/RELEASE-CHECKLIST.md) and the [user guide](windows/docs/USER-GUIDE.md#install-uninstall-and-autostart).

## Configuration

Configuration files live in `%LOCALAPPDATA%\caelestia-windows\config\`:

- `shell.json` for the shell, bar, launcher, dashboard and services.
- `keybinds.json` for shortcuts.
- `windows.json` for Windows-specific behavior.
- `monitors\<name>\` for per-monitor overrides.

Change settings live in [Nexus](windows/docs/USER-GUIDE.md#nexus-settings-windows), or edit the JSON files. Add only the options you want to change. The shell uses built-in defaults for everything else. The [configuration reference](windows/docs/CONFIGURATION.md) lists every option and notes which ones behave differently on Windows.

## FAQ

**Is this the Linux version of Caelestia?** No. This repository is the Windows 11 port. It keeps Caelestia's QML interface and animations. For Linux and Hyprland, use [upstream Caelestia](https://github.com/caelestia-dots/shell).

**Do I need Hyprland, a Linux desktop or WSL?** No. The shell runs natively on Windows, and DWM composites application windows.

**Do I need administrator rights?** No. Install, update, rollback and uninstall all run per user.

**Does it replace Explorer, the taskbar or my tiler automatically?** No. Desktop takeover and tiling are opt-in, and only one tiling manager can be active at a time. See [troubleshooting](windows/docs/USER-GUIDE.md#troubleshooting).

**Does it support Windows 10?** No. It requires Windows 11 64-bit.

**How does it differ from Caelestia on Linux?** The [user guide](windows/docs/USER-GUIDE.md#what-differs-from-linux-caelestia-and-why) lists each difference, such as the lock screen, workspaces and the system tray.

**Where are the logs?** See [where logs live](windows/docs/USER-GUIDE.md#where-logs-live). Remove personal data before you share logs.

## Credits

The interface is [Caelestia Shell](https://github.com/caelestia-dots/shell) by soramanew and contributors (GPL-3.0). The Windows platform layer comes from the Windows Quickshell work for [ii-windows](https://github.com/nunreasonable/ii-windows) (LGPL-3.0), through this port's backend fork. The shapes come from [m3shapes](https://github.com/soramanew/m3shapes).

[Windows credits and attribution](windows/README.md#credits-and-attribution) and [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md) list all copyright holders, licenses and bundled notices. Parts of the Windows port were written with AI assistance under the maintainer's direction and review. Contributors are responsible for the code and documentation they submit.

## Documentation

- [Windows overview and architecture](windows/README.md)
- [Native Windows build instructions](windows/NATIVE-BUILD.md)
- [Milestones and acceptance criteria](windows/ROADMAP.md)
- [Source revisions](windows/sources.lock.json)
- [Contributing](CONTRIBUTING.md)
- [Release checklist](windows/docs/RELEASE-CHECKLIST.md)
