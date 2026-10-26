# Windows integration round 3

Branch: `t3/integration-3`, based on `origin/t3/integration-2` (`41ddcefc`).
Backend: `windows/integration-3`, pushed merge
`13b2d0930f798e7a0c006258a3a68824e300b2d6`, from `57163953` plus
`caelestia/windows/global-shortcuts` (`d44760b`). The gitlink and
`sources.lock.json` agree. M3Shapes remains pinned at
`32ad9ce328bb77ed349b40a3be10ee9ea610b8ab`.

## Merges and conflict resolutions

- Production (`f0954432`), merge `203aa191`: unioned staging selections, retained
  integrated documentation and combined capabilities. Production now stages the
  integrated graph, not the round-0 graph: workspaces and dispatch, active window,
  per-monitor AppBar reservation, background/clock, M3Shapes, utilities and shortcuts.
- Takeover (`627006fb`), merge `63a97c86`: retained the background switches and
  independent Combined+Tiling selection while adding supervisor switches. Production
  uses the durable watchdog; `config/windows.json` defaults to taskbar hiding off
  and bounded crash restart on. Recovery scripts are packaged beside the launcher.
- Shortcuts (`d931193d` and `e62beea1`), merge `da7ba109`: unioned the background
  and shortcut daemon plus both manifests; retained the M3Shapes pin and moved the
  backend gitlink to the pushed merge. Restored volume/media/brightness/notification
  service shortcut handlers remain intact. Production targets the focused monitor.
- User guide (`34fb9fd6`), merge `3482604c`: clean docs merge. Resolved verifiable
  installer flags, profile/log paths, IPC, monitor-name discovery and the full
  default keybind table. Remaining TODOs concern unsupported/untested OS versions
  and round-4 dynamic schemes, visualizer and tiling-config details.
- REPORT conflicts are superseded by this integration report. No feature branch
  implementation was discarded. No backend source conflict occurred.

## Production integration

`windows/shell/shell.json` matches the integrated Combined Live configuration,
with production background and desktop clock enabled. First launch seeds
`shell.json`, `keybinds.json` and `windows.json` once under the persistent profile.
Existing files survive reinstall and restart. Tiling remains a separate opt-in:
`-TilingMode Disabled|Observe|Interactive`, `-TilingIncluded`, `-TilingExcluded`.
No shell.json tiling schema was added ahead of round 4.

The installer packages the real M3Shapes module/helper DLL/license, all portable
plugins, Qt/CRT, fonts and the watchdog/recovery scripts. Qt deployment's missing
translation-catalog message is captured as text; native exit status remains the
failure criterion. No autostart option was used in testing.

Installed smoke keeps AppBar reservations and all-monitor background enabled,
but suppresses input, native service writes, dispatch, tiling, recording,
keep-awake, notification mirroring, tray interception and physical hotkeys.
After about 15 seconds of QML runtime it reports PASS and waits for exact-path
IPC quit, with a 60-second recovery timeout. Local empty keybind fixtures protect
other shell instances; combined notification smoke retains round 1's in-process
fixture and does not depend on owning the system notification server.

The first production quit exposed teardown-only clock/network binding warnings.
Small Windows adapters now guard clock reads and retain the last network sample
through native singleton destruction. The shared upstream Time.qml is unchanged.
Background smoke checks each actual background instance and its monitor geometry.
Hard reload also exposed an old generation disabling the new generation's
process-wide DesktopLayer. The new wrapper now owns that setting at startup;
old-wrapper destruction only removes its windows and does not disable the new
owner. Process exit still removes the background and AppBars.

## Build and validation

Build output is exclusively:

```text
C:\Users\Ermin\.t3\worktrees\caelestia-windows\t3-488b52f1\windows\.local\build
```

No other worktree's build was modified. Full `Build-Prototype.ps1` passed for
backend, M3Shapes, portable plugins and installation, with Qt 6.11.2, clang-cl
20.1.8, MSVC 14.44.35207 and SDK 10.0.26100.0 on Windows build 26300. Build
metadata records shell merge `3482604c` with integration edits present, backend
`13b2d093`, and the unchanged M3Shapes revision. Final QML is staged from this
integration commit; the C++ sources did not change after that build.

- Strict build-environment report passed with both dependency pins matching.
  The separate required ordinary `Test-Environment.ps1 -Json` also confirms pins;
  tools absent from the ordinary PATH remain a prerequisite note, not a build failure.
- Final `-Combined -Smoke`: PASS, exit 0, 32.551 seconds,
  `combined-20261026-020841-631.json`.
- Final `-Combined -Live -Smoke`: PASS, exit 0, 32.260 seconds,
  `combined-20261026-020916-881.json`.
- Installed production smoke: PASS on native 150% and 175% monitors, with
  2560x1440 and 2194x1234 logical drawers/backgrounds and 60-DIP bars.
  Service/write gates were all false and tiling mode was off.
  Exact-path IPC State, hard Restart and Quit were exercised. The second
  generation passed the same all-monitor smoke after Restart, with no QML
  warnings/errors. A test-harness log-reader sharing race was corrected before
  the passing restart run; the reader now allows concurrent watchdog appends.
- AppBar reservations measured 90 and 105 physical pixels at the respective DPIs.
  Work areas and taskbar flags matched the original pre-test baseline after
  IPC quit and uninstall. No taskbar show/hide calls were recorded and no test
  autostart entry was present. An earlier quit-only run also matched the exact
  per-HWND snapshot. On the final shared-desktop run, taskbar visibility changed
  independently while flags/work areas stayed equal; taskbar hiding was forced
  off throughout, so this run does not claim exclusive visibility ownership.
- Temporary package, profile and Start-menu shortcut were removed by uninstall
  with `-Purge`. Explorer PID 9252, KSG Shell PID 24108 and the user's preview
  PID 39652 remained. Another preview (PID 28224) started during testing and was
  left alone. The old baseline's other preview PID 10400 ended independently;
  none of this task's commands targeted it or either preview build.

Logs, JSON and staged sources remain ignored under `windows/.local`; no new
validation evidence archive was created. This is build/loading/install smoke,
not live hardware, tiling, shortcut input, crash-restart, hotplug or release
acceptance. Round-4 work remains separate.

## User commands

From this checkout, using its default build directory:

```powershell
powershell -NoProfile -File windows/scripts/Install-Caelestia.ps1
& "$env:LOCALAPPDATA\Programs\caelestia-windows\Start-Caelestia.ps1"
& "$env:LOCALAPPDATA\Programs\caelestia-windows\Start-Caelestia.ps1" -Command State
& "$env:LOCALAPPDATA\Programs\caelestia-windows\Start-Caelestia.ps1" -Command Restart
& "$env:LOCALAPPDATA\Programs\caelestia-windows\Start-Caelestia.ps1" -Command Quit
powershell -NoProfile -File windows/scripts/Uninstall-Caelestia.ps1
```

Installation defaults to `%LOCALAPPDATA%\Programs\caelestia-windows` and the
profile to `%LOCALAPPDATA%\caelestia-windows`. Add `-Autostart` only to opt into
sign-in startup. Ordinary uninstall preserves the profile; add `-Purge` only
when intentionally deleting it. Taskbar hiding defaults off. Coordinate existing
shell/tiler ownership before enabling interactive tiling.
