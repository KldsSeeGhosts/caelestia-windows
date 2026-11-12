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

## Staging map

[`sources.json`](sources.json) is the one production staging map: every file the
installer stages, as source to staged path. `Stage-ShellPrototype.ps1 -Prototype
shell-live` reads it for installation and public smoke. The production adapters it names live next to it under
[`adapters/`](adapters/), and `WindowsFonts.qml` stays here too. Staging keeps
the font-loader and workspace-font transforms in the script. A source under
`windows/tests/` fails production staging, so the released tree cannot depend
on test fixtures. The old combined developer preview is retired.

## Install and run

Build as described in [NATIVE-BUILD.md](../NATIVE-BUILD.md), then run from the
repository root:

```powershell
powershell -NoProfile -File windows/scripts/Install-Caelestia.ps1
& "$env:LOCALAPPDATA\Programs\caelestia-windows\Start-Caelestia.ps1"
& "$env:LOCALAPPDATA\Programs\caelestia-windows\Start-Caelestia.ps1" -Command State
& "$env:LOCALAPPDATA\Programs\caelestia-windows\Start-Caelestia.ps1" -Command Restart
& "$env:LOCALAPPDATA\Programs\caelestia-windows\Start-Caelestia.ps1" -Command Settings
& "$env:LOCALAPPDATA\Programs\caelestia-windows\Start-Caelestia.ps1" -Command Quit
powershell -NoProfile -File windows/scripts/Uninstall-Caelestia.ps1
```

Installer flags: `-BuildRoot`, `-QtPrefix`, `-VCRuntimeRoot`, `-Prefix`,
`-ProfileRoot`, opt-in `-Autostart`, and `-Restart`. `-SkipSchemeRuntime` skips
preparing the optional Python scheme runtime during this install; an existing
prepared runtime is still used, and a later launcher start may provision one.
Ordinary installation does not launch the shell and requires it to be stopped.

For an update, do **not** quit first:

```powershell
& windows/scripts/Install-Caelestia.ps1 -BuildRoot C:\b-topic -Restart
```

This assembles Qt, QML, licenses and the optional profile-local Python scheme
runtime in a new immutable version while the old shell remains running. Scheme
dependencies are built in an immutable generation under
`scheme/runtimes/<generation>`; `scheme/runtime.json` is published atomically
only after that generation verifies. A profile-scoped lock serialises installer
preparation, normal starts and repairs, so two provisioners never write at once
and a published generation is never modified. Only then does it quit,
atomically select the prepared version and launch through an on-demand,
non-elevated interactive scheduled task. Provisioning is reported as its own
phase; activation allows 75 s for launcher setup, including up to 45 s for
banner recovery and a 20 s initial child-readiness observation. Provisioning finishes
before activation, so a cold venv or slow download cannot trigger a rollback. If
provisioning fails, the install continues, the shell starts on its fixed
palette and `scheme-runtime.log` records the fallback. A responsive IPC endpoint
and first frame from every drawer are required before success. Failed
activation selects/restarts the previous version and still reports failure. A
retained payload that predates the generation layout is started with scheme
provisioning disabled, so a rollback cannot run pip inside the readiness
budget; it uses the fixed palette. No running executable or DLL is overwritten.

The layout is:

```text
<prefix>/
  Start-Caelestia.ps1             stable launcher, shortcuts and Run entry
  Manage-Caelestia.ps1            status and confirmed rollback
  Uninstall-Caelestia.ps1
  install.json                   schema 2: current and previous version ids
  versions/<timestamp-revision-id>/
    install.json                 schema 1 runtime/provenance manifest
    qs.exe, shell/, qml/, plugins/, licenses/, ...
```

The profile remains outside this tree. `State`, `Quit` and `Restart` route to
the actual running version; `Start` uses the selected version. Current and
previous payloads are retained. Older owned versions are removed only after
successful installation, never if still running, linked, unrecognized or
locked. Their removal is best effort and cannot fail a healthy update.

The first update migrates a flat installation by retaining a legacy version
before changing its root launcher. Legacy runtime files may also remain at the
root for compatibility; subsequent installs use only version directories.
No junctions or symlinks are used, and no credentials are stored in the tree.

Settings > Updates shows the running/selected build and retained previous
version. Rollback requires confirmation and runs as independent scheduled
maintenance, so closing Settings does not cancel it. It preserves the profile.
The same operation can be requested from PowerShell:

```powershell
& "<prefix>\Manage-Caelestia.ps1" -Command Status
& "<prefix>\Manage-Caelestia.ps1" -Command Rollback
```

Rollback toggles the selected and previous versions, allowing a return to the
newer build. `-Wait` executes maintenance synchronously for diagnostics; normal
requests queue it outside the shell's process tree.

No Windows release packages/feed are published yet. The page explicitly reports
that downloads are unavailable; it does not treat source commits as installable
updates, prompt for authentication, or perform background network checks.
This layout is a foundation for a verified package channel and warm successor
handoff, not a claim of zero-frame native executable replacement. Native updates
still stop the old shell before starting the replacement.

`-Command Restart` is the normal lightweight restart: it reloads QML **inside
the existing shell process**, retaining the watchdog and windows. It waits for
a new QML generation to render, and fails if the reload is rejected instead of
mistaking the still-running old graph for success. It does not install source
changes or reload native DLLs. Profile settings/keybinds are already watched and
usually need neither command.

Uninstall accepts `-Prefix` and optional `-Purge`; ordinary uninstall preserves
configuration. All IPC commands select this installation's exact QML path.

The deployed runtime includes Qt, CRT, portable Caelestia and M3Shapes plugins,
fonts and license notices. Normal launches retain PATH for applications. Qt
uses Direct3D 11; smoke excludes developer PATH entries.

### Background apps

The tray above the clock defaults to a compact, bare chevron. Click its chevron
to expand or collapse it; it stays open until the chevron is clicked again.
The expanded list scrolls
after roughly five icons so it cannot crowd out the clock. Hover an icon for
its name, left-click for the app's primary action, or right-click for the app's
native menu, including Exit when that app provides it. These are notification
area apps, not a list of every running window or background process.
Icons retain their original app-provided colours (`bar.tray.recolour: false`).

Existing profiles are preserved on update. To enable this in an older
`config/shell.json`, enable the `bar.entries` item with `"id": "tray"`, set
`bar.tray.compact` to `true` and `bar.tray.background` to `false`, and keep
`bar.popouts.tray` `false`: Windows uses app-owned native menus, not upstream's
Qt menu handles.
An empty tray takes no space.

After deploying tray changes, check the running version selected by the
installed launcher against these sources. Checking only the stable prefix's
legacy `shell/` directory is insufficient after migration to versioned payloads.

## Profile and controllers

The stable profile defaults to `%LOCALAPPDATA%\caelestia-windows`. First launch
seeds these files once, preserving edits across restart/update/uninstall:

- `config/shell.json`: integrated combined Live defaults, with background and
  wallpaper enabled (yielding automatically while Wallpaper Engine owns the
  desktop), desktop clock and visualiser off, focus-follows-mouse off and tiling
  disabled with 10/10 DIP gaps. Native Config watches edits.
- `config/keybinds.json`: shipped `defaults/windows/keybinds.json`. The backend
  watches edits; see [KEYBINDS.md](../docs/KEYBINDS.md).
- `config/windows.json`: `{"windows":{"hideTaskbar":false,"restartOnCrash":true,"wallpaperEngine":{"enabled":false}}}`.
  These supervisor settings apply at the next launch. Wallpaper Engine is
  opt-in; a missing `enabled` key is off, while an existing saved value
  (including the older `"auto"`) is kept.

The installer provisions the pinned Caelestia CLI and Python dependencies in an
immutable generation under `scheme/runtimes/<generation>` before activation.
`scheme/runtime.json` points at the verified generation for the selected
version's revision. A launcher started outside the installer (for example the
Run entry on a later sign-in) reuses that generation and repairs by building a
new one. Activations never wait for provisioning: when no matching generation
is published, the shell starts on its fixed palette. A start that finds
provisioning already in progress also stays on the fixed palette until the next
shell start; it never waits for the provisioner. Generations used by the
current and previous installed versions are retained; older ones are pruned on
a later install only when no shell or supervisor is running. Pruning first
renames a generation into `scheme/runtimes/.trash`, which fails (and keeps the
generation whole until the next prune) while a working directory or open file is
inside. A rename does not prove no code runs from it, so the generation is also
kept while any of its `.exe`/`.dll`/`.pyd` images refuses write access (the OS
does so for a mapped image, even for processes whose modules cannot be read).
A directory cannot be renamed while any file inside is open, so the image check
is repeated at the new location and a generation that gained a mapped image in
between is moved straight back. A move-back that cannot complete is recorded in
`scheme/prune-restore.json` and each later prune makes one restore attempt
before any deletion, so its path is not lost to a blind retry (or to the delete
that would otherwise follow). Read-only image files are not treated as in use:
the write check clears that attribute only for its probe and restores it.
Deletion then holds the images open while it runs. Use
`-SkipSchemeRuntime` on the installer or launcher to skip preparation. If
preparation failed, Caelestia starts on the fixed palette and
`logs/scheme-runtime.log` reports it; rerun `Install-SchemeRuntime.ps1` from the
selected version directory to retry. The shell keeps one helper process warm and
sends each palette request over stdin, so switching wallpaper does not pay Python
startup and the CLI imports again; the upstream per-image cache stays warm too.
Wallpaper Engine discovery and preview colour matching share the combined
services; its options are watched under `windows.wallpaperEngine` in
`config/windows.json`.

State, cache, data, runtime and logs remain in that profile. Normal and smoke
runs capture `logs/shell.stdout.log` and `logs/shell.stderr.log`; the watchdog
records its durable snapshot/status under `runtime/supervisor-<id>/`.
Quickshell also retains native instance bookkeeping under
`%LOCALAPPDATA%\quickshell`.

Taskbar hiding is opt-in. On startup, Explorer stays unchanged until every
monitor's shell window has presented a frame or the backend confirms that its
placed, visible Top window is lowered beneath fullscreen. Overlay panels still
need a frame. The content-free stdout record `CAELESTIA_SHELL_READY` reports this
takeover predicate. IPC `lifecycle.ready` keeps its stricter first-frame check.
`watchdog.json` stays `starting` for the first 20 s, then `waiting-ready` while
the child is alive without a marker. The supervisor never kills or restarts a
live child for missing readiness. It keeps its heartbeat and accepts readiness
however late, then takes over and reports `running`.

A plain Start or logon launch reports readiness failure without stopping that
child. Transactional install/update activation keeps its existing policy of
stopping unsuccessful attempts and rolling back. A locked session, sleeping
display or pending hotplug placement can therefore delay ordinary startup
without the supervisor terminating the shell.

The watchdog retries the first crash immediately, retaining taskbar suppression
for at most two seconds while waiting for the replacement's first frames.
After that grace, Explorer returns until the replacement is ready. Backoff
returns Explorer too. Pending banner recovery also returns Explorer before its
potentially slow replay. Repeated quick crashes use bounded backoff and give up
after three failures. Readiness is latched per child process, so soft QML reloads
do not flash Explorer while new QML scopes wait for first frames.

After readiness, the watchdog sends a nonce through GUI-thread IPC once a
minute, allowing 5 s for a reply. After a missed reply it probes every 15 s.
Detection arms only after the first exact reply. At least six consecutive
misses spanning 120 s report `phase: frozen` and `shellFrozen: true`. A
continuously frozen, previously responsive shell is detected about two to three
minutes after its last reply. A successful reply clears the miss window.
Sleep/resume, session lock/disconnect, shutdown, QML reload and supervisor
scheduling gaps over 5 s clear the window too. A held install/update lock
cancels a freeze at the moment it would be declared. Older shells that never
answer remain unarmed.

Set `windows.restartFrozenShell` to `false` in `config/shell.json` before the
next launch to keep detection/status without automatic termination. The default
is `true`. Automatic recovery uses the crash cleanup/backoff path. A frozen
termination counts toward the three-failure limit when the shell froze within
10 minutes of starting. A freeze after a longer lifetime resets that count.
`watchdog.json` also reports `livenessSupported`,
`livenessMisses`, `restartFrozenShell` and `lastUnhealthyReason`.
The watchdog restores its owned desktop changes on exit, and never starts a second tiler.
`Restore-Desktop.ps1` is the emergency recovery command; restarting Explorer
requires its separate explicit flag.

### Experimental invisible taskbar

With `hideTaskbar: true`, setting `windows.taskbarSuppression` to `"invisible"`
adds an empty window region to Explorer's primary and secondary taskbar HWNDs
before the existing hides. The default, `"hide"`, does not change regions.
This is an unvalidated experiment, not a guarantee of zero visible frames or
input transparency. The region experiment changes no window styles, layered
attributes or Windows auto-hide preferences. New Explorer windows are discovered
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

Win and Win+T navigation of an invisible taskbar is no longer left to Explorer:
the shell's keyboard hook, described under shortcut suppression below, consumes
Win+T and the other taskbar chords in both suppression modes. If keyboard focus
or pointer input is captured, stop the experiment; do not interpret it as
acceptance.

Each HWND's original region is recorded in `desktop-before.json` before
mutation, including taskbars discovered later. Recovery verifies the HWND,
Explorer PID and process creation time before restoring it, not just monitor
identity. Clean quit, crash give-up, watchdog recovery and delayed restart backoff
restore regions along with the existing desktop state. If the supervisor is
forcibly killed, run `Restore-Desktop.ps1 -SnapshotPath <desktop-before.json>`;
without that snapshot exact prior regions cannot be reconstructed. Restarting
Explorer is a disruptive last resort and creates new taskbar HWNDs. As with all
external HWND modifications, a same-process HWND reuse cannot be perfectly
distinguished. `GetWindowRgn` also reports both no region and some failures as
ERROR, so exact recovery on every API failure cannot be guaranteed.

Controlled live validation must exercise edge hover and separately check
pointer click-through on every monitor. `IsWindowVisible` and state hashes do
not prove taskbar pixels are absent or input passes through. Keep a durable
recovery snapshot, restore the original state afterward, and exclude private
screen content from evidence. This experiment is not a release acceptance claim.
Then test the installed experimental configuration under orchestrator control,
including transitions, startup, multiple monitors, Explorer restart, pointer
click-through, a lone Win tap, every suppressed taskbar chord, clean exit and
crash recovery. Do not run the probe concurrently with the supervisor.

### Taskbar shortcut suppression

While `hideTaskbar` is true, in either suppression mode, the shell's own
low-level keyboard hook consumes the Explorer taskbar shortcuts that would
otherwise reveal, focus or invoke a hidden taskbar: Win+T, Win+Shift+T, Win+B,
Win+0..9, Win+Shift+0..9, Win+Ctrl+0..9, Win+Alt+0..9 and Win+Alt+Enter.
Matching requires the exact modifiers, so Win+A, Win+N, Win+L and other Windows
chords are unchanged. A lone Win tap still opens the Caelestia launcher.
Microsoft also documents Win+Ctrl+Shift+0..9 (launch the pinned app as
administrator); that combined variant is outside this exact-modifier set and is
not consumed.

The supervisor sets `QS_WINDOWS_TASKBAR_SHORTCUT_FILTER=1` on the shell child
when `hideTaskbar` is configured, and removes an inherited value otherwise.
This process-lifetime filter also applies during the short startup overlap and
while a slow replacement temporarily returns Explorer. The filter is part of the shell's existing
hook, not a second hook in the supervisor: every keystroke passes through one
low-level hook and there is no install order to preserve. The variable is read
once for the shell's process lifetime, so changing `hideTaskbar` takes effect on
the next shell start.

A configured bind keeps priority over the filter: a hook-backed or registered
bind on one of these chords still runs, and an empty bind map leaves the filter
running. After a consumed chord the hook masks the Windows key release the same
way it does for its own Super chords: an unassigned 0xE8 key tap followed by a
replayed Win key-up, tagged with the `0x5153484B` injection marker. The physical
Win-up is swallowed only when the replay succeeded; a failed or partial replay
lets it pass through so Win is never left logically down. Injected or remapped
chords, for example from PowerToys, are consumed too unless they carry that
marker.

The filter needs no entry in `keybinds.json` and adds no default bind. With
`hideTaskbar: false` the shell hook does not consume these chords and Explorer
handles them as usual.

When enabled, an Explorer-process WinEvent show hook supplements the existing
250 ms reconciliation timer. After twelve shows on the same Explorer-owned
window within 75 ms of our preceding event hide returns, all within two seconds,
it pauses event-driven hiding and region reapplication for five seconds while
the timer continues to reconcile both.
Separate, slower relayouts and shows on different windows do not share a count.
The supervisor's `taskbar-actions.jsonl` records show observations, hide calls,
WinEvent hook installation/failure and event-backoff transitions.
`Source` distinguishes event callbacks from timer polling and initial/broadcast
reconciliation.
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

Tiling defaults off. `Start-Caelestia.ps1 -TilingMode Observe` enables observation;
`-TilingMode Interactive -TilingIncluded '<application-patterns>'` opts into
control. `-TilingExcluded` supplies the denylist. Coordinate with the existing
tiler before enabling control. `windows.tiling` in `shell.json` supports live rules/gaps/mode reload; see
[the schema](../services/tiling/README.md). Omitted launcher switches allow the
profile to apply.

## Public offscreen smoke

`windows/scripts/Test-Smoke.ps1 -BuildRoot <build> -QtPrefix <qt>` is the
public smoke command. It stages this production map, runs the built `qs.exe`
with `QT_QPA_PLATFORM=offscreen` and the software backend under an isolated
temporary profile, and exits 0 once every drawer has presented its first frame.
All services and control paths stay off. It never installs or reads the live
profile, and it fails on a QML diagnostic, missing import, wrong pin, missing
plugin DLL or a 90-second timeout. See
[the build guide](../NATIVE-BUILD.md#smoke).

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
Before testing AppBar reservations, verify the reported screen over IPC.
Record physical work areas and taskbar flags before and after, check fullscreen
release and restoration, and preserve any existing shell process. A wrong
screen selection can affect application placement.

Use the temporary uninstaller with `-Purge` afterward. This checks the deployed
runtime without changing the user's profile or enabling autostart.
