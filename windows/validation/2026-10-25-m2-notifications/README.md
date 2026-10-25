# M2 notifications validation

ERM-502's bounded Windows notification slice at clean root
`521f4a64d602b29657924939648515feaac6c305`, backend pin
`1401042969e4b7ab3cfb314fc76945ab081db3de`. The recorded harness reports
`sourceDirty: false`; the archive files were added in a later commit.

## Sources and environment

| source | sha256 |
| --- | --- |
| `windows/services/notifications/NotificationsService.qml` | `02C26240B120CD7B14C88285B1013F4E711DE9C77C18CB48A6EF02DE1212C9D5` |
| `windows/services/notifications/NotifData.qml` | `D2A7848F7737F13C2FDA4735A17651D9A07C102268F61AD52B3D457D00A859A4` |
| `windows/services/notifications/Notifs.qml` | `D72342ACDF0C1F99029A1C45F955D7569DEB4FB6714BCAE2ED920E529E59242E` |
| `windows/services/notifications/NativeNotificationBackend.qml` | `9DF3CA72CCF0C9DBC004D0262759961C47E4A412099885ECD7D2532354550479` |
| `windows/services/notifications/NotifImageCache.qml` | `DA87459AF23F7A79C7635FBE1D654307209E42E7887DD2C4F2B6F4876DCBD767` |
| `windows/services/notifications/NotificationsServiceTest.qml` | `BC34AA3B8A1A1BFDBFF3A485802DEB58CA19F4958CEE54C4823119E1AE804B02` |
| `windows/notifications-prototype/shell.qml` | `C575051703ECCC0BC8F4F157C74179C676FEF1F8BFA872797E9C2E889D694240` |
| `windows/notifications-prototype/sources.json` | `1909F9FC0E0D94AF25E2157CD6F1AA8766E9A9D5663E98BA62478C4E1DBEB32C` |
| `windows/scripts/Test-NotificationService.ps1` | `36B5FAD53AE767EC70F9C78F86AE7F6FE1139B0E3673E9FD1E0B0212D6BEA878` |
| `windows/scripts/Test-NotificationsPrototype.ps1` | `DC7AC9FB369D28BD40ECD44A4433F2A833D7906FB10C8BCDFBC4220425CBD4A3` |
| `windows/scripts/Stage-ShellPrototype.ps1` | `39F23D04D6CE58690672470374536583C7CA3B7C9DF8E7B76C0402B84856FF8E` |
| `windows/scripts/Start-ShellPrototype.ps1` | `18E98BA93E639CD4AD245F73502B95682E04CE6CE0525819C1933D4033AD4F9D` |
| `windows/shell-prototype/adapters/services/Colours.qml` | `0C3083D7F2DE9F0CF5BAE566DBB4CEBDD2608C3CE8636232361306CAEF3D38A8` |
| `windows/shell-prototype/adapters/utils/Paths.qml` | `E427BF861436ECA08E06A402AD7678D4F323D03B697AD380ED8C5D285BCA5CB4` |
| `windows/audits/M2-SERVICES.md` | `F4063280FAD0E7879133D949586F5C5DE1AE90B7E7BEF1D7AF4C188D7BD9728E` |

Toolchain and runners used by the runs:

- Qt `6.11.2`, `qml.exe` sha256
  `24994D434962751713F0C8932B356104B0849572B95765DAD50C13DA6BE3FA20`.
- Shared native build `windows/.local/build`, `qs.exe` sha256
  `22B69FFE0523F8FFDB86C22E1669A36B2C8DCAEA97B19754000EC7455345AF22`.
  The build was not rebuilt for these QML-only changes; `build/build.json`
  (sha256 `3FA201EE45FC755B663FF122090B617D222BBFD99352B18F490B003F0C14FED1`)
  records the existing build.
- Windows, two connected screens: `MAG321UX OLED` at 150% (origin 0,0) and
  `DELL S2725QS` at 175% (origin -3840,0). Native runs used the measured DPI.

## Commands

```powershell
$qtPrefix = "$env:LOCALAPPDATA\caelestia-dev\Qt\6.11.2\msvc2022_64"
$buildRoot = 'D:\AiStack\caelestia-windows\windows\.local\build'

powershell -NoProfile -File windows/scripts/Test-NotificationService.ps1 `
    -QtPrefix $qtPrefix -BuildRoot $buildRoot
powershell -NoProfile -File windows/scripts/Test-NotificationsPrototype.ps1 `
    -QtPrefix $qtPrefix -BuildRoot $buildRoot
powershell -NoProfile -File windows/scripts/Test-MediaService.ps1 `
    -QtPrefix $qtPrefix -BuildRoot $buildRoot
powershell -NoProfile -File windows/scripts/Test-BatteryService.ps1 `
    -QtPrefix $qtPrefix -BuildRoot $buildRoot
```

## Results

### Fixture

`fixture-standalone/result.json` (also embedded in `matrix.json`):

- `passed: true`, exit `0`, timed out `false`.
- **136 assertions**.
- No native imports, no HOME/XDG/`Paths` fallback, no upstream
  `notifimagecache` reference, no `NotificationServer` in the pure service or
  record, and no diagnostics. All static checks are `true`, including
  `wrapperMirroringFalseAtConstruction`, `wrapperNeverEnablesMirroring` and
  `noNotificationAccessRequest`.
- Covers disabled construction, path confinement (empty, missing, distinct,
  outside-profile and HOME/XDG roots), mirroring refusal, owner/contended/
  unknown ownership, local arrival, the original action/lock/close contract,
  expiry, local versus toast-backed dismissal, progressive updates, persistence
  round-trip, corrupt/missing/non-list history, stable record ids, image-cache
  acceptance/refusal and a real Timer-driven popup expiry.

### Native prototype

`matrix.json` records nine passing entries from clean `521f4a64`:

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

Each native run asserted:

- Disabled: no native loader, no `NotificationServer`, no original notification
  components, no records.
- Local: the original popup card and sidebar notification center loaded, the
  native loader/server was active, mirroring was off, system notification
  access stayed `Unknown` (`0`), and `ownership` stayed `unknown`.
- Fresh local run: one local `notifySend` arrived, appeared in the original
  popup list with its action, and persisted.
- Restart run: the previous notification was restored from a separate process,
  the new notification expired out of the popup list but remained in the list
  until dismissed, and dismissal removed only the local record.
- The sidebar notification center screenshot after restart shows the restored
  entry while the popup list is empty.
- Every run rejected QML diagnostics and recorded the stage/profile/source
  hashes.

Evidence:

- `local-persist-local-screen0/capture.png` — 150% fresh local delivery:
  original popup card and sidebar notification center.
- `local-expire-dismiss-local-screen0/capture.png` — 150% restart: restored
  notification in the center; the new popup expired and was dismissed.
- `local-extra-screen-local-screen1/capture.png` — 175% negative-origin screen.
- `disabled-disabled-screen0/capture.png`,
  `disabled-disabled-screen1/capture.png` — no native service or original UI.
- Per-run `stdout.log`, `stderr.log`, `result.json` and `sources.json` are in
  each directory. `staged-*` files are the exact source copies used by the
  fixture.

Persisted history (`profile-history.json`) is at
`<profile>/state/notifs.json`; the final file contains exactly the restored
record:

```json
[{"time":1792966503268,"recordId":"1-1792966503268","notificationId":"1","summary":"Caelestia Windows local notification","body":"Local delivery test 1792966502005","appIcon":"","appName":"Caelestia Windows","image":"","expireTimeout":60000,"urgency":1,"resident":false,"hasActionIcons":false,"actions":[{"identifier":"default","text":"Open"}],"local":true}]
```

No `cache/notifs` directory was created; the smoke path posted no image.

### Regressions

- `regressions/media-service/result.json`: `passed: true`, **148 assertions**,
  clean `521f4a64`.
- `regressions/battery-service/result.json`: `passed: true`, **128 assertions**,
  clean `521f4a64`.
- `m1-regression/`: the original bar/session smoke passed.

The legacy user path `%USERPROFILE%\.local\state\caelestia\notifs.json` did not
exist before or after (`legacyHistoryBefore` and `legacyHistoryAfter` both
`exists: false`). The isolated history path was
`D:\AiStack\caelestia-windows\windows\.local\build\notifications-prototype-profile\state\notifs.json`.

Desktop comparison (monitors, taskbar, Explorer, installed shell) was unchanged.
Transient `qs.exe` smoke processes are excluded from that identity because our
own runs and concurrent agents create and retire them.

## Real Windows notifications

System notification mirroring was never enabled:

- the wrapper sets `mirrorSystemNotifications: false` at construction;
- no `requestSystemNotificationAccess` call exists in the staged code;
- the smoke observed `systemMirrorActive: false` and
  `systemNotificationAccess: Unknown (0)`;
- every dismissal targeted only the local test record (`localDismissals`), and
  `protectedDismissals` stayed `0`;
- fixture records carrying `x-windows-toast-id`/`x-windows-aumid` were removed
  from the local UI without calling `dismiss()`.

This is not a measurement of the Windows notification database. It establishes
that this code path never constructs the mirror, requests access or issues a
Windows notification removal.

## Limits

- The pinned backend's claim retry happens inside `server.cpp` (lines 55-91) and
  is not published to QML. Native ownership is therefore `unknown`; the
  `contended` and `unconfirmed` states are fixture-covered and ready for a
  backend revision that exposes the claim result. A missing local delivery is
  reported as a likely competing owner, not proven ownership. If another
  Quickshell owner holds the session mutex, the single smoke send is forwarded
  by the backend and the run fails with that hint instead of retrying.
- The image-cache writer is implemented (hidden `PanelWindow` + `CUtils.saveItem`)
  but native evidence posts no image. Only the confined path calculation,
  acceptance and refusal are recorded.
- No system consent prompt, denied listener access, Windows notification
  dismissal or app-open path is exercised; those belong to ERM-503.
- The app icon uses a Windows-localized `ColouredIcon` adapter because
  `Caelestia.Images` is excluded from the portable build. The notification
  centre's empty-state picture is intentionally unavailable on Windows.
- This is an opt-in bounded host, not the full shell or a packaged release.
