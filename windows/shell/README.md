# Windows shell entry

`shell-live` stages the integrated combined graph with one original
`ContentWindow` on every Qt screen, including monitor arrival/removal. Each
full-screen drawer has an AppBar reservation beside it. The original desktop
background and clock are enabled on every monitor. Workspaces, native workspace
dispatch, active-window display, utilities, M3Shapes, shortcuts, and service
controls share the combined adapters. There is no preview control window.

This is a production entry with loading/install smoke, not a validated shell
release. Hardware controls, hotplug, sleep/wake and daily use need acceptance.

## Install and run

Build as described in [NATIVE-BUILD.md](../NATIVE-BUILD.md), then run from the
repository root:

```powershell
powershell -NoProfile -File windows/scripts/Install-Caelestia.ps1
& "$env:LOCALAPPDATA\Programs\caelestia-windows\Start-Caelestia.ps1"
& "$env:LOCALAPPDATA\Programs\caelestia-windows\Start-Caelestia.ps1" -Command State
& "$env:LOCALAPPDATA\Programs\caelestia-windows\Start-Caelestia.ps1" -Command Restart
& "$env:LOCALAPPDATA\Programs\caelestia-windows\Start-Caelestia.ps1" -Command Quit
powershell -NoProfile -File windows/scripts/Uninstall-Caelestia.ps1
```

Installer flags: `-BuildRoot`, `-QtPrefix`, `-VCRuntimeRoot`, `-Prefix`,
`-ProfileRoot`, and opt-in `-Autostart`. Installation does not launch the shell.
Uninstall accepts `-Prefix` and optional `-Purge`; ordinary uninstall preserves
configuration. All IPC commands select this installation's exact QML path.

The deployed runtime includes Qt, CRT, portable Caelestia and M3Shapes plugins,
fonts and license notices. Normal launches retain PATH for applications. Qt
uses Direct3D 11; smoke excludes developer PATH entries.

## Profile and controllers

The stable profile defaults to `%LOCALAPPDATA%\caelestia-windows`. First launch
seeds these files once, preserving edits across restart/update/uninstall:

- `config/shell.json`: integrated combined Live defaults, with background and
  desktop clock on. Native Config watches edits.
- `config/keybinds.json`: shipped `defaults/windows/keybinds.json`. The backend
  watches edits; see [KEYBINDS.md](../docs/KEYBINDS.md).
- `config/windows.json`: `{"windows":{"hideTaskbar":false,"restartOnCrash":true}}`.
  These supervisor settings apply at the next launch.

State, cache, data, runtime and logs remain in that profile. Normal and smoke
runs capture `logs/shell.stdout.log` and `logs/shell.stderr.log`; the watchdog
records its durable snapshot/status under `runtime/supervisor-<id>/`.
Quickshell also retains native instance bookkeeping under
`%LOCALAPPDATA%\quickshell`.

Taskbar hiding is opt-in. The watchdog restarts crashes with bounded backoff,
restores its owned desktop changes on exit, and never starts a second tiler.
`Restore-Desktop.ps1` is the emergency recovery command; restarting Explorer
requires its separate explicit flag.

Tiling defaults off. `Start-Caelestia.ps1 -TilingMode Observe` enables observation;
`-TilingMode Interactive -TilingIncluded '<application-patterns>'` opts into
control. `-TilingExcluded` supplies the denylist. Coordinate with the existing
tiler before enabling control. Tiling configuration in `shell.json` is deferred.

## Temporary installed smoke

Install with separate `-Prefix` and `-ProfileRoot` under a temporary directory.
Run its `Start-Caelestia.ps1 -Smoke` in another PowerShell process. After roughly
15 seconds of QML runtime it prints `CAELESTIA_SHELL_LIVE_PASS` and awaits
`Start-Caelestia.ps1 -Command Quit`. The runner has a 60-second timeout. It checks
all monitor-sized drawers and backgrounds while disabling input, hardware writes,
workspace dispatch, tiling, recording, keep-awake, physical hotkeys, notification
mirroring and tray interception. AppBar reservations remain enabled and must be
released on quit. Smoke forces taskbar hiding off even with edited settings.

Use the temporary uninstaller with `-Purge` afterward. This checks the deployed
runtime without changing the user's profile or enabling autostart.
