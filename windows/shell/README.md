# Windows shell entry

`shell-live` reuses the combined manifest and Windows service facades, replacing
only the entry point and screen-list service. `Variants` over
`Quickshell.screens` owns one original `ContentWindow` per monitor, anchored to
all four edges. Monitor arrival/removal updates windows and `ShellState`
together. There is no preview control window. Live controls are the default;
the session drawer contains explicit Confirm/Cancel controls.

Use [REPORT.md](../../REPORT.md) for install, launch, IPC and uninstall commands.
This entry is intended for daily use, but the quick smoke is not full shell
release acceptance.

## Profile and runtime

The installer defaults to `%LOCALAPPDATA%\Programs\caelestia-windows`.
`Start-Caelestia.ps1` runs its deployed `qs.exe`, Qt, CRT and portable plugins,
without requiring the development build or Qt on PATH. Normal launches preserve
the user's PATH for launched applications; smoke excludes developer PATH entries.
Qt uses Direct3D 11.

The stable profile defaults to `%LOCALAPPDATA%\caelestia-windows`:

- `config/shell.json`: seeded from the combined Live configuration on first
  launch only. User edits survive restarts, updates and ordinary uninstall.
  The native Config watcher reloads edits.
- `state`, `cache`, `data`, `runtime`: explicit Caelestia/Quickshell overrides.
- `logs`: captured stdout/stderr when using `-Wait` or `-Smoke`.

An alternate `-ProfileRoot` is recorded at installation, including in the QML
directory pragmas. Use a separate profile with a temporary `-Prefix` for smoke.
Quickshell still keeps its native instance discovery/log bookkeeping under
`%LOCALAPPDATA%\quickshell`; the shell does not write Linux `~/.config` paths.

Normal startup observes the adapted services and enables their reviewed Live
gates, including the tray hook and session requests. Notification access
requires the existing explicit history-panel consent action. `-Smoke` disables
all native write/launch/session/mirror gates and tray interception, disables
window input, opens session/dashboard content on every monitor, checks geometry,
prints `CAELESTIA_SHELL_LIVE_PASS`, and exits after about ten seconds of QML
runtime. Initial QML compilation can add startup time.

## Integration seams

- **AppBar:** add the future per-monitor exclusion controller beside
  `ContentWindow` in `shell.qml`, using `scope.modelData` and `content.bar`.
  Preserve full-monitor drawer anchoring and its existing
  `exclusionMode: ExclusionMode.Ignore`.
- **Tiling:** no controller is constructed. The launcher explicitly sets
  `CAELESTIA_WINDOWS_TILING=0`; the tiling branch owns its eventual opt-in and
  coordination with other tilers.
- **Global shortcuts:** no controller is constructed. The launcher sets
  `CAELESTIA_WINDOWS_GLOBAL_SHORTCUTS=0`. Route future actions through the
  `shell.panel(screenName, panelName)` IPC function or the matching
  `ShellState.forScreen(screen)` state. Accepted panel names are `launcher`,
  `dashboard`, `session`, `sidebar`, and `utilities`.

These are reserved integration points, not claims that the future controllers
already consume those environment variables. The combined adapters retain their
current unavailable workspaces/active-window contracts.

`shell.state()` reports all window/screen dimensions and service gates.
`shell.restart()` performs a hard QML reload; `shell.quit()` exits the selected
instance. The installed launcher selects the exact QML path for each IPC call
and prevents duplicate launches of that path.
