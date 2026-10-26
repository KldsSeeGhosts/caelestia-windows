# M2 notification mirroring validation

ERM-503's consent-gated system notification mirroring on top of ERM-502's local
delivery. Clean root `0299e4daf4d002f88769fe43aa4d5b00cd915e38`, backend pin
`1401042969e4b7ab3cfb314fc76945ab081db3de`. The recorded harness reports
`sourceDirty: false`; the archive files were added in a later commit.

All mirroring behavior in this archive was validated with **fixtures only**.
Native runs covered Disabled and Local modes, where every mirroring, access,
dismissal, app-open and settings counter stayed at zero. See
[Native limits](#native-limits) before citing this evidence.

## Sources and environment

| source | sha256 |
| --- | --- |
| `windows/services/notifications/NotificationsService.qml` | `A49F579F744F10BC6684F2FEB1BE291AFDF28FCFCBBA2DEF2FB8E23F2313C019` |
| `windows/services/notifications/NotifData.qml` | `4615D82985483E085C83CE32F9F665D3478047A5DF86C62CE2FCB553B2B74007` |
| `windows/services/notifications/Notifs.qml` | `7F1B78905FF8AF1C315DC61520F9B6ED3968A9106BD99CFC5901374C3647771C` |
| `windows/services/notifications/NativeNotificationBackend.qml` | `4C0BCF6050AD3EA0428090709BF528FFCA95A040AF25203AF7590FCAA2498B7A` |
| `windows/services/notifications/NotifImageCache.qml` | `7DA44B26DC6114F0BE950F0DA160597C37E707BD63A2B53F326E33C39F638EEC` |
| `windows/services/notifications/NotificationsServiceTest.qml` | `57D38735967BFA4EDB1656E2BE0AB56118808A755267C452030C0CDC9F47B45D` |
| `windows/notifications-prototype/shell.qml` | `CC1E95BAE115ABFA159A96F6B2F3A2DB707AB82F5041A8239EE25CEC388D4B97` |
| `windows/notifications-prototype/sources.json` | `0811068079C05E4002F7A9DADA70D7E1E87AAA5136539ED4A57F0A8F0FA805AE` |
| `windows/notifications-prototype/README.md` | `278912F0F46A543A5E54233A7981CE461A9D42F76C4645968560F46896818785` |
| `windows/scripts/Test-NotificationService.ps1` | `028C96C53C77B52CB26DC4C68DD2A1020060BF5A1ADB9413BAD2A9C795538B8F` |
| `windows/scripts/Test-NotificationsPrototype.ps1` | `161F3B6E271119BCAF37463866EF7F21E61B18C1E9B183CBB1BE8518909BAAB6` |
| `windows/scripts/Start-ShellPrototype.ps1` | `32EFC213727199D3AD4B7E16F53D209FFBA416F13AF410D2F80055C65647B941` |
| `windows/scripts/Stage-ShellPrototype.ps1` | `39F23D04D6CE58690672470374536583C7CA3B7C9DF8E7B76C0402B84856FF8E` |
| `modules/notifications/Notification.qml` | `6DBFE1A43906FB3F4D0B75ADCCEF32B18DC87EF4B1CDA795DABC290038B55F25` |
| `modules/sidebar/NotifActionList.qml` | `CDF643F8F5E137D07631661E7493F3B31E74578C1D20498DAE4E19D446455118` |
| `modules/sidebar/NotifDock.qml` | `950D089E11E15A2955BD3C91CE026A6B26B9EB8B9A0AD6803B79A73F07F9A558` |
| `windows/audits/M2-SERVICES.md` | `8B6C2B5E82C4825858E0973506D1DDD31A09055B683B64A025EA946C725B88E4` |

Toolchain and runners:

- Qt `6.11.2`, `qml.exe` sha256
  `24994D434962751713F0C8932B356104B0849572B95765DAD50C13DA6BE3FA20`.
- Shared native build `windows/.local/build`, `qs.exe` sha256
  `22B69FFE0523F8FFDB86C22E1669A36B2C8DCAEA97B19754000EC7455345AF22`.
  The build was not rebuilt for these QML-only changes; `build/build.json`
  (sha256 `3FA201EE45FC755B663FF122090B617D222BBFD99352B18F490B003F0C14FED1`)
  records the existing build (Qt 6.11.2, clang-cl 20.1.8, Windows SDK
  10.0.26100.0, built from `d9cdcf9a`).
- Windows, two connected screens: `MAG321UX OLED` at 150% (origin 0,0) and
  `DELL S2725QS` at 175% (origin -3840,0). Native runs used the measured DPI.

## Commands

```powershell
$qtPrefix = "$env:LOCALAPPDATA\caelestia-dev\Qt\6.11.2\msvc2022_64"
$buildRoot = 'D:\AiStack\caelestia-windows\windows\.local\build'

powershell -NoProfile -File windows/scripts/Test-NotificationsPrototype.ps1 `
    -QtPrefix $qtPrefix -BuildRoot $buildRoot
powershell -NoProfile -File windows/scripts/Test-NotificationService.ps1 `
    -QtPrefix $qtPrefix -BuildRoot $buildRoot
powershell -NoProfile -File windows/scripts/Test-MediaService.ps1 `
    -QtPrefix $qtPrefix -BuildRoot $buildRoot
powershell -NoProfile -File windows/scripts/Test-BatteryService.ps1 `
    -QtPrefix $qtPrefix -BuildRoot $buildRoot
```

`Test-NotificationsPrototype.ps1` ran the fixture, disabled smoke on both
screens, a fresh local persist run, a second-process restore/expire/dismiss run,
local smoke on the second screen, the M1 bar/session regression, and the
media/battery fixtures. Its output is `matrix.json` plus one directory per run.

## Results

### Fixture

`fixture-standalone/result.json` (also embedded in `matrix.json`):

- `passed: true`, exit `0`, timed out `false`, **221 assertions**.
- All 16 static checks are `true` and the staged/source hashes match. The checks
  require exactly one native `requestSystemNotificationAccess` (inside
  `NativeNotificationBackend.requestAccess`), one service `requestAccess()`
  function, exactly one backend request call site, no facade/record access
  request, and the original notification center as the only consent button.
- ERM-502's fixture assertions still pass, including its 136 original
  assertions' scenarios: disabled construction, path confinement, mirroring
  refusal without the opt-in, ownership states, local arrival, the
  action/lock/close contract, expiry, local vs toast-backed dismissal,
  progressive updates, persistence round-trip, corrupt/missing/non-list
  history, stable ids, image-cache acceptance/refusal, and real Timer expiry.
- New mirroring coverage:
  - every access value (`0/1/2/3/4/9/-1`) maps to
    Unknown/Unspecified/Allowed/Denied/Unavailable and consent is available only
    from Unspecified;
  - consent is refused from Allowed/Denied/Unavailable/Unknown, issued exactly
    once from Unspecified, never automatically (asserted again after the event
    loop) and never again after a timeout;
  - an unanswered request times out and exposes the Windows settings action;
  - Allowed writes `mirrorSystemNotifications` once and repeated refreshes do
    not write again; local delivery continues;
  - mirrored identification via `x-windows-toast-id`, via `x-windows-aumid`
    alone, and a local record without hints;
  - dismissal without the opt-in is local-only (no native dismiss,
    `protectedDismissals`/`mirroredLocalDismissals`), with the opt-in it calls
    `dismiss()` and counts a Windows dismissal;
  - app-open is disabled and refused without its opt-in, enabled with it; local
    actions are never gated;
  - mirrored records are excluded from serialized history and restored history
    is never mirrored;
  - denied polling is capped at five checks, stops immediately when the center
    is hidden, does not reset its budget on re-show, and never retries the
    prompt.

### Native prototype

`matrix.json` records nine passing entries from clean `0299e4da`:

| run | mode | screen | initial list | final list | final popup | dismissals |
| --- | --- | --- | --- | --- | --- | --- |
| fixture | - | - | - | - | - | - |
| disabled screen 0 | Disabled | 0 @ 150% | 0 | 0 | 0 | 0 |
| disabled screen 1 | Disabled | 1 @ 175% | 0 | 0 | 0 | 0 |
| local persist | Local | 0 @ 150% | 0 | 1 | 1 | 0 |
| local expire/dismiss | Local | 0 @ 150% | 1 | 1 | 0 | 1 |
| local extra screen | Local | 1 @ 175% | 1 | 1 | 0 | 1 |
| M1 regression | default | 0 @ 150% | - | - | - | - |
| media service regression | - | - | - | - | - | - |
| battery service regression | - | - | - | - | - | - |

Each native run asserted, in both the initial and final snapshot:

- `mirrorOptIn`, `mirrorControlEnabled`, `windowsDismissEnabled` and
  `appOpenEnabled` are `false`; `mirrorStatus` is `disabled`;
  `mirrorAccessState` is `Unknown`; `canRequestMirrorAccess` is `false`.
- `mirrorConsentRequested`, `mirrorConsentPending`,
  `mirrorSettingsActionRequired` are `false`; `settingsOpenRequests`,
  `mirrorAccessRequests`, `mirrorAccessRequestRefusals`, `mirrorWrites`,
  `mirroredCount`, `windowsDismissals`, `mirroredLocalDismissals`,
  `appOpenRefusals`, `appOpenInvocations` and `deniedPolls` are all `0`;
  `deniedPollingActive` is `false`.
- `mirroringOff` is `true`, `mirrorSystemNotifications` is `false`,
  `systemMirrorActive` is `false`, and the backend's published
  `systemNotificationAccess` is `0` in Local mode and `-1` in Disabled mode.
- `centerVisible` equals `dockLoaded`, so the original notification center was
  the visible surface and no denied polling was running.
- Local mode still delivered and persisted exactly one local `notifySend`, and
  the restart run restored it from a separate process, expired the new popup,
  and dismissed only the local test record.

`-NotificationsMode Mirror` was **not** run natively. The launcher forces
mirroring, dismissal and app-open off under `-Smoke`; no native run constructed
the mirror worker, requested notification-listener access, removed a Windows
notification or activated another app.

Evidence:

- `local-persist-local-screen0/capture.png` — 150% fresh local delivery:
  original popup card and sidebar notification center, with the mirroring row
  absent because the opt-in is off.
- `local-expire-dismiss-local-screen0/capture.png` — 150% restart: restored
  notification in the center; the new popup expired and was dismissed.
- `local-extra-screen-local-screen1/capture.png` — 175% negative-origin screen.
- `disabled-disabled-screen0/capture.png`,
  `disabled-disabled-screen1/capture.png` — no native service or original UI.
- Per-run `stdout.log`, `stderr.log`, `result.json` and `sources.json` are in
  each directory. `staged-*` files are the exact source copies used by the
  fixture.

`profile-history.json` is the final
`<profile>/state/notifs.json`. It contains exactly one local record and no
`x-windows-toast-id`/`x-windows-aumid` hint:

```json
[{"time":1792968233242,"recordId":"1-1792968233242","notificationId":"1","summary":"Caelestia Windows local notification","body":"Local delivery test 1792968231992","appIcon":"","appName":"Caelestia Windows","image":"","expireTimeout":60000,"urgency":1,"resident":false,"hasActionIcons":false,"actions":[{"identifier":"default","text":"Open"}],"local":true}]
```

No `cache/notifs` directory was created; the smoke path posted no image.

### Regressions

- `regressions/media-service/result.json`: `passed: true`, **148 assertions**,
  clean `0299e4da`.
- `regressions/battery-service/result.json`: `passed: true`, **128 assertions**,
  clean `0299e4da`.
- `m1-regression/`: the original bar/session smoke passed.

The legacy user path `%USERPROFILE%\.local\state\caelestia\notifs.json` did not
exist before or after (`legacyHistoryBefore` and `legacyHistoryAfter` both
`exists: false`). The isolated history path was
`D:\AiStack\caelestia-windows\windows\.local\build\notifications-prototype-profile\state\notifs.json`.

Desktop comparison (monitors, taskbar, Explorer, installed shell) was unchanged.
Transient `qs.exe` smoke processes are excluded from that identity because our
own runs and concurrent agents create and retire them.

## Native limits

Native mirroring, consent, denied polling, Windows dismissal and app-open were
**not exercised**. They are fixture-only. Specifically:

- No native run passed `CAELESTIA_WINDOWS_NOTIFICATION_MIRROR=1`, and no native
  run clicked the consent button.
- Reading `systemNotificationAccess` is safe but returns `Unknown` without the
  mirror worker; the native snapshots only confirm it was never created.
- The Windows settings action, the real Windows toast removal and app activation
  were only counted in fakes.

## Decisions and backend gaps

**Mirrored records are not persisted.** They are live Windows state owned by
Windows and the source app; a restored copy could outlive the real toast and
would misrepresent a notification the shell cannot re-read after a restart.
`serializeHistory` excludes them; the fixture proves a mixed list persists only
the local record.

Backend gaps found in the pinned revision (read only, no submodule change):

1. **No read-only access query.** `NotificationServerQml::systemNotificationAccess`
   (`qml.cpp` line 66) returns `NotificationServer::systemAccess()`, which is
   `Unknown` unless `mMirror` exists (`server.cpp` lines 424-426). Creating the
   mirror is the request path, so QML cannot observe `Unspecified` before
   consent. The service documents its staged-un-requested value as
   `Unspecified`; a real measurement needs a backend accessor that calls
   `GetAccessStatus` without `RequestAccessAsync`.
2. **Enabling the mirror can itself request access.**
   `ToastMirrorWorker::setEnabled(true)` calls `begin(true)`
   (`toast_worker.cpp` lines 102-113), and `begin` requests when the status is
   `Unspecified` (lines 115-139). The service only calls `setMirroring(true)`
   after observing `Allowed`, so no prompt is expected; the race is in the
   backend, not the service.
3. **Access polling is not visibility-scoped.** While enabled and non-Allowed,
   the backend runs a 10-second access timer (`toast_worker.cpp` lines 141-193)
   independent of any UI state. The service's own denied polling is bounded to
   five checks while the center is visible, but it can only observe the value
   the backend published.
4. **Dismissal removes the real toast at the backend level.**
   `Notification.dismiss()` → `deleteNotification` calls
   `ToastMirror::removeToast` for a Dismissed mirrored record (`server.cpp`
   lines 223-243), which maps to `RemoveNotification` (`toast_worker.cpp` lines
   272-281). The QML layer therefore gates it with the separate opt-in.
5. **App-open activates or launches another app.**
   `NotificationAction::invoke` → `NotificationServer::invokeAction` →
   `activateApp` for a mirrored `default` action (`server.cpp` lines 344-386).
   The QML layer refuses the invoke without its opt-in and marks the action
   disabled.
6. **Enabling after a mirror exists reads status again, never prompts for
   non-Unspecified values** (`toast_worker.cpp` lines 141-180), which is why the
   service waits for `Allowed` before writing.

## Upstream edits

Three original files were touched, all additively with unchanged Linux defaults:

- `modules/sidebar/NotifDock.qml`: optional `mirrorControl` property and a
  zero-height status/consent row when it is null.
- `modules/notifications/Notification.qml`: `disabled` on the existing action
  `TextButton`.
- `modules/sidebar/NotifActionList.qml`: disabled `StateLayer` and the existing
  38% disabled opacity.

No backend source, dependency pin, `windows/deps/quickshell`, `HANDOFF.md` or
`ROADMAP.md` was changed.

## Review addendum

An independent review of `736d992a` found six issues (two P1, four P2). All six
are fixed on `t3/notification-mirroring` (root `ef985779`, backend branch
`windows/m2-notification-mirror-consent` at `fe01579`, created from the
unchanged pin `1401042969`; the root gitlink and `windows/sources.lock.json`
were not updated). The concurrent notification image-cache removal from
`t3/notifications-local-delivery` was merged; conflicts were resolved by taking
the cache removal plus the mirroring fixes.

### Fixes

1. **P1 app-open bypassed the dismissal opt-in.** The backend gained
   `activateMirrored(id)`, which activates a mirrored toast's source app
   without the `Dismissed` auto-close that `NotificationAction::invoke` turned
   into a real-toast removal. The generic action path no longer auto-closes
   mirrored records at all; local records keep the original behavior. The
   service routes mirrored app-open through the new member and refuses it
   (counting a refusal) when the backend does not expose it — the pinned
   revision's case — so a body click or app-open can never remove the real
   Windows toast without the separate dismissal opt-in. The QML fixture's
   `FakeAction` now models the native auto-close, proving activation neither
   dismisses nor removes while an explicit dismiss still does.
2. **P1 enabling could issue a second automatic access request.**
   `ToastMirrorWorker::setEnabled(true)` now calls `begin(false)`: enabling the
   mirror (the consent path and session ownership acquisition, extracted into
   `NotificationServer::acquireOwnership`) only reads `GetAccessStatus`. The
   OS prompt belongs exclusively to `requestSystemAccess()`.
3. **P2 revocation never disabled mirroring.** `applyMirroring()` reconciles in
   both directions from raw inputs (property-change handlers can run before
   derived bindings re-evaluate, so `mirrorStaged`/`accessState` are not
   trusted there): lost access, a removed mirror opt-in, backend
   unavailability and service disable each withdraw the applied mirror with
   one `setMirroring(false)` write — which also stops the backend's
   ten-second access polling — and recovered access re-enables it with one
   fresh write.
4. **P2 denied polling could not detect recovery.** The backend gained the
   non-prompting `refreshAccessStatus()` (GetAccessStatus only, never
   RequestAccessAsync). The service's denied poll calls it inside the existing
   visible-center, five-poll budget, so a denied-to-allowed change made in
   Windows settings is observed and re-enables mirroring without any new
   prompt.
5. **P2 QML reload lost process-wide consent.** The explicit request latches a
   process-lifetime `accessRequested` (kept on the backend singleton and
   exposed read-only to QML). A reloaded service object reconciles with it: a
   cached `Allowed` re-enables mirroring without a new request, and an
   unanswered request is not repeatable in the same process.
6. **P2 Linux dock layout regressed.** `modules/sidebar/NotifDock.qml` anchors
   the list to `title.bottom` with the original `Tokens.spacing.medium`
   whenever the optional mirroring row is hidden, so the hidden zero-height
   row adds no gap above the list; the row keeps its `Tokens.spacing.small`
   margin only while visible.

Every new backend member is feature-detected in QML (`typeof` checks and
`=== true` reads), so the shared build at the pinned revision still loads the
facade and the service refuses the unsafe paths instead of using them.

### Re-validation

- Backend: the new `windows/scripts/Test-BackendNotifications.ps1` builds
  `notification_mirror_consent_test` plus the mpris/upower status regressions
  with the smallest seam faking the WinRT listener access status/request, app
  activation and window lookup. **7 + 6 + 9 passed, 0 failed** (consent test:
  enable never prompts; only the explicit request prompts and only from
  Unspecified; `refreshAccessStatus` never prompts; mirrored activation does
  not dismiss or remove while an explicit dismiss does; ownership acquisition
  enables without prompting). No test requests listener access, prompts,
  activates an app or removes a real notification.
- QML fixture: `Test-NotificationService.ps1` passes with **449 assertions**
  (221 before this slice), keeping every prior assertion except the single
  app-open one that finding 1 deliberately replaced, plus the merged
  replacement-send and image-policy coverage from
  `t3/notifications-local-delivery` and new sections for both-direction
  revocation, non-prompting recovery, reload reconciliation and the pinned
  backend revision.
- Native (`Test-NotificationsPrototype.ps1`, worktree sources against the
  shared pinned build, Disabled/Local smoke only): run
  `notifications-validation-20261025-202958-578` — fixture, two disabled
  screens, three local runs and the M1/media/battery regressions,
  **9/9 passed**; desktop and legacy-history identity unchanged; every
  mirroring, access, dismissal, app-open and settings counter stayed zero.

### Still not exercised natively

Real Windows access prompts, real toast mirroring/dismissal/removal, real app
activation and the backend's ten-second access timer remain fixture/seam-only;
native evidence still covers Disabled and Local smoke only.
