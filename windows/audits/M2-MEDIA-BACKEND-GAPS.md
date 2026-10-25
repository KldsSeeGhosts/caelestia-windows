# M2 media backend gaps at pin `8c71bdb8` (ERM-498)

Task-owned audit of `Quickshell.Services.Mpris` in the pinned backend, recorded
2026-10-25 on branch `t3/windows-gsmtc-media-scope-rollup`. Source paths are
relative to `windows/deps/quickshell/`. This is a source audit, not a runtime
claim: ERM-498 acceptance still requires the parent's native observation on a
desktop with real media sessions. The backend submodule and pins were not
modified by this branch.

## Exact QML API observed

`Mpris` singleton (`src/windows/services/mpris/mpris.hpp:18-50`): a `players`
object model (`NOTIFY valuesChanged` confirmed in `src/core/model.hpp:45`).
Constructing the singleton eagerly creates `GsmtcBackend` (`mpris.cpp:19-21`),
whose worker thread starts after the first frame (`gsmtc_backend.cpp:30`) and
performs WinRT `init_apartment(multi_threaded)` plus
`GlobalSystemMediaTransportControlsSessionManager::RequestAsync`
(`gsmtc_worker.cpp:93-110`).

`MprisPlayer` (`player.hpp:49-276`): `canControl`, `canPlay`, `canPause`,
`canTogglePlaying`, `canSeek`, `canGoNext`, `canGoPrevious`; `identity`,
`desktopEntry`, `dbusName`; `position` (read/write), `positionSupported`,
`length`, `lengthSupported`; `metadata` map, `uniqueId`, `trackTitle`,
`trackArtist`/`trackArtists`, `trackAlbum`, `trackAlbumArtist`,
`trackArtUrl`; `playbackState` and `isPlaying` (read/write), `loopState`
(read/write) + `loopSupported`, `rate` (read-only, min/max fixed 1.0),
`shuffle` (read/write) + `shuffleSupported`; invokables `raise`, `quit`,
`openUri`, `next`, `previous`, `seek`, `play`, `pause`, `stop`,
`togglePlaying`. Per-player unsupported constants are already truthful:
`canQuit`/`canRaise`/`canSetFullscreen` return false (`player.hpp:121-123`),
`volume` is a constant 1.0 no-op with `volumeSupported == false`
(`player.hpp:136-138`), and `stop` logs that GSMTC has no stop command and
changes nothing (`player.cpp:158-161`). `raise`/`quit`/`openUri` log and ignore
(`player.cpp:43-48`). Command guards reject unsupported/capability-less calls
with warnings (`player.cpp:50-94, 116-131, 138-205`); every write guards before
dispatching to the worker.

Other observed behavior worth recording:

- Media property reads that fail are retried up to 8 times at 400 ms
  (`gsmtc_worker.cpp:30-31, 395-401`); stale art is retried up to 6 times at
  350 ms (`gsmtc_worker.cpp:32-33, 420-428`). Session identity is a static
  AUMID table with raw-AUMID fallback (`gsmtc_worker.cpp:53-76`); `dbusName`
  embeds a per-process monotonic id (`gsmtc_worker.cpp:213`), so it is not
  stable across restarts and must not be persisted as a selection.
- Artwork thumbnails are decoded and written as PNGs under
  `QStandardPaths::CacheLocation/mpris-art`, pruned to 50 files
  (`art_cache.cpp:26-40, 60-77`). In the prototypes the CacheDir pragma keeps
  this inside the isolated profile cache.

## Gaps that keep native status conservatively unknown

1. **No initialization/failure state.** `init_apartment` or `RequestAsync`
   failure logs a warning and returns (`gsmtc_worker.cpp:93-110`); `Mpris`
   exposes no `ready`, error, or status property. An empty player list is
   therefore indistinguishable from a failed GSMTC request. The
   [Players adapter](../services/media/PlayersService.qml) keeps status
   "ready" only for *observation being active* and its reason text states the
   empty-list caveat; it never reports a healthy "no sessions" conclusion.
2. **No per-command result.** `TryPlayAsync`/`TryPauseAsync`/`Try*` failures
   log on the worker only (`gsmtc_worker.cpp:487-579`); QML cannot observe a
   denied or failed transport command.

## Precise backend patch requested (parent to implement in the fork)

Following the audio precedent (`Pipewire.lastError`,
`PwNodeAudio.controlAvailable/controlError`), in
`src/windows/services/mpris/`:

1. Add to `GsmtcWorker` an initialization outcome recorded in `start()`:
   an enum `{ Succeeded, ApartmentFailed, RequestFailed }` plus the
   `HRESULT` code captured at `gsmtc_worker.cpp:93-110`, queued to the
   frontend on the main thread.
2. Add to `Mpris` (`mpris.hpp/cpp`) bindable `ready` (bool) and
   `lastError` (QString, empty when ready) properties fed by that outcome,
   with a `readyChanged`/`lastErrorChanged` notification path; keep them
   false/empty until the worker reports. Do not change worker retry
   behavior or add polling.
3. Optionally (separate reviewable commit) add a per-command result signal
   `commandFinished(quint64 sessionId, QString command, uint hresult)` to
   `Mpris`, emitted from the `cmd*` methods' catch blocks, so adapters can
   surface denied transport commands without polling playback state.

Until that patch is pinned (fork commit + review + gitlink and
`windows/sources.lock.json` moved together with fresh evidence), the media
adapter must keep treating an empty list as "sessions unknown" and must not
claim denied-control detection.
