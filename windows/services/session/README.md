# Windows session service

The bounded Windows session service replaces the M1 always-unavailable
`Caelestia.Services.SessionManager` adapter with a default-off service that
projects `Quickshell.Windows.Session` capabilities and, only after a second
opt-in, dispatches an explicit allowlist. The original session drawer, launcher
actions, motion and icons remain in use; no replacement session UI was written.

## Contract and data flow

The pure state object is
[`SessionService.qml`](SessionService.qml). It imports no Quickshell module and
has no process, detached-execution or arbitrary-command path; tests inject a
recording fake. [`NativeSessionBackend.qml`](NativeSessionBackend.qml) is the
thin facade over the pinned singleton, and the staged
[`SessionManager.qml`](../../shell/adapters/imports/Caelestia/Services/SessionManager.qml)
singleton wires the environment opt-ins and a lazy `Loader`.

Upstream `SessionManager.exec(list<string>): bool` remains the command entry
point used by [`modules/session/Content.qml`](../../../modules/session/Content.qml)
and [`modules/launcher/services/Actions.qml`](../../../modules/launcher/services/Actions.qml).
On Windows `exec()` always returns `true`, including for an unknown command, so
the original `Quickshell.execDetached()` fallback cannot run. The localized
hooks in those two components also refuse detached execution when the adapter's
`allowDetachedFallback` is `false`; upstream native `SessionManager` does not
define the property, so Linux keeps its original fallback.

### Explicit allowlist

Only these exact shapes map to a native method. Extra arguments, malformed
values and arbitrary commands are consumed as `unsupported`.

| Commands | Action | Native call | Destructive |
| --- | --- | --- | --- |
| `lock`, `lock-session`, `loginctl lock-session` | lock | `Session.lock()` (secure Windows lock) | no |
| `logout`, `loginctl terminate-user ''` | logout | `Session.logout()` | yes |
| `shutdown`, `poweroff`, `systemctl poweroff` | shutdown | `Session.shutdown()` | yes |
| `reboot`, `systemctl reboot` | reboot | `Session.reboot()` | yes |
| `suspend`, `systemctl suspend` | suspend | `Session.suspend()` | no |
| `hibernate`, `systemctl hibernate` | hibernate | `Session.hibernate()`, only while `canHibernate` | no |
| `firmware`, `firmware-reboot`, `firmware_reboot`, `reboot-to-firmware` | firmware | `Session.rebootToFirmware()` | yes |
| `switch-back`, `switchback`, `switch-back-to-windows` | switchback | detached `Start-Caelestia.ps1 -Command Quit`, optionally with `-DisableAutostart` | no |
| `suspendThenHibernate` | — | none; Windows has no combined operation | — |

Names are normalized like upstream: `-` and `_` are removed and the token is
lowercased. The upstream `systemctl`/`loginctl` two-token aliases and the
`loginctl terminate-user ''` logout alias are preserved. A canonical command
with extra arguments is refused rather than partially executed.

### Switch back to Windows

`switchback` is the shell-side "Switch back to Windows" action. It is not a
native `Quickshell.Windows.Session` call. The native facade starts the installed
stable-root `Start-Caelestia.ps1` as a detached process, so the existing IPC
Quit, supervisor stop, taskbar/work-area restore and `Restore-Desktop.ps1`
recovery all run outside the shell that is exiting. The facade implements no
second process-cleanup or restore path. `Process.startDetached()` disowns the
child handles before the shell quits.

The backend also reports `switchBackSupported`. It is false unless
`CAELESTIA_SHELL_LIVE=1`, the session is not a smoke run, `CAELESTIA_INSTALL_ROOT`
holds `Start-Caelestia.ps1` and `install.json`, and the inbox Windows PowerShell
exists. The UI keeps the action visible but disabled with that reason.

Before `exec(["switch-back"])`, the session UI sets
`switchBackDisableAutostart`. When true, the launcher removes only this
installation's own HKCU Run entry through the registration helper shared with
install, then follows the same Quit path. The session drawer and Nexus > Services
both offer the choice; it is off by default.

## Outcomes and capability

`request()` returns a result object and `exec()` records the same object in
`lastResult`:

| outcome | meaning |
| --- | --- |
| `disabled` | observation opt-in absent; nothing was resolved |
| `unavailable` | the facade is absent, failed to load, or no backend exists |
| `unsupported` | unknown/arbitrary command, malformed shape, combined sleep, or hibernate without capability |
| `actions-disabled` | a known action was refused because the dispatch opt-in is off |
| `requested` | exactly one native method was invoked |
| `failed` | the injected facade threw; no success is claimed |

Every result has `consumed: true` and `succeeded: false`. `requested` means a
request was sent, **not** that Windows accepted it. The pinned backend methods
return `void` and only log failures:
`windows/deps/quickshell/src/windows/system/session.cpp:45-49` (lock),
`:51-55` (logout), `:57-71` (shutdown), `:73-87` (reboot), `:89-93` (suspend),
`:95-99` (hibernate), `:101-115` (firmware reboot) and `:117-121`
(`canHibernate`). There is no per-action result to expose truthfully.

`sessionAction()`/`actionInfoFor()` expose per-action `supported`, `capability`,
`dispatchable`, `destructive` (information only) and UI `available` values.
Hibernate capability follows `Session.canHibernate`; a missing or non-boolean
value is false. The Windows host uses these flags for the original buttons'
existing disabled styling instead of inventing new visuals.

## Opt-ins

Both opt-ins are child-process environment variables. Default behavior remains
unavailable, and the M1 host sets both explicitly so an inherited value cannot
enable the service.

- `CAELESTIA_WINDOWS_SESSION=1` loads the native facade for capability
  observation only. It reads `canHibernate`; it sends no action.
- `CAELESTIA_WINDOWS_SESSION_ACTIONS=1` additionally permits allowlisted
  dispatch, destructive actions included. It is independent of observation and
  is forced off by every smoke run. The host exposes the explicit
  `-SessionActions` switch (only with `-Session -SessionMode Observe`) for an
  interactive run; it is not validated by this slice.

Destructive actions (`logout`, `shutdown`, `reboot`, `firmware`) dispatch
directly, as in upstream Caelestia: its session panel calls `exec()` on
activation with no confirmation step, so this slice adds none. The allowlist and
the two opt-ins are the only gates, and a destructive button's existing disabled
styling follows `dispatchable` exactly like the others. There is no pending
request and no confirm step to wire later.

## Validation

Use the [public production smoke](../../NATIVE-BUILD.md#smoke) for loading
with actions disabled and the
[installed-shell live checklist](../../docs/LIVE-CHECKLIST.md) for normal use.
Never treat a requested dispatch as successful completion. Any real session
action needs explicit user intent and can interrupt other applications.

## Limits

- No real lock, logout, shutdown, reboot, suspend, hibernate or firmware reboot
  is established by the production smoke.
- Native Observe smoke reads `canHibernate` and the service state; it invokes no
  action. Real privilege-denied and Windows failure behavior remain unvalidated;
  the backend reports them only in its log.
- Destructive actions now run on the first activation, exactly as upstream
  Caelestia does. A confirmation step is not part of this service.
