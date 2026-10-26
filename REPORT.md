# Taskbar takeover implementation

Branch: `t3/takeover`, based on `origin/t3/combined-modules` at `6026f947`.
No pushes, PRs, Linear changes, backend edits, dependency pin changes, or evidence
archives. Shared `D:\AiStack\caelestia-windows\windows\.local\build` was reused
read-only. All staging/logs/profiles stayed in this worktree's ignored
`windows/.local/`.

Implemented:

- Standalone Windows PowerShell/WinForms supervisor, independent of qs.exe.
  Launches the shell only after acquiring session ownership and persisting its
  desktop snapshot. Handles TaskbarCreated and re-hides delayed/new secondary
  taskbars on a 250 ms timer using SW_HIDE. Restores without activating taskbars.
- JSON `windows.hideTaskbar=false`, `windows.restartOnCrash=true` defaults.
  Combined prototype uses separate `config/windows.json`, preserving compatibility
  with the existing compiled upstream configuration schema. Production passes
  its platform settings path to `Start-DesktopShell.ps1`.
- Clean exit restores saved taskbar visibility/flags. Nonzero exit restores
  before restarting; 2/4 second backoff stops after three consecutive crashes
  with lifetimes under 30 seconds. Long lifetimes reset that counter.
  The backend crash handler is disabled only in the supervised child.
- Recovery removes only the dead child's stale backend AppBar registrations.
  Saved work areas are restored when stale owned AppBars were removed or the
  production caller explicitly passed `-RestoreWorkAreas`. The bounded
  prototype does not own work-area changes, so it leaves other agents' work
  areas alone. Hide-off supervision makes no taskbar visibility/flag calls.
- Background windows and WinEvent hooks owned by a dead process are destroyed
  by Windows. Recovery redraws the desktop, preserving shared WorkerW/Progman
  and windows owned by other applications.
- `Restore-Desktop.ps1` cooperatively stops an active supervisor, shows real
  taskbars, disables auto-hide and resets physical per-monitor work areas minus
  the real taskbar. Optional exact snapshot restoration; Explorer restart only
  with `-RestartExplorer`.
- Launcher switches `-Takeover`, `-HideTaskbar`, `-NoRestartOnCrash`, and writable
  `-RunRoot`. Production integration contracts are in the combined README's
  Takeover heading. No production-entry, AppBar, tiling, shortcut, workspace or
  background component implementation changes.

Checks on 2026-10-26, native Windows build 26300, Qt 6.11.2, supplied qs.exe
SHA-256 `9B518329FAC6B96973F4ECAA58A6CDFA5E413B6F9633A8F70345A706905F55AA`:

```powershell
powershell -NoProfile -File windows/scripts/Test-DesktopTakeover.ps1 `
  -QtPrefix "$env:LOCALAPPDATA\caelestia-dev\Qt\6.11.2\msvc2022_64" `
  -BuildRoot D:\AiStack\caelestia-windows\windows\.local\build
```

Passed: clean Qt.quit after ten seconds, four hide calls and two restore calls;
hard-killed only the next owned qs.exe, exit -1, two hide/two restore calls.
Every hide was matched to a restore request for the same HWND and owner PID,
using saved visibility. Immediate native observations matched every request.
Both child processes and watchdogs exited. Later changes isolated work-area
ownership and changed showing to SW_SHOWNA, without changing hide/watch logic.

Passed: deterministic default restart-policy test with `cmd /c exit 7`: three
quick crashes, backoff, give-up, exit 7, no taskbar visibility calls with hiding
off. C# helper compilation, PowerShell syntax parsing and `git diff --check`
passed.

Combined UI smoke: an initial run rendered all components and emitted
`CAELESTIA_COMBINED_PASS`, but exposed a null PowerShell process exit-code
reporting issue that was fixed. The final run correctly reported exit 1 for
`CAELESTIA_COMBINED_FAIL: notification popup did not render`. This unrelated
combined notification smoke failure remains; no notification changes were made.
The helper exited cleanly in both runs.

Environment prerequisite report: backend pin matches
`525786fc81f13346cb196dca5ab356f89ad707a5`; Qt/runtime found. CMake, Ninja and
C++ compiler are absent from ordinary PATH. No native shell/backend rebuild was
required; the helper compiles with Windows PowerShell's Add-Type.

Desktop interference: other agents repeatedly changed auto-hide, taskbar
visibility and work areas during this work. Per user direction, acceptance
assertions target our recorded calls, not exclusive global ownership.
Final recovery returned both taskbars visible and flags 0, with work areas
`(0,0)-(3840,2088)` and `(-3840,0)-(0,2076)`. A read one second later observed
another controller had already re-enabled auto-hide and hidden the primary
taskbar. Final recovery is run again immediately before handoff; no task-owned
shell/watchdog remains. Other agents' processes and Explorer were not stopped.

Remaining integration acceptance: exclusive production takeover, real Explorer
restart, live AppBar/background crash cleanup, monitor hotplug and stable visible
taskbars after recovery. TaskbarCreated reception and cleanup code are implemented;
these integrated scenarios were not exercised on the contested desktop.
