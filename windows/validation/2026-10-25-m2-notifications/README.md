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
  reported as forwarded/unconfirmed, not proven ownership. If another
  Quickshell owner holds the session mutex, the single smoke send is forwarded
  by the backend and the run fails with that hint instead of retrying.
- The image-cache writer copies the already validated local source into the
  confined cache. Native evidence posts no image, so the copy path and the
  directory listing/pruning are fixture- and probe-covered only (see the review
  addendum).
- No system consent prompt, denied listener access, Windows notification
  dismissal or app-open path is exercised; those belong to ERM-503.
- The app icon uses a Windows-localized `ColouredIcon` adapter because
  `Caelestia.Images` is excluded from the portable build. The notification
  centre's empty-state picture is intentionally unavailable on Windows.
- This is an opt-in bounded host, not the full shell or a packaged release.

## Review addendum

An independent review found five defects in the slice above. All five are fixed
here. Both harnesses were run against the uncommitted working tree on top of
`774bb319b644d32404e4e19497eb56dd8c95eca2`, which is why their own
`sourceRevision`/`sourceDirty` fields record `774bb319` and `sourceDirty: true`;
the fixes are committed immediately after those runs as a `windows:` commit.
The tree was dirty for every recorded run below.

Changed files: `windows/services/notifications/NotificationsService.qml`,
`NotifData.qml`, `NotifImageCache.qml`, `Notifs.qml`,
`NotificationsServiceTest.qml` and `windows/notifications-prototype/shell.qml`.

### 1. Notification image source trust

Defect: `NotifImageCache.qml` accepted any source and `needsImageCache()` only
rejected `image://` and already-cached paths, so an external `file:` URL, a UNC
share, a relative path or a `..` traversal could be loaded by the writer window
and by the original UI image.

Fix: `NotificationsService.validateImageSource(source)` is the single pure,
Quickshell-free decision. It returns `{accepted, kind, canonical, reason}` and
performs no filesystem access. It accepts only `image://` provider URLs and
local absolute non-UNC paths whose lexical canonical form (`\`→`/`, `.`/`..`
resolved, drive-root escape, alternate data streams and UNC authorities
rejected, case-insensitive containment) is a strict child of the isolated
profile cache directory, the isolated profile state directory, or the injected
staged shell assets directory. `NotifData.updateImage()` clears a rejected
source to `""` (the original card then shows its existing fallback icon),
records the reason on the record and in service state, and never exposes a
destination; `needsImageCache()`/`imageCachePath()` return nothing for it, so no
writer is ever pointed at it. Persisted history images are re-validated on
restore. The facade injects `shellAssetsDirectory` from
`Quickshell.shellPath("assets")`.

Coverage: fixture assertions for provider URLs, profile cache/state paths,
backslash paths, case-insensitivity, `..` normalisation, external absolute
paths, `file:///` and `file://server/` URLs, `\\`/`//` UNC shares, `http(s)`,
`data:`, `qrc:`, relative/drive-relative paths, a drive root, alternate data
streams, an uninjected assets directory, and live records whose rejected image
must stay empty with no writer slot and no cache target.

### 2. Cache retention and writer concurrency

Defect: cache file names embedded the notification id, every record started an
unbounded writer, and nothing ever pruned the cache.

Fix: the destination is
`imageCacheDirectory/<16-hex hash of the lowercased canonical source>.png`, so
repeats share one file. The service owns a bounded FIFO writer pool
(`maxConcurrentImageWriters = 2`, `maxQueuedImageWriters = 8`): a request beyond
the queue drops the oldest waiting record with a recorded reason and counter,
and completing, aborting or dismissing a record frees its slot and promotes the
next. Cache retention prunes files that no retained record references on every
dismissal/removal, after a successful write, and after history restoration;
a hard quota (`maxImageCacheFiles = 64`) then evicts the oldest referenced files
and clears their records' image. Deletion only ever targets a canonical path
strictly inside `imageCacheDirectory`; the service re-checks containment and the
injected remover re-checks it again, and a listing entry outside that directory
is skipped unread. The facade supplies the listing (a `FolderListModel` over the
confined cache directory) and deletion (`CUtils.deleteFile`).

Coverage: fixture assertions for the id-free hash file name, one shared file for
two records with the same source, two active slots, the 8-entry queue bound, the
two oldest drops and their recorded reason, FIFO promotion on completion and on
abort, recorded writer failures, slot release on dismissal, registry-only
pruning without a listing, listing pruning, refusal to delete outside/state
entries, a traversal listing entry canonicalised then pruned, the hard quota
oldest-first eviction, and the disabled pool reset.

Expiry is not a deletion trigger by design: the original UI expires only the
popup and retains the notification (and therefore its image reference), so its
file is still referenced. Files are pruned when the record is actually removed.

### 3. Writer visibility

Defect: the writer showed a `PanelWindow` at the notification image size and an
`Image.Error` left it active.

Fix: the writer now creates no surface at all. The source is already validated
and confined, and the notification card crops at display time, so the writer
makes one synchronous byte copy of the source into the hash-named confined cache
file; there is no window, input region or opacity to leak, and nothing is left
active on success or failure. Failures (copy error, rejected destination,
missing cache directory) are recorded in service state
(`imageCacheErrors`, `lastImageCacheError`, the record's `imageCacheError`) and
release the writer slot. The cache directory is created by a `.keep` marker
write through `FileView`, which creates missing parents; `CUtils.copyFile` does
not.

Why not a hidden surface: a native writer probe (ad-hoc, not committed) drove
the real service and writer on the shared build with a 1984x868 local image. A
`PanelWindow` writer saved a fully transparent 63x63 PNG for zero-opacity
content, for a 1x1 window, for a clipped token-size window and for an off-screen
window (`grabToImage` renders through the window pass); only the copy produced
the real image. Keeping a visible rasteriser window would have hidden nothing,
so the surface was removed instead. With a synchronous copy there is no
asynchronous write to time out; the bounded timeout only applied to the removed
window writer.

### 4. Startup history race

Defect: `restoreHistory()` destroyed every existing record before restoring, so
a notification delivered before the asynchronous `FileView` load was lost.

Fix: restoration merges. Live (backend-backed) records are kept and win every
`recordId`/`notificationId` collision; previously restored historical records
are dropped, fresh entries are appended, the merged list is sorted by time and
persisted through the existing `historyChanged` save. Corrupt, non-list and
missing history keep live records and drop only stale historical ones.

Coverage: fixture assertions that a live record received before the load
survives, that live wins an id collision while a colliding record id is dropped,
that non-colliding history merges, that the merged set is what serializes, and
that the other service instance is untouched.

### 5. Forwarded-send false confirmation

Defect: any live record with the returned id confirmed a send, so an id that
already existed (another owner forwarding the same id, or a reused id) produced
a false "delivered" state.

Fix: the service tracks a monotonic arrival sequence. `expectDelivery(id,
summary, body)` records the current sequence and the expected content; a send is
confirmed only by a live record with that id received after the send and, when
the caller supplied them, matching summary and body. Anything else resolves to
`deliveryConfirmation: "forwarded"`, `deliveryUnconfirmed: true` and a reason
that says the send was forwarded or not delivered. An unrelated fresh delivery
no longer clears the state. The facade passes the posted summary/body.

Coverage: fixture assertions that a pre-existing id never confirms, that an
unrelated fresh delivery leaves the state forwarded, that a fresh matching
delivery confirms, and that a fresh id with different content ends unconfirmed.
Native: all three local smoke runs now report
`deliveryConfirmation: "confirmed"` (including the restart run, whose restored
record shares the backend's restarted id `1`); disabled runs report `idle`.

### Results

```powershell
$qtPrefix = "$env:LOCALAPPDATA\caelestia-dev\Qt\6.11.2\msvc2022_64"
$buildRoot = 'D:\AiStack\caelestia-windows\windows\.local\build'
powershell -NoProfile -File windows/scripts/Test-NotificationService.ps1 -QtPrefix $qtPrefix -BuildRoot $buildRoot
powershell -NoProfile -File windows/scripts/Test-NotificationsPrototype.ps1 -QtPrefix $qtPrefix -BuildRoot $buildRoot
```

- Fixture: `passed: true`, exit `0`, not timed out, **244 assertions** (was
  136; 108 added), no diagnostics, all ten static checks `true`. Runner
  `qml.exe` sha256 `24994D43...3FA20`, Qt `6.11.2`.
- Prototype: `passed: true`, nine runs, revision `774bb319` with
  `sourceDirty: true`:
  - fixture (244 assertions), disabled screens 0/1, local persist, local
    expire/dismiss, local extra screen 1, M1 regression, media regression
    (148 assertions), battery regression (128 assertions);
  - disabled runs `status: disabled`, `deliveryConfirmation: idle`, no backend,
    no original UI, no records;
  - local runs `status: local`, `deliveryConfirmation: confirmed`,
    `mirroringOff: true`, `systemMirrorActive: false`,
    `systemNotificationAccess: 0`, `protectedDismissals: 0`,
    `rejectedImageSources: 0`, `imageCacheErrors/Dropped/Evicted/Pruned: 0`,
    `activeImageWriters/queuedImageWriters: 0` (no image is posted, so the pool
    stays idle);
  - desktop identity, legacy `%USERPROFILE%\.local\state\caelestia\notifs.json`
    identity and the isolated history path were unchanged.
  - Output: `windows\.local\build\notifications-validation-20261025-184344-963`.
- Prompted fixture changes: the old assertions that a `file:///fixtures/...`
  source was preserved and requested a cache copy now assert the same source is
  rejected; the dismiss-counter assertions are relative to the image tests'
  baseline. All other original assertions still pass.

Clean re-run: both harnesses were then run again on the committed tree at
`26c49656e6fe024941bdae8b057ad9934095ed0b` (the commit that contains the fixes
above). Both report `sourceRevision: 26c49656` and `sourceDirty: false`:

- fixture `passed: true`, 244 assertions, no diagnostics
  (`notification-tests/notifications-fixture-20261025-184514-931`);
- prototype `passed: true`, nine runs, output
  `windows\.local\build\notifications-validation-20261025-184521-303`; the
  local runs again report `deliveryConfirmation: "confirmed"` and the disabled
  runs `idle`, with every policy assertion above unchanged.

The code was not modified after that run; only documentation (this note and the
prototype README) follows it.

### Untested in this round

- The committed smoke posts no image, so `NotifImageCache` and the
  `FolderListModel` listing path are not exercised by either harness. The
  fixture covers the pool/retention/pruning decisions with injected
  lister/remover fakes; the writer itself was only exercised by the ad-hoc
  probe described above, which also confirmed the `.keep` directory creation and
  the copied file (1984x868, non-blank, id-free hash name).
- Eviction order across process restarts relies on file mtimes from
  `FolderListModel`; the fixture covers ordering with injected `savedAt` values.
- Cache files are byte copies of the source image, so the quota bounds the file
  count (64), not total bytes; the notification card crops at display time, so
  no visual size is lost.
- No system consent, denied listener access, real Windows notification removal
  or app-open path is exercised; those remain ERM-503.

## Second review addendum

A second independent review found eight defects, nearly all in the notification
image cache that copied notification-supplied files into the profile cache. The
orchestrator decision was to **remove the cache entirely** instead of hardening
it. All eight findings are addressed by deletion; the cache no longer exists in
this slice.

### Findings

1. Percent-encoding bypassed source validation and deletion (`%2e%2e`, `%5c`).
2. A junction/reparse component could escape the lexical cache boundary.
3. The synchronous byte copy had no size bound and ran on the UI thread.
4. Pruning raced history restoration and the `FolderListModel` listing.
5. A failed deletion broke the 64-file quota accounting.
6. A failed writer could strand its pool slot.
7. A failed repeat copy could delete a valid shared cache file.
8. Replacement sends (`-r`/`--replace-id`) were never confirmed and ended as
   unconfirmed instead of being refused.

The review also found that the whole state directory (including `notifs.json`)
was accepted as an image location.

### Decision: delete the cache

The cache existed only to make a copy of an image the original card could load
directly. It added file validation, copying, listing, pruning, quota and
deletion to a slice whose job is local delivery, and every second-review defect
lived in that surface. It is removed:

- `windows/services/notifications/NotifImageCache.qml` is deleted (and its
  staging entry removed from `windows/notifications-prototype/sources.json`).
- The writer pool/queue, source-keyed hash names, prune/quota registry,
  listing/removal injection and all copy/delete helpers are removed from
  `NotificationsService.qml`.
- `Notifs.qml` no longer imports `Qt.labs.folderlistmodel` or uses
  `CUtils.copyFile`/`CUtils.deleteFile`, and no longer injects a cache
  directory. The prototype no longer instantiates writer delegates.
- `NotifData.qml` no longer has cache-pending/dropped/error properties.
- The `cacheDirectory` path injection and the image-cache directory property are
  removed. Path confinement now covers only the history (`state/notifs.json`).
- The harness no longer creates, asserts or cleans an image-cache directory.

No notification image file is ever copied, written, listed, pruned or deleted
by this slice. Static checks in `Test-NotificationService.ps1` now fail on any
`imageCache`/`copyFile`/`deleteFile`/`FolderListModel`/`CUtils` reference in the
service, record or facade, and on the writer component reappearing.

### New image source policy

`NotificationsService.validateImageSource()` is still the single, pure,
Quickshell-free decision (no filesystem access), applied to live notifications,
image changes and restored history. It accepts exactly:

- `image://` provider URLs (theme icons); the final review addendum narrows this
  to `image://icon/<bare-theme-name>`;
- local files that are strict, case-insensitive children of the injected staged
  shell assets directory.

Rejected classes: any source containing `%`; UNC (`\\server`), `\\?\`, `\\.\`,
`//` and `file://host`; alternate data streams (`:` beyond the drive letter);
relative and drive-relative paths; any `.` or `..` component; components ending
in `.` or a space; `~` in any component (8.3 short-name alias); the profile
cache, data and state directories (including the old `cache/notifs` location);
and anything outside the staged assets directory.

The URL handed to the original card is rebuilt from the validated local path as
`file:///` plus forward slashes, never from the raw input; the final review
addendum percent-encodes each segment. A rejected or unsupported source becomes
`""`, so the original card shows its existing fallback icon. Persisted history
images go through the same validator on restore; the final review addendum also
re-validates restored app icons and sanitizes restored bodies. App-supplied images outside the staged assets directory therefore show
the fallback icon **by design**; that is the deliberate trade for removing the
copy/validation/deletion surface.

### Replacement sends

`NotificationsService.replacementIdFromArgs()` mirrors the pinned backend's
`-r`/`--replace-id` syntax, and `replacementSendRefusal()` returns a clear
"Replacement notifications are not supported by this slice; the local send was
refused." The facade refuses before `notifySend` and before `expectDelivery`, so
a replacement send cannot become a pending or unconfirmed delivery. The native
smoke posts such a send first and fails the run if it is not refused.

### Kept from the previous fixes

History restoration still merges (live records win id collisions), fresh
delivery confirmation still requires a matching arrival after the send,
system notification mirroring stays off with no access request, and the history
path remains confined to the isolated profile state directory.

### Results

Recorded on the clean tree at
`f14d77ce8dea30c70724acd40b58057d4bcb8410` (commit
`windows: remove the notification image cache`). Both runs report
`sourceDirty: false` and `sourceRevision: f14d77ce`.

```powershell
$qtPrefix = "$env:LOCALAPPDATA\caelestia-dev\Qt\6.11.2\msvc2022_64"
$buildRoot = 'D:\AiStack\caelestia-windows\windows\.local\build'
powershell -NoProfile -File windows/scripts/Test-NotificationService.ps1 -QtPrefix $qtPrefix -BuildRoot $buildRoot
powershell -NoProfile -File windows/scripts/Test-NotificationsPrototype.ps1 -QtPrefix $qtPrefix -BuildRoot $buildRoot
```

- Fixture: `passed: true`, exit `0`, not timed out, **218 assertions** (was 244;
  the cache pool/prune/quota assertions were removed and the policy,
  replacement-refusal, restore-revalidation and original non-cache assertions
  remain), no diagnostics, no hash mismatch. All twelve static checks are `true`:
  no Quickshell/native import, no HOME/XDG/`Paths` fallback,
  `NotificationServer` never constructed in the service or record, mirroring
  false at construction, no notification access request, and no image-cache code
  or writer component.
- Prototype runs: Disabled screens 0/1 report `status: disabled`,
  `deliveryConfirmation: idle`, no backend, no original UI and no records. Local
  screens 0/1 report `status: local`, `deliveryConfirmation: confirmed`,
  `mirroringOff: true`, `systemMirrorActive: false`,
  `systemNotificationAccess: 0`, `protectedDismissals: 0`,
  `rejectedImageSources: 0`; the replacement send was refused in each local run
  before the real send. Disabled/`unknown` ownership and every other previous
  policy assertion are unchanged.
- Prototype: `passed: true`, nine runs (fixture, disabled screens 0/1, local
  persist, local expire/dismiss, local extra screen 1, M1 regression, media
  regression, battery regression). Output:
  `windows\.local\build\notifications-validation-20261025-191533-249`.
  Desktop identity, the legacy `%USERPROFILE%\.local\state\caelestia\notifs.json`
  identity (absent before and after) and the isolated history path were
  unchanged. No image is posted by the smoke, so no image file is touched.

Evidence is archived under `second-review/`:

- `second-review/matrix.json` and the per-run `stdout.log`, `stderr.log`,
  `result.json`, `sources.json` and `capture.png` (screenshots for disabled,
  local and M1 runs);
- `second-review/fixture-standalone/` with the fixture `result.json`, both logs
  and the three exact staged QML sources;
- `second-review/desktop-before.json` / `desktop-after.json`;
- `second-review/archive-second-review.ps1` is the archive script used.
- `artifacts.sha256.json` was regenerated to cover the whole validation folder,
  including the new evidence.

Changed sources at the recorded revision:

| source | sha256 |
| --- | --- |
| `windows/services/notifications/NotificationsService.qml` | `03EBA603919002B0EC53357DA7D37C06A7517D08B0E969516C4D36C0C6E67048` |
| `windows/services/notifications/NotifData.qml` | `1C7FCED5555587E1B5BA869768323C43E3076FE2F1BF6EC47B8975B5EC6D6943` |
| `windows/services/notifications/Notifs.qml` | `55EFD4C903A88149072127180AD4B5AB436650F8877D282AA885E8AEAB0726EB` |
| `windows/services/notifications/NotificationsServiceTest.qml` | `4C95C672E42A859EFC580E5C0F0F7EC74AF0822825F92D5C8C45EBAACCB788CA` |
| `windows/notifications-prototype/shell.qml` | `48C0FD5B06C6E580CA5DB448ED9E95EBAFEF62350EC16B980060CA860496AD93` |
| `windows/notifications-prototype/sources.json` | `390F672B2A55526046DCFAE7BDE9027919293D87DAFB8EBCA80357F4F69F7EC9` |
| `windows/scripts/Test-NotificationService.ps1` | `A46FABEA9587CA23C51BC347BC17D21DADBD3AE11DC00E17EF65410748B8D9EB` |
| `windows/scripts/Test-NotificationsPrototype.ps1` | `CEE37E45A1CE63DD67D024A3A420619401931F91CEFBFBE4E1DC97A32C5FA119` |

`windows/services/notifications/NotifImageCache.qml` no longer exists; the hash
in the original sources table above documents the removed revision. The
original "Image cache" and writer limits in the earlier sections describe the
superseded slice and are retained as history.

### Untested in this round

- No smoke posts an image, so a provider or staged-asset image has not been
  rendered by the original card; the policy, built URL, fallback and rejection
  paths are fixture-covered.
- The staged assets directory is injected from the real stage path, but no file
  from it is loaded by the UI. The validator is lexical and does **not** detect
  reparse points; the staged assets root comes from trusted staging
  (`Quickshell.shellPath("assets")`), not notification input, so physical
  containment relies on the staging step. No reparse point was exercised.
- App-supplied images outside the staged assets directory now fall back by
  design; there is no compatibility path.
- No system consent, denied listener access, real Windows notification removal
  or app-open path is exercised; those remain ERM-503.

## Final review addendum

A third independent review found three blocking bypasses and two minor defects
in the second-review slice. All five are fixed here. The fixes are in
`8cbf416b` (`windows: fix final notification review findings`); `17a37c26`
(`windows: correct the notification image policy documentation`) only corrects a
comment and documentation, so the behaviour is identical. This addendum
supersedes two earlier statements: that any `image://` provider URL is accepted,
and that junction/reparse behaviour is rejected lexically.

Changed files: `windows/services/notifications/NotificationsService.qml`,
`NotifData.qml`, `Notifs.qml` (comment), `NotificationsServiceTest.qml` and
`windows/notifications-prototype/README.md`.

### 1. BLOCKING: image://icon provider confinement

Defect: `validateImageSource()` accepted any `image://` URL whose provider part
was non-empty and free of `..`. `image://icon/C:/outside/picture.png` reached
`QIcon::fromTheme`, which loads an absolute path, and
`image://icon/foo?fallback=C:/outside.png` loaded the fallback name; both escaped
the staged-asset confinement. App icons had the same problem through
`Quickshell.iconPath()`, which builds `image://icon/<appIcon>`.

Fix: only `image://icon/<name>` is accepted, where `<name>` matches
`^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$`. The name cannot contain a slash,
backslash, colon, `?`, `#`, `%`, whitespace or authority, and the canonical URL
is rebuilt as `image://icon/` plus the validated name. Every other provider is
rejected. `validateAppIcon()` applies the same theme-name rule plus the staged
asset rule (returned as the validated local path because `iconPath()` builds the
provider URL itself); anything else becomes `""` so the original fallback icon
renders. Restored history re-validates the app icon.

Coverage: fixture cases for an absolute path, a lower-case drive, `?fallback=`,
`?path=`, a fragment, a subpath, an empty segment, an empty name, a provider
without a name, other providers, user-info and port authorities, whitespace, a
backslash, an upper-case scheme, percent-encoded traversal and `..`/`.` names,
128/129-character names, and app icons (theme, empty, staged path, staged file
URL, external/prefix-sibling/dot-dot/UNC/relative/qrc/percent forms, provider
forms, whitespace, leading dot). Restored provider-path image and app icon are
rejected; a restored theme app icon survives.

### 2. BLOCKING: body images

Defect: bodies render as Markdown in the original popup and sidebar, so
`![x](file:///C:/outside.png)`, reference-style images and raw HTML `<img>` could
load arbitrary local or remote images.

Fix: `NotificationsService.sanitizeBody()` is applied by `NotifData` to the
initial live body, every `bodyChanged` update and restored history. It:

- replaces inline `![alt](destination "title")` and `![alt](<destination>)` with
  `alt`, using escape-aware bracket/paren matching, nested alt brackets,
  parentheses in the destination and nested images;
- replaces `![alt][reference]` and `![alt]` with `alt`;
- removes reference definition lines `[ref]: url ...`;
- removes `<img>`, `<picture>`, `<source>`, `<svg>`, `<image>`, `<object>`,
  `<embed>` and `<iframe>` tags, case-insensitively, across lines and with a
  quoted `>` in an attribute. An unterminated media tag drops the rest of the
  body because a tolerant HTML parser could still load it.

Ordinary text, Markdown links and ordinary HTML links are kept.
`expectDelivery()` compares the sanitized body, so a body image cannot make a
genuine delivery look unconfirmed. This is a lexical filter, not a full Markdown
parser: fenced code blocks and multi-line reference titles are not modelled.

Coverage: fixture cases for inline file/http images, nested alt brackets and
destination parentheses, escaped brackets, angle-bracket destinations,
parentheses inside them, nested images, shortcut and reference images, reference
definition lines, HTML `img` (case, multi-line, quoted `>`), picture/source/
svg/image/object/embed/iframe, unterminated tags, escaped image markers,
comparison text and ordinary links; a live body and a live body update; restored
history bodies; and a body-image delivery confirmation.

### 3. BLOCKING: replacement IDs

Defect: `replacementIdFromArgs()` scanned every argument independently, so
`["-r", "+42"]` and `["--replace-id=+42"]` were not refused although
`QString::toUInt` accepts a leading `+`. It also mis-parsed
`["-a", "-r", "42"]` as a replacement although the backend consumes `-r` as the
app name.

Fix: the parser mirrors `notify_send.cpp` option consumption: the same short and
long table, case-sensitive names, only `u/t/a/i/c/h/A/r` take a following
argument, an unknown option consumes nothing, and the last valid `-r` wins while
an invalid later value keeps the earlier one. `backendReplaceId()` mirrors
`QString::toUInt` base 10 as measured against Qt 6.11.2: optional ASCII
whitespace, optional `+`, decimal digits, optional ASCII whitespace and a value
`<= UINT_MAX` (4294967295). Unicode whitespace, `-1`, fractional values,
`+ 42`, `0x2a` and overflow are not parsed. A parsed value `> 0` is refused
before `notifySend` and `expectDelivery`.

Coverage: existing cases plus `+42`, `--replace-id=+42`, `007`, surrounding
whitespace, tab/plus/leading zeros, `UINT_MAX`, `UINT_MAX + 1`, non-breaking
space, `+ 42`, last-valid-wins, invalid-later-keeps-earlier,
`-a/-i/-t/--app-name/--replace-id` consuming `-r`, `-e/--transient` not
consuming, an unknown option, case-sensitive long and short names, a missing
value, and refusal/no-refusal of the corresponding sends.

### 4. MINOR: rebuilt file URLs

Defect: `imageUrlForPath()` concatenated the validated path, so
`assets/banner#v2.png` became a URL fragment.

Fix: each validated path segment is percent-encoded with `encodeURIComponent`;
lone surrogates are rejected during canonicalisation and an encoding failure
rejects the source. `banner#v2.png` becomes `banner%23v2.png`,
`banner?v=2.png` becomes `banner%3Fv%3D2.png`, and a space becomes `%20`.

Coverage: fixture cases for `#`, `?` and a space in a staged file name, plus a
live record.

### 5. MINOR: README junction claim

The second-review text said junction/reparse behaviour was rejected lexically.
That was wrong: the validator is lexical and does not detect reparse points. The
staged assets root comes from `Quickshell.shellPath("assets")`, which is trusted
staging rather than notification input, and physical containment relies on that
staging. The stale bullet was corrected in place, as was the claim that any
`image://` provider URL is accepted.

### Results

Recorded on the clean tree at
`17a37c261a74d43f13f3c4eb0a9a8ad4e5befe95` (behaviour identical to `8cbf416b`).
Both harnesses report `sourceRevision: 17a37c26` and `sourceDirty: false`.

```powershell
$qtPrefix = "$env:LOCALAPPDATA\caelestia-dev\Qt\6.11.2\msvc2022_64"
$buildRoot = 'D:\AiStack\caelestia-windows\windows\.local\build'
powershell -NoProfile -File windows/scripts/Test-NotificationService.ps1 `
    -QtPrefix $qtPrefix -BuildRoot $buildRoot
powershell -NoProfile -File windows/scripts/Test-NotificationsPrototype.ps1 `
    -QtPrefix $qtPrefix -BuildRoot $buildRoot
```

- Fixture: `passed: true`, exit `0`, not timed out, **324 assertions** (was 218;
  106 added), no diagnostics, all twelve static checks `true`. Stage
  `windows\.local\build\notification-tests\notifications-fixture-20261025-193051-195`.
- Prototype: `passed: true`, nine runs, output
  `windows\.local\build\notifications-validation-20261025-193053-982`:
  fixture (324 assertions), disabled screens 0/1, local persist, local
  expire/dismiss, local extra screen 1, M1 regression, media regression (148
  assertions) and battery regression (128 assertions). Disabled runs report
  `status: disabled`, `deliveryConfirmation: idle`, no backend, no original UI
  and no records; local runs report `status: local`,
  `deliveryConfirmation: confirmed`, `rejectedImageSources: 0`,
  `mirroringOff: true`, `systemMirrorActive: false`,
  `systemNotificationAccess: 0` and `protectedDismissals: 0`. Desktop identity,
  the legacy `%USERPROFILE%\.local\state\caelestia\notifs.json` identity (absent
  before and after) and the isolated history path were unchanged.
- Prior assertions: all 218 are unchanged and passing. The 106 additions are new
  cases; no prior assertion needed a change.

Changed sources at the recorded revision:

| source | sha256 |
| --- | --- |
| `windows/services/notifications/NotificationsService.qml` | `ADD9DAA92FFD57448F4272D4F140F06160EB7CACF23E1E32393B5F38332F7488` |
| `windows/services/notifications/NotifData.qml` | `735C9C5978C973DF0DA62C80A24177F1728CC15509721021D40FB2C30E7B963A` |
| `windows/services/notifications/Notifs.qml` | `1ED746ED13B4BF0B9FB9B8C1668D8321FB00ECED323E23426621D1FD32BA4B0D` |
| `windows/services/notifications/NotificationsServiceTest.qml` | `4A176CB722A615701B48D752339905E7391C707621DC78FB2E5A4A14CCC8A583` |
| `windows/notifications-prototype/README.md` | `0040B94CD19C46598A9E3A1883421109614A3479FD191919F8B51A6440698533` |

### Untested in this round

- No smoke posts an image or an app icon, so the original card has not rendered
  an accepted provider/staged image or a staged app icon; the allowlist, built
  URLs, fallback and rejection paths are fixture-covered.
- The body filter is lexical, not a full Markdown parser: fenced code blocks,
  multi-line reference titles and HTML entities are not modelled. No real
  notification body containing an image was rendered by the original card.
- No reparse point (junction/symlink) was exercised. The staged assets root is
  trusted staging, not notification input; the validator is lexical and does not
  detect reparse points.
- No system consent, denied listener access, real Windows notification removal
  or app-open path is exercised; those remain ERM-503.


