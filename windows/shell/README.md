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

### Experimental invisible taskbar

With `hideTaskbar: true`, setting `windows.taskbarSuppression` to `"invisible"`
adds an empty window region to Explorer's primary and secondary taskbar HWNDs
before the existing hides. The default, `"hide"`, does not change regions.
This is an unvalidated experiment, not a guarantee of zero visible frames or
input transparency. No window styles, layered attributes, keyboard hooks, or
Windows auto-hide preferences are changed. New Explorer windows are discovered
on show, broadcast and polling; a new window can paint before discovery, and
Explorer can change its region between checks. TaskbarCreated is not trusted
as proof of an Explorer restart because Quickshell also broadcasts it.

[SetWindowRgn](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-setwindowrgn)
documents clipping to the window region and transfer of region ownership.
[TaskbarXI's Windows 11 source](https://github.com/TaskbarXI/TaskbarXI/blob/main/Taskbar11.cpp)
uses an empty taskbar region, but this does not establish correctness on build
26300 or across Explorer relayouts. The experiment avoids layered alpha because
it would also require preserving potentially pre-existing layered attributes;
[Microsoft's layered-window documentation](https://learn.microsoft.com/en-us/windows/win32/winmsg/window-features)
describes alpha and `WS_EX_TRANSPARENT` hit testing for layered windows, not
whether Explorer's composition-hosted taskbar obeys it. Region hit testing,
composed pixels, and reapplication must be checked live.

Win and Win+T are not intercepted. Start is a separate window and should remain
available; Win+T may focus an invisible taskbar, and its keyboard navigation
can be confusing. Neither behavior has been validated here. If keyboard focus
or pointer input is captured, stop the experiment; do not interpret it as
acceptance.

Each HWND's original region is recorded in `desktop-before.json` before
mutation, including taskbars discovered later. Recovery verifies the HWND,
Explorer PID and process creation time before restoring it, not just monitor
identity. Clean quit, crash give-up, watchdog recovery and restart backoff
restore regions along with the existing desktop state. If the supervisor is
forcibly killed, run `Restore-Desktop.ps1 -SnapshotPath <desktop-before.json>`;
without that snapshot exact prior regions cannot be reconstructed. Restarting
Explorer is a disruptive last resort and creates new taskbar HWNDs. As with all
external HWND modifications, a same-process HWND reuse cannot be perfectly
distinguished. `GetWindowRgn` also reports both no region and some failures as
ERROR, so exact recovery on every API failure cannot be guaranteed.

For a controlled live test only, stop the supervisor and make all Explorer
taskbars visible, then run:

```powershell
powershell -NoProfile -File windows/scripts/Test-InvisibleTaskbarProbe.ps1 -OutputDirectory "$env:TEMP\caelestia-taskbar-probe-unique" -Seconds 5 -IntervalMilliseconds 100
```

The probe refuses an active supervisor, records a durable recovery snapshot,
captures a baseline and sampled screen pixels for each taskbar rectangle, and
restores and verifies regions in `finally`. It does not force the taskbars to
show. Inspect the PNGs against the baseline: hashes and `IsWindowVisible` do
not prove that taskbar pixels are absent, and screen captures may contain
private data. Sampling is not a frame-perfect or 5 ms exposure measurement.
If interrupted by forced termination, use its snapshot for emergency recovery.
Then test the installed experimental configuration under orchestrator control,
including transitions, startup, multiple monitors, Explorer restart, pointer
click-through, Win and Win+T, clean exit and crash recovery. Do not run the probe
concurrently with the supervisor.

When enabled, an Explorer-process WinEvent show hook supplements the existing
250 ms reconciliation timer. After twelve shows on the same Explorer-owned
window within 75 ms of our preceding event hide returns, all within two seconds,
it pauses event-driven hiding and region reapplication for five seconds while
the timer continues to reconcile both.
Separate, slower relayouts and shows on different windows do not share a count.
The supervisor's `taskbar-actions.jsonl` records show observations, hide calls,
hook installation/failure and event-backoff transitions. `Source` distinguishes
event callbacks from timer polling and initial/broadcast reconciliation.
`MonotonicTicks` and `TickFrequency` use `Stopwatch`; a hide's
`ShowObservedTicks` correlates it with its show observation.
`ShowToHideMilliseconds` measures from callback delivery or a polling timestamp
captured after taskbar enumeration to the return of synchronous
`ShowWindow(SW_HIDE)`. `VisibleAfter` is an immediate subsequent visibility
check, not a guarantee of lasting state. A
callback can arrive after Windows first showed the window; queued delivery,
unobserved transitions, failed hides, and frame presentation mean these
intervals are not exact exposure or a zero-flicker measurement. No autohide
preference is changed by suppression.
`powershell -NoProfile -File windows/scripts/Test-TaskbarEvents.ps1` compiles
the production source and tests the event logic with fakes only.

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
read-only drawer without changing any work area, then starts the isolated
component fixture with its exclusions inactive. It validates the reported screen
over IPC (the secondary monitor, and the same screen as the smoke when that ran)
before enabling the four reservations, so a wrong `-ScreenIndex` cannot move
application windows. It measures the physical work-area deltas, keeps those
reservations stable through its fullscreen input, quits its children, and checks
that both starting work areas, taskbar flags and existing shell processes are
preserved. A fresh temporary deployment plus the 15-second smoke dominates its
runtime, so the run is bounded at 240 seconds and reports its last phase in
`result.json`; use `-ReusePrefix` for a fixture-only rerun of an interrupted
temporary install and `-SkipSmoke` to omit the installed runtime smoke. Neither
option points at the live installation.

Use the temporary uninstaller with `-Purge` afterward. This checks the deployed
runtime without changing the user's profile or enabling autostart.
