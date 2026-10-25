# M2 explicit Windows session actions, 2026-10-25

This archive records ERM-507's bounded session slice on branch
`t3/windows-session-actions`. It retains the previous unavailable default,
adds a pure allowlisted session service, a thin
`Quickshell.Windows.Session` facade and Disabled/Observe native smoke wiring.

**No real session action was executed.** No lock, logout, shutdown, reboot,
suspend, hibernate or firmware reboot was invoked, including in every native
test below. Native runs were limited to Disabled and Observe modes with action
dispatch forced off; all send/receive checks used an injected recording fake.

## Sources and runtime

- Implementation commit
  `0c54b48d16677ddcc258ede95780c8b035a56d45`, clean during the recorded runs
  (`sourceDirty=false`). The evidence commit that adds this directory is later
  and changes no runtime source.
- Backend unchanged at
  `1401042969e4b7ab3cfb314fc76945ab081db3de`; no gitlink,
  `windows/sources.lock.json` or submodule edit is part of this slice.
- Windows 11 Pro `10.0.26300`, Qt `6.11.2`, existing shared build
  `D:\AiStack\caelestia-windows\windows\.local\build`. QML-only changes; no
  rebuild was performed in the shared build.
- Primary monitor at native 150%; secondary at native 175%, x=-3840.

## Delivered behavior

The pure [SessionService](../../services/session/SessionService.qml) imports no
Quickshell module and has no process/detached path. It maps only `lock`,
`logout`, `shutdown`/`poweroff`, `reboot`, `suspend`, capability-gated
`hibernate` and `firmware` reboot, with the upstream `systemctl`/`loginctl`
aliases. Unknown, arbitrary, empty, extra-argument and malformed commands are
consumed as `unsupported`; `exec()` always returns true so the original UI cannot
reach `Quickshell.execDetached()`. The localized
[session](../../../modules/session/Content.qml) and
[launcher](../../../modules/launcher/services/Actions.qml) hooks add
`allowDetachedFallback === false` and unavailable-button styling while preserving
Linux defaults when the native Linux `SessionManager` lacks the properties.

Every native method returns void and only logs failures
(`windows/deps/quickshell/src/windows/system/session.cpp:45-115`). Results are
therefore `requested`, never `succeeded`. Destructive actions stop at
`confirmation-required`; the original session panel at this revision has no
confirmation flow, so the host does not auto-confirm and the buttons remain
disabled instead of bypassing it. Observation (`CAELESTIA_WINDOWS_SESSION=1`)
and dispatch (`CAELESTIA_WINDOWS_SESSION_ACTIONS=1`) are separate opt-ins; smoke
forces dispatch off, while Observe smoke still observes.

## Results

| Check | Observed result | Evidence |
| --- | --- | --- |
| Offscreen session fixture | 338 assertions passed; no native imports, fallback path or QML diagnostics | [result](fixture/result.json), [stdout](fixture/run.stdout.log), [stderr](fixture/run.stderr.log) |
| Session native matrix | 6/6 runs passed: fixture, 2 screens x Disabled/Observe, M1 regression | [matrix](matrix/result.json) |
| Disabled at 150% and 175% | Pass; no native facade/backend, no action, `lastOutcome=disabled`, all four original buttons disabled | [150%](session-disabled-screen0/result.json), [175%](session-disabled-screen1/result.json) |
| Observe at 150% and 175% | Pass; backend loaded for capability reads only, `canHibernate=true`, dispatch off, `lastOutcome=unsupported`, all four buttons disabled | [150%](session-observe-screen0/result.json), [175%](session-observe-screen1/result.json) |
| Original M1 bar/session regression | Pass | [result](m1-regression/result.json) |
| Media service regression | 148 assertions passed | [result](regressions/media-service.json) |
| Battery service regression | 128 assertions passed | [result](regressions/battery-service.json) |
| M1 shell smoke regression | Pass, exit 0, no runtime WARN/ERROR | [result](regressions/m1-smoke.json) |

Native session states (initial; final identical):

| Screen | Scale | Mode | Native backend | `canHibernate` | Actions | `lastOutcome` | Original buttons |
| --- | --- | --- | --- | --- | --- | --- | --- |
| 0 | 150% | Disabled | not loaded | not read | off | `disabled` | 4/4 disabled |
| 0 | 150% | Observe | loaded | true | off | `unsupported` | 4/4 disabled |
| 1 | 175% | Disabled | not loaded | not read | off | `disabled` | 4/4 disabled |
| 1 | 175% | Observe | loaded | true | off | `unsupported` | 4/4 disabled |

The observation probe is the unknown command
`caelestia-m1-unavailable-probe`; it is consumed, never dispatched. No attempt
was made to invoke `Session.lock/logout/shutdown/reboot/suspend/hibernate/
rebootToFirmware`. The smoke host reads the singleton's `canHibernate` property
and otherwise observes only service policy state. Each run recorded staged
source hashes, initial/final session snapshots, the four original button disabled
states, a PNG, stdout/stderr and desktop state. A search of every archived
stdout/stderr log for `LockWorkStation`, `ExitWindowsEx`, `InitiateShutdown`,
`SetSuspendState`, `CreateProcessW`, `shutdown.exe /r /fw` and the session
logging category returned zero matches.

Fixture coverage includes exact allowlist mapping and aliases, unknown/arbitrary
and malformed command consumption, actions-off refusal, hibernate capability
gating (including a non-boolean capability), the unsupported combined
suspend-then-hibernate action, destructive confirmation/cancellation and
single-dispatch replacement, `requested` vs `succeeded` semantics, missing
backend methods, a throwing facade and disable cleanup. Dispatch targets only the
fake backend's recorded call list.

## Commands

Run from the repository root with native PowerShell:

```powershell
$qtPrefix = "$env:LOCALAPPDATA\caelestia-dev\Qt\6.11.2\msvc2022_64"
powershell -NoProfile -File windows/scripts/Test-SessionService.ps1 `
    -QtPrefix $qtPrefix

powershell -NoProfile -File windows/scripts/Test-SessionPrototype.ps1 `
    -QtPrefix $qtPrefix

powershell -NoProfile -File windows/scripts/Test-MediaService.ps1 `
    -QtPrefix $qtPrefix

powershell -NoProfile -File windows/scripts/Test-BatteryService.ps1 `
    -QtPrefix $qtPrefix

powershell -NoProfile -File windows/scripts/Start-ShellPrototype.ps1 `
    -QtPrefix $qtPrefix -Smoke -ScaleFactor native -ScreenIndex 0
```

Observed summaries:

```text
Test-SessionService:      passed=True assertions=338 nativeImports=0 fallbackPaths=0
Test-SessionPrototype:    passed=True runs=6 output=...session-validation-20261025-181310-889
Test-MediaService:        passed=True assertions=148
Test-BatteryService:      passed=True assertions=128
M1 Start-ShellPrototype:  passed=True prototype=shell exitCode=0
```

`Test-SessionPrototype.ps1` selects every measured connected screen, runs only
Disabled and Observe with `-Smoke` (actions forced off), asserts the four
original buttons are disabled, then runs the original M1 smoke. Its desktop gate
ignores unrelated concurrent `qs` prototypes but proves this harness left no
`session-*`/`session-prototype-profile` process behind.

## Preserved state

[Desktop before](desktop-before.json) and [after](desktop-after.json) preserve
Explorer PID 9252, KSG Shell PID 24108, both monitor bounds/work areas and
taskbar flags `stateFlags=1`, auto-hide true. The matrix records
`sourceDirty=false`. No pointer/keyboard input was synthesized and no session
action or privilege change occurred.

## Limits

- Real lock/logout/shutdown/reboot/suspend/hibernate/firmware behavior and
  privilege denial are untested by design. The native API returns void, so even
  an interactive request could not be called a confirmed success.
- Destructive actions remain behind a confirmation gate with no original
  confirmation UI at this revision; they are fixture-tested only. A real
  destructive acceptance requires the separately agreed live test.
- The launcher is disabled in the isolated profile; its no-fallback guard is
  source-reviewed and shares the session service, but no launcher UI run was
  performed.
- No backend source or pin changed; the backend gap and its file/line references
  remain as audited.

## Review addendum

An independent review of `229ca28e` found that `-SessionActions` had no usable
path: the launcher wrote empty command arrays for all four original session
buttons, so even supported hibernate stayed disabled. `-Session` runs now bind
the buttons to the allowlisted command names (`logout`, `shutdown`,
`hibernate`, `reboot`); the M1 default keeps empty commands. Dispatch still
requires `CAELESTIA_WINDOWS_SESSION_ACTIONS=1`, smoke forces it off, and
destructive actions still stop at the confirmation gate. Comments that said
smoke forces both opt-ins off now say it forces dispatch off.

Re-run of `Test-SessionPrototype.ps1` on the dirty follow-up tree: all six
records passed (`session-validation-20261025-182013-909`); all four original
buttons stayed disabled with dispatch off. No session action was executed.
`-SessionActions` interactive dispatch remains untested.
