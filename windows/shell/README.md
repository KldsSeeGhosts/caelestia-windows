# Windows shell entry

`shell-live` stages the integrated combined graph with one original
`ContentWindow` on every Qt screen, including monitor arrival/removal. Each
full-screen drawer has four AppBar reservations: the bar width on the left and
the configured border thickness on the top, right and bottom. They release
while upstream's fullscreen detection hides the frame. The original desktop
background is enabled on every monitor and yields to Wallpaper Engine. The
desktop clock defaults off. Workspaces, native workspace
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
  desktop clock off and tiling disabled with 10/10 DIP gaps. Native Config watches edits.
- `config/keybinds.json`: shipped `defaults/windows/keybinds.json`. The backend
  watches edits; see [KEYBINDS.md](../docs/KEYBINDS.md).
- `config/windows.json`: `{"windows":{"hideTaskbar":false,"restartOnCrash":true}}`.
  These supervisor settings apply at the next launch.

The first launch provisions the pinned Caelestia CLI and Python dependencies in
`scheme/venv` under this profile. Use `-SkipSchemeRuntime` to keep the fixed
palette. Wallpaper Engine discovery and preview colour matching share the
combined services; its options are watched under `windows.wallpaperEngine` in
`config/windows.json`.

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
tiler before enabling control. `windows.tiling` in `shell.json` supports live rules/gaps/mode reload; see
[the schema](../services/tiling/README.md). Omitted launcher switches allow the
profile to apply.

## Temporary installed smoke

Install with separate `-Prefix` and `-ProfileRoot` under a temporary directory.
Run its `Start-Caelestia.ps1 -Smoke` in another PowerShell process. After roughly
15 seconds of QML runtime it prints `CAELESTIA_SHELL_LIVE_PASS` and awaits
`Start-Caelestia.ps1 -Command Quit`. The runner has a 60-second timeout. It checks
all monitor-sized drawers and backgrounds (or zero background hosts while
Wallpaper Engine owns the desktop) while disabling input, hardware writes,
workspace dispatch, tiling, recording, keep-awake, physical hotkeys, notification
mirroring and tray interception. AppBar reservations remain enabled and must be
released on quit. Smoke runs directly, without acquiring the desktop supervisor's
session mutex or invoking taskbar/global recovery. Its cleanup removes only its
own exited child's stale AppBars.

When another shell is live, add `-ScreenIndex 1` (verify the secondary Qt screen
index first) to limit the temporary smoke's drawers, backgrounds and reservations
to that display. This flag requires `-Smoke`. Normal starts still use all screens.
The repeatable `windows/scripts/Test-InstalledFrame.ps1 -QtPrefix <Qt-prefix>`
creates a temporary install/profile, verifies the installed smoke loaded one
read-only drawer without changing any work area, measures the four work-area
deltas the isolated component fixture reserves on the secondary display, keeps
those reservations stable through its fullscreen input, quits its children, and
checks that both starting work areas, taskbar flags and existing shell processes
are preserved. A fresh temporary deployment plus the 15-second smoke dominates
its runtime, so the run is bounded at 240 seconds and reports its last phase in
`result.json`; use `-ReusePrefix` for a fixture-only rerun of an interrupted
temporary install and `-SkipSmoke` to omit the installed runtime smoke. Neither
option points at the live installation.

Use the temporary uninstaller with `-Purge` afterward. This checks the deployed
runtime without changing the user's profile or enabling autostart.
