# Windows notifications prototype

ERM-502's bounded M2 notification slice delivers notifications sent through the
pinned backend's **local** notification path into the original Caelestia popup
card and sidebar notification center. System notification mirroring is a
separate issue (ERM-503) and is **off**: no Windows toast is read, no
notification-listener access is requested, and no local dismiss can remove a
real Windows notification.

## Scope and original components

The host stages these original components without reimplementing their visuals
or motion:

- [`modules/notifications/Content.qml`](../../modules/notifications/Content.qml)
  and [`Notification.qml`](../../modules/notifications/Notification.qml): the
  original popup list and card, including expand, swipe, urgency colours,
  action row and image/app-icon treatment.
- [`modules/sidebar/NotifDock.qml`](../../modules/sidebar/NotifDock.qml) and its
  `NotifDockList`/`NotifGroup`/`NotifGroupList`/`Notif`/`NotifActionList`
  dependencies: the original notification center list. Restored notifications
  remain visible here after a restart, while only new deliveries pop up.
- The `Notifs`/`NotifData` contract from
  [`services/Notifs.qml`](../../services/Notifs.qml) and
  [`services/NotifData.qml`](../../services/NotifData.qml) is replaced by the
  Windows service files below. Their names, properties, signals, timers,
  `lock()`/`unlock()` hover behaviour and `close()` semantics are preserved.

The bounded window is at most 920x620 logical pixels, inset 80 from the chosen
screen, and has a smoke-only no-input mask. The sidebar dock is limited to the
notification list; the rest of the sidebar, utilities, drawers, toasts, global
shortcuts, DnD state and shell controllers are not staged.

## Service boundary

[`NotificationsService.qml`](../services/notifications/NotificationsService.qml)
is a pure life-cycle/history object with no Quickshell import. It owns the
records, expiry timers, the preserved list contract, persistence serialization,
image-cache path calculation and dismissal policy. It never constructs a native
object and never writes a file.

[`NativeNotificationBackend.qml`](../services/notifications/NativeNotificationBackend.qml)
is the thin native wrapper. It is loaded by URL only when the opt-in is present,
constructs `NotificationServer`, and sets `mirrorSystemNotifications: false` at
construction (the pinned backend default is true). It requests no system access
and keeps `keepOnReload` false.

[`Notifs.qml`](../services/notifications/Notifs.qml) is the singleton facade
replacing the original `Notifs`. It reads only the isolated
`Quickshell.stateDir`/`cacheDir`, validates that both are strict descendants of
the profile root, and owns the history `FileView`. There is no HOME, XDG or
`Paths.state` fallback in these files.

States are explicit:

| state | meaning |
| --- | --- |
| `disabled` | opt-in absent; no native loader, server or original UI |
| `initializing` | wrapper loaded, native server not marked ready yet |
| `local` | local delivery is available; mirroring is off |
| `unavailable` | wrapper component failed to load |
| `mirroring-blocked` | a backend reported mirroring on; records are refused |
| `contended` | an injected backend reports another owner; no local delivery |
| `unconfirmed` | a local send did not arrive locally; another owner may be active |

The pinned backend performs its own five-second mutex claim retry
([`server.cpp`](../deps/quickshell/src/windows/services/notifications/server.cpp),
lines 55-91) but publishes no ownership property to QML. Native runs therefore
report `ownership: "unknown"` and do not claim or guess otherwise. The
`contended` state and its copy are exercised by the fixture and are ready for a
backend revision that exposes the claim result. A local send that never arrives
is reported as `unconfirmed` with the same "another notification owner may be
active" hint; it does not retry or fight ownership.

## Local delivery, expiry and dismissal

`notifySend(summary, body, args)` is the only staged delivery path. The fixture
and native smoke use it; the host never sends automatically outside its smoke
opt-in. On delivery the service sets `tracked` (in the wrapper), copies the
original fields into a `NotifData`, prepends it to `list`, and shows it in
`popups` unless suppressed. The original card's timer stops on hover and the
original swipe-to-close calls `close()`.

Expiry mirrors upstream: the record's timer hides the popup after
`expireTimeout` (or `defaultExpireTimeout` / `fullscreenExpireTimeout`) when
`Config.notifs.expire` is true. The record remains in the notification-center
list, exactly as the original popup/notification-center split behaves.

Dismiss calls the native `Notification.dismiss()` only for a local record. A
record carrying the backend's `x-windows-toast-id` or `x-windows-aumid` hint is
removed from the local UI without dismissal and increments a protected counter.
Because mirroring stays off, that branch cannot be reached by this slice's own
delivery path; the fixture still proves it.

History is a JSON array under the profile's `state/notifs.json`, including the
time, stable record id, original notification id, summary/body/app/text/image
fields, expiry, urgency, resident/action-icon flags and action identifiers. A
missing file starts empty; corrupt JSON or a non-list is reported through
`historyError` without a crash; a valid list is sorted newest first and restored
without a native notification. Backend ids restart at 1 per process, so records
also carry a stable `recordId` for identity after a restart.

## Image cache

The original `NotifData` rasterised remote images through a hidden native
window. This slice keeps the same bounded technique in
[`NotifImageCache.qml`](../services/notifications/NotifImageCache.qml), but the
destination is always `NotificationsService.imageCachePath()` under the profile
`cache/notifs` directory. A path outside that directory is rejected. Icons from
the icon provider and images already in the confined cache never request a copy.
The smoke path posts no image, so the native writer itself is not exercised in
the recorded runs; the fixture covers path generation, acceptance and refusal.

## Opt-in and launch

The only opt-in is the child-process variable
`CAELESTIA_WINDOWS_NOTIFICATIONS=1`, mapped from
`-NotificationsMode Local`. There is no mirroring or interactive mode. Disabled
mode never constructs `NotificationServer` and never loads the original
components.

```powershell
$qtPrefix = "$env:LOCALAPPDATA\caelestia-dev\Qt\6.11.2\msvc2022_64"
powershell -NoProfile -File windows/scripts/Start-ShellPrototype.ps1 `
    -QtPrefix $qtPrefix -Notifications -NotificationsMode Local -Wait
```

Use `-Smoke` for the bounded no-input run. `-NotificationsMode Disabled` is the
default and is also what every non-notification entry point uses.

## Localized original/upstream adaptation

No file under `modules/notifications` or `modules/sidebar` was edited. Windows
adapters are staged only into this host:

- `windows/notifications-prototype/adapters/components/effects/ColouredIcon.qml`
  replaces the excluded `Caelestia.Images` dominant-colour analyser with the
  requested colour while preserving `IconImage`/`Colouriser` behaviour.
- `windows/notifications-prototype/adapters/modules/utilities/Wrapper.qml`
  satisfies the original `Content.qml` utilities type reference; its
  `screenState.utilities` branch stays false and the real utilities tree is not
  staged.
- The shared fixed palette adapter gained the upstream palette names and an
  identity `layer()` used by notifications, plus the non-error `absolutePath`
  return used by the original empty-state image. Upstream Linux defaults are
  untouched.

## Validation

```powershell
powershell -NoProfile -File windows/scripts/Test-NotificationService.ps1 `
    -QtPrefix $qtPrefix
powershell -NoProfile -File windows/scripts/Test-NotificationsPrototype.ps1 `
    -QtPrefix $qtPrefix
```

`Test-NotificationService.ps1` stages only `NotificationsService.qml`,
`NotifData.qml` and the fixture into Qt's offscreen `qml.exe`; it rejects native
imports, path fallbacks, upstream image-cache references, mirroring enabled,
notification access requests, staging hash mismatches and QML diagnostics. The
fixture covers disabled construction, path confinement (including HOME/XDG,
outside-profile and missing roots), mirroring refusal, owner/contended/unknown
states, local arrival, the original action/lock/close contract, expiry, local
vs toast-backed dismissal, progressive updates, persistence round-trip,
corrupt/missing/non-list history, stable record ids, image-cache acceptance and
refusal, and a real Timer-driven popup expiry.

`Test-NotificationsPrototype.ps1` runs the fixture, disabled smoke on every
connected screen, a fresh local persist run, a second-process restore/expiry/
dismiss run, local smoke on the remaining screens, the M1 bar/session
regression, and the media/battery service fixtures. It records both profile
paths, the ordinary user notification history before/after, desktop state and
screenshots.

## Limits

- Native evidence uses the pinned backend's local path and a real shell-owned
  server. It does not claim system mirroring, notification-listener access,
  Windows notification removal, denied-access behaviour or app-open semantics;
  those belong to ERM-503.
- The pinned backend does not publish claim ownership. Native runs report
  `unknown`; the explicit `contended` state is fixture-only until a backend
  revision exposes it. A "not delivered locally" probe is a hint, not proof. If
  another Quickshell notification owner holds the session mutex, the bounded
  smoke's single `notifySend` is forwarded by the backend instead of arriving
  locally; the run fails with the competing-owner hint rather than retrying or
  fighting the claim.
- The image-cache writer is implemented but the native smoke posts no image;
  only path validation and refusal are recorded natively.
- The sidebar dock is staged only as a notification list; its empty-state
  picture is intentionally unavailable on Windows.
- Notifications are local-only, so ordinary Windows applications cannot create
  them in this slice. No real Windows notification was read, requested or
  dismissed by the recorded runs.
