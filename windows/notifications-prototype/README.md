# Windows notifications prototype

ERM-502's bounded M2 notification slice delivers notifications sent through the
pinned backend's **local** notification path into the original Caelestia popup
card and sidebar notification center. ERM-503 adds an **off-by-default,
consent-gated system mirroring** layer: Windows toasts can be shown in the same
original components only after an explicit user action grants notification
listener access, and the two side effects of a mirrored record (Windows
dismissal and app-open) each need their own opt-in.

Local-only delivery remains the default and unchanged: no Windows toast is read,
no notification-listener access is requested, and no local dismiss can remove a
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
image source policy and dismissal policy. It never constructs a native object,
never writes a file, and never copies, lists or deletes a notification image.

[`NativeNotificationBackend.qml`](../services/notifications/NativeNotificationBackend.qml)
is the thin native wrapper. It is loaded by URL only when the opt-in is present,
constructs `NotificationServer`, and sets `mirrorSystemNotifications: false` at
construction (the pinned backend default is true). It requests no system access
and keeps `keepOnReload` false.

[`Notifs.qml`](../services/notifications/Notifs.qml) is the singleton facade
replacing the original `Notifs`. It reads only the isolated
`Quickshell.stateDir`, validates that it is a strict descendant of the profile
root, and owns the history `FileView`. There is no HOME, XDG or `Paths.state`
fallback in these files.

States are explicit:

| state | meaning |
| --- | --- |
| `disabled` | opt-in absent; no native loader, server or original UI |
| `initializing` | wrapper loaded, native server not marked ready yet |
| `local` | local delivery is available; mirroring is off |
| `unavailable` | wrapper component failed to load |
| `mirroring-blocked` | a backend reported mirroring on without the mirror opt-in; records are refused |
| `contended` | an injected backend reports another owner; no local delivery |
| `unconfirmed` | a local send did not arrive locally; another owner may be active |

`status` describes local delivery. Mirroring has its own `mirrorStatus`
(`disabled`, `initializing`, `blocked`, `consent-required`, `pending`, `allowed`,
`denied`, `timed-out`, `unavailable`, `unknown`), which drives the notification
center row.

The pinned backend performs its own five-second mutex claim retry
([`server.cpp`](../deps/quickshell/src/windows/services/notifications/server.cpp),
lines 55-91) but publishes no ownership property to QML. Native runs therefore
report `ownership: "unknown"` and do not claim or guess otherwise. The
`contended` state and its copy are exercised by the fixture and are ready for a
backend revision that exposes the claim result. A local send that never arrives
is reported as `unconfirmed` with the same "another notification owner may be
active" hint; it does not retry or fight ownership.

## System notification mirroring

Mirroring is a second, independent opt-in. It is never enabled by the local
flag, and it still starts unrequested: the service cannot ask for listener
access until the user presses the button in the original notification center.

| variable | effect |
| --- | --- |
| `CAELESTIA_WINDOWS_NOTIFICATIONS=1` | local delivery (unchanged) |
| `..._NOTIFICATION_MIRROR=1` | permits the consent flow and later mirrored delivery |
| `..._NOTIFICATION_MIRROR_DISMISS=1` | dismissing a mirrored record also removes the real Windows toast |
| `..._NOTIFICATION_APP_OPEN=1` | the mirrored record's "Open" action may activate or launch its app |

`-NotificationsMode Mirror` maps to the first two; `-NotificationDismiss` and
`-NotificationAppOpen` are additive switches. **Smoke always forces all three
mirroring variables off**, so the recorded native runs never create the mirror
worker.

Access states follow the backend contract: `Unknown`, `Unspecified`, `Allowed`,
`Denied`, `Unavailable`. The service never reads the status natively itself. At
the pinned backend `NotificationServer.systemNotificationAccess` returns
`Unknown` until a `ToastMirror` exists, and the mirror is created by the access
request itself, which may prompt. The service therefore exposes the staged,
un-requested state as `Unspecified` (consent undecided) and keeps `Unknown` for
an absent/unready backend or an unrecognised value. The backend only raises an
OS prompt when Windows reports `Unspecified`, so an explicit click never
re-prompts an already decided system.

Consent:

- One explicit `requestAccess()` from the notification-center button, only while
  the state is `Unspecified` and only once per process. It is refused from
  `Allowed`, `Denied`, `Unavailable`, `Unknown`, after a previous attempt and
  while a request is pending.
- The answer is awaited for a bounded 60 seconds. A timeout is reported
  (`timed-out`) and is **not** retried; the center offers Windows settings.
- `Allowed` enables `mirrorSystemNotifications` on the backend at most once.
  Nothing else writes it.
- `Denied` never enables mirroring and never retries the prompt. The center
  shows the denied state and an explicit **Open Windows settings** action backed
  by `Quickshell.Windows.NotificationSettings.openAccessSettings()`
  (`ms-settings:privacy-notifications`). Status polling is capped at five checks
  and only runs while the notification center is visible; hiding it stops
  polling immediately and the budget is not reset by re-showing it.

Mirrored records:

- Identified only by the backend's `x-windows-toast-id` / `x-windows-aumid`
  hints. They keep the original app name/icon fields, so nothing new is added to
  the visual language.
- **Not persisted** to `state/notifs.json`. They are live Windows state: Windows
  and the source app own their lifetime, and a restored copy would outlive the
  real toast. The history filter keeps local records only.
- Dismissal hides the record locally by default. With
  `CAELESTIA_WINDOWS_NOTIFICATION_MIRROR_DISMISS=1` it calls the backend's
  `Notification.dismiss()`, which removes the real Windows toast
  (`server.cpp` `deleteNotification`).
- App-open requires `CAELESTIA_WINDOWS_NOTIFICATION_APP_OPEN=1`. Without it the
  "Open" action stays visible but uses the existing disabled styling
  (`ButtonBase.disabled` / 38% content opacity), and the service refuses a
  direct `invoke()` as well.

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

Dismiss calls the native `Notification.dismiss()` directly only for a local
record. A mirrored record follows the separate policy above: local-only removal
by default, Windows removal only with the dismissal opt-in. Local records never
carry a Windows toast identity, so a local dismiss cannot remove a real
notification.

History is a JSON array under the profile's `state/notifs.json`, including the
time, stable record id, original notification id, summary/body/app/text/image
fields, expiry, urgency, resident/action-icon flags and action identifiers. A
missing file starts empty; corrupt JSON or a non-list is reported through
`historyError` without a crash; a valid list is sorted newest first and restored
without a native notification. Backend ids restart at 1 per process, so records
also carry a stable `recordId` for identity after a restart.

## Image policy

A notification image is used only when
`NotificationsService.validateImageSource()` accepts it. The policy is purely
lexical (no filesystem access) and accepts exactly two forms:

- an `image://icon/<theme-name>` provider URL, where the name matches
  `^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$`: a bare theme name with no path, query
  (`?fallback=`/`?path=`), fragment, authority or percent escape. Every other
  provider is rejected because `QIcon::fromTheme` loads absolute paths and
  honours a fallback name;
- a file already inside the staged shell assets directory
  (`Quickshell.shellPath("assets")`), after a local path is validated.

Local paths are rejected if the source contains `%` anywhere, is UNC
(`\\server`), a device path (`\\?\`/`\\.\`), protocol-relative (`//`) or a
`file://host` URL, carries an alternate data stream (`:` beyond the drive
letter), is relative or drive-relative, contains a `.`/`..` component, has a
component ending in `.` or a space, or contains `~` (an 8.3 short-name alias).
The remaining path must be a strict, case-insensitive child of the staged assets
directory. The URL handed to the original card is rebuilt from the validated
path as `file:///C:/...` with each path segment percent-encoded, so `#` and `?`
in a staged file name cannot become a fragment or query; the raw input is never
used. The staged assets root comes from trusted staging, not notification input,
and the validator is lexical (it does not detect reparse points).

App icons are validated by the same rule (a theme name or a staged asset path);
anything else becomes `""`, so the original fallback icon renders. Notification
bodies are sanitized before the original Markdown-rendering popup/sidebar sees
them: Markdown inline and reference images are replaced with their alt text,
reference definition lines are removed, and `<img>`, `<picture>`, `<source>`,
`<svg>`, `<image>`, `<object>`, `<embed>` and `<iframe>` tags are removed.
Ordinary text and links are kept. Live bodies, body updates and restored history
all go through the filter.

There is no image cache: no notification image is copied, written, listed,
pruned or deleted by this slice. Rejected or unsupported sources are cleared to
`""`, so the original card shows its existing fallback icon. Persisted history
images, app icons and bodies are re-validated on restore.

App-supplied notification images outside the staged assets directory therefore
show the fallback icon by design. That is the intentional trade for removing the
copy/validation surface; a later slice can add a non-copying staged-asset
ingest if the product needs arbitrary app images.

The original `NotifData` rasterised remote images through a hidden native window;
that path (and the interim byte-copy writer) is removed.

## Opt-in and launch

The base opt-in is the child-process variable
`CAELESTIA_WINDOWS_NOTIFICATIONS=1`, mapped from `-NotificationsMode Local`.
`-NotificationsMode Mirror` adds `CAELESTIA_WINDOWS_NOTIFICATION_MIRROR=1`
(consent-gated) and optionally the dismissal/app-open variables through
`-NotificationDismiss`/`-NotificationAppOpen`. Disabled mode never constructs
`NotificationServer` and never loads the original components.

```powershell
$qtPrefix = "$env:LOCALAPPDATA\caelestia-dev\Qt\6.11.2\msvc2022_64"
powershell -NoProfile -File windows/scripts/Start-ShellPrototype.ps1 `
    -QtPrefix $qtPrefix -Notifications -NotificationsMode Local -Wait
```

Use `-Smoke` for the bounded no-input run. Smoke forces mirroring, dismissal and
app-open off even in Mirror mode. `-NotificationsMode Disabled` is the default
and is also what every non-notification entry point uses.

## Localized original/upstream adaptation

ERM-503 touched three original files, additively and with unchanged defaults:

- [`NotifDock.qml`](../../modules/sidebar/NotifDock.qml) gained an optional
  `mirrorControl` (null by default) and a status row with the consent and
  "Open Windows settings" buttons. With no control injected the row has zero
  height and the original layout is identical.
- [`Notification.qml`](../../modules/notifications/Notification.qml) passes the
  action's `disabled` flag to the existing `TextButton` disabled styling.
- [`NotifActionList.qml`](../../modules/sidebar/NotifActionList.qml) uses the
  same 38%-opacity disabled treatment and disables its `StateLayer` for a
  disabled action.

Windows adapter files staged only into this host:

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
imports, path fallbacks, any remaining image-cache/copy/listing code, the
deleted writer component, mirroring enabled, notification access requests,
staging hash mismatches and QML diagnostics. It also requires exactly one native
access-request function, one service request function and one call site, and
that the original notification center is the only consent button. The fixture
covers disabled construction, path confinement (including HOME/XDG,
outside-profile and missing roots), mirroring refusal, owner/contended/unknown
states, local arrival, the original action/lock/close contract, expiry, local
vs toast-backed dismissal, progressive updates, persistence round-trip,
replacement-send refusal, corrupt/missing/non-list history, stable record ids,
every image-policy rejection class, restore re-validation, a real Timer-driven
popup expiry, and the mirroring cases: every access state, one explicit consent
request (never automatic or repeated, latched for the process after a reload),
consent timeout, Allowed enabling with both-direction revocation, denied
polling bounds/visibility and non-prompting recovery, toast-hint
identification, local-only versus opted-in dismissal, app-open through
mirrored activation (refused at the pinned backend revision), and no
persistence of mirrored records.

`Test-NotificationsPrototype.ps1` runs the fixture, disabled smoke on every
connected screen, a fresh local persist run, a second-process restore/expiry/
dismiss run, local smoke on the remaining screens, the M1 bar/session
regression, and the media/battery service fixtures. It asserts that every
native snapshot has mirroring, access requests, mirrored records, dismissal,
app-open and settings actions at zero. It records both profile paths, the
ordinary user notification history before/after, desktop state and screenshots.

## Limits

- Native evidence uses the pinned backend's local path and a real shell-owned
  server. **Native mirroring, consent, denied access, Windows dismissal and
  app-open were not exercised**: smoke forces those opt-ins off. Their behavior
  is fixture-only.
- The pinned backend has no read-only access query: `systemNotificationAccess`
  is `Unknown` until a `ToastMirror` exists, and creating it is the request
  path. The service exposes the staged un-requested state as `Unspecified` and
  documents that mapping; a backend that publishes a non-prompting status read
  would make it a real measurement.
- `ToastMirrorWorker::setEnabled(true)` calls `begin(true)`
  (`toast_worker.cpp` lines 102-113), so the backend's setter itself can request
  access if Windows reports `Unspecified` at that moment. The service only calls
  it after observing `Allowed`, so no prompt is expected; the race is a backend
  gap, not a service behavior.
- Once mirroring is allowed, the backend polls access every ten seconds while it
  is non-Allowed (`toast_worker.cpp` lines 141-193). That timer is inside the
  backend and is not visibility-scoped; the service's own denied polling is
  bounded to the visible center, but it can only observe the value the backend
  published.
- The pinned backend does not publish claim ownership. Native runs report
  `unknown`; the explicit `contended` state is fixture-only until a backend
  revision exposes it. A "not delivered locally" probe is a hint, not proof. If
  another Quickshell notification owner holds the session mutex, the bounded
  smoke's single `notifySend` is forwarded by the backend instead of arriving
  locally; the run fails with the competing-owner hint rather than retrying or
  fighting the claim.
- The image policy is enforced by the fixture only: the native smoke posts no
  image, so a provider/asset image has not been rendered by the original card.
  Rejected sources and the fallback icon are fixture-covered.
- App-supplied images outside the staged assets directory show the fallback icon
  by design; there is no image copy, cache or ingest path in this slice.
- The sidebar dock is staged only as a notification list; its empty-state
  picture is intentionally unavailable on Windows.
- Notifications are local-only, so ordinary Windows applications cannot create
  them in this slice. No real Windows notification was read, requested or
  dismissed by the recorded runs.
