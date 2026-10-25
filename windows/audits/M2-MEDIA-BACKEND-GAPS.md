# M2 media backend status at pin `2dff3ef2` (ERM-498)

Task-owned audit of `Quickshell.Services.Mpris` in the pinned backend, recorded
2026-10-25 on the media integration branch. Source paths are relative to
`windows/deps/quickshell/`. This is a source audit, not a runtime claim: ERM-498
acceptance still requires the parent's native observation on a desktop with real
media sessions. This branch modified no backend source, gitlink, or
`sources.lock.json`.

This document supersedes the earlier draft audit at backend `8c71bdb8`. That
revision did not expose lifecycle state. Pin `2dff3ef2` (backend PR #3, stacked
on PR #2) adds the status boundary below, so the draft's "no initialization or
failure state" gap is no longer true. The per-command gap remains.

## Lifecycle API observed at `2dff3ef2`

`Mpris` ([`mpris.hpp`](../deps/quickshell/src/windows/services/mpris/mpris.hpp),
lines 21-23, 33-35) now exposes:

- `ready` (bool, `NOTIFY statusChanged`)
- `lastError` (QString, `NOTIFY statusChanged`)

Both are backed by `MprisBackendStatus`
([`backend_status.hpp`](../deps/quickshell/src/windows/services/mpris/backend_status.hpp),
lines 10-35), which starts `mReady=false` and `mLastError=""`. `setResult(error)`
sets `ready = error.isEmpty()`, stores both values, and emits one `changed`
signal after both are current. `Mpris::statusChanged` is forwarded from that
signal.

Construction is still eager for the native singleton: `Mpris` creates
`GsmtcBackend` in its constructor (`mpris.cpp`, lines 19-22), and the backend
starts its worker thread through `startup::afterFirstFrame`
([`gsmtc_backend.cpp`](../deps/quickshell/src/windows/services/mpris/gsmtc_backend.cpp),
lines 23-31). Before the worker reports, the honest state is `ready=false` with
an empty `lastError`: the adapter treats it as loading, not as a healthy empty
scan.

### Success

After `GetSessions` succeeds, `resyncSessions()` removes departed sessions, adds
new ones, and publishes an empty error
([`gsmtc_worker.cpp`](../deps/quickshell/src/windows/services/mpris/gsmtc_worker.cpp),
lines 180-215, especially line 210). The result is `ready=true` and
`lastError=""` **regardless of session count**. A desktop with no open media
sessions is therefore a healthy empty scan, not an error.

### Failure

Every failure path publishes `ready=false` with a non-empty operation string
(plus the HRESULT where one is available) built by `statusError()` (lines
47-53):

- `winrt::init_apartment` failure: lines 111-120, `"init_apartment failed (HRESULT 0x...)"`
- `RequestAsync` failure: lines 122-130, `"GSMTC RequestAsync failed (HRESULT 0x...)"`
- a null session manager: lines 131-134, `"GSMTC RequestAsync returned no session manager"`
- `GetSessions` failure: lines 186-192, `"GSMTC GetSessions failed (HRESULT 0x...)"`
- later session synchronization failure: lines 211-215,
  `"GSMTC session synchronization failed (HRESULT 0x...)"`

A failed scan does **not** clear `Mpris.players`. The failure return paths leave
previously published `MprisPlayer` objects in the model (the `GetSessions`
failure returns before removals at lines 194-205). A consumer must gate its
player list and every control on `ready`; object presence alone proves neither
session health nor controllability. A later successful scan flips `ready` back
to true and clears `lastError`; removed sessions are then reconciled normally.

Command failures do not touch lifecycle status. `ready` describes the last
successful session enumeration, not transport health.

## Player contract and unsupported actions

`MprisPlayer`
([`player.hpp`](../deps/quickshell/src/windows/services/mpris/player.hpp),
lines 49-168) preserves `canControl`, `canPlay`, `canPause`,
`canTogglePlaying`, `canSeek`, `canGoNext`, `canGoPrevious`, `identity`,
`desktopEntry`, `dbusName`, `position`/`positionSupported`, `length`/
`lengthSupported`, `metadata`, `uniqueId`, `trackTitle`, `trackArtist`/
`trackArtists`, `trackAlbum`, `trackAlbumArtist`, `trackArtUrl`, playback state
and `isPlaying`, loop state/`loopSupported`, rate, shuffle/`shuffleSupported`,
`fullscreen`, and URI/mime lists.

The unsupported constants remain truthful:

- `canQuit`, `canRaise`, `canSetFullscreen` return false (lines 121-123).
- `volume` is a constant 1.0 no-op with `volumeSupported == false` (lines
  136-138).
- `stop()` routes to a `Stopped` playback state that logs "GSMTC has no stop
  command" and returns without dispatching
  ([`player.cpp`](../deps/quickshell/src/windows/services/mpris/player.cpp),
  lines 84, 158-161).
- `raise()`, `quit()` and `openUri()` log that GSMTC has no equivalent and
  ignore the request (`player.cpp`, lines 43-48).

Command guards reject unsupported or capability-less calls before dispatch
(`player.cpp`, lines 50-94, 116-205); each write guards before reaching the
worker. The adapter exposes matching false `stopSupported`/`raiseSupported`/
`quitSupported`/`openUriSupported`/`volumeSupported` flags and `canStop`/
`canRaise`/`canQuit`/`canOpenUri`/`canSetVolume` gates returning false, so these
actions cannot be presented as available or successful.

Two additional details affect adaptation rather than capability:

- `metadata` is rebuilt as `xesam:title`, `xesam:artist`, `xesam:album`,
  `xesam:albumArtist` and `mpris:artUrl` (`player.cpp`, lines 256-262). It does
  **not** carry `xesam:url`, so the upstream YouTube URL art fallback cannot fire
  on this backend; `trackArtUrl` (the cached native thumbnail) is the working
  source.
- `dbusName` embeds a per-process monotonic session id
  (`gsmtc_worker.cpp`, line 247), so it is not stable across restarts and must
  not be persisted as a player selection.
- Artwork thumbnails are decoded and written as PNGs under
  `QStandardPaths::CacheLocation/mpris-art`, pruned to 50 files
  ([`art_cache.cpp`](../deps/quickshell/src/windows/services/mpris/art_cache.cpp),
  lines 26-40, 43-77). The prototype's `CacheDir` pragma keeps this under the
  isolated profile cache; observing sessions may therefore write native
  thumbnails even though this slice adds no artwork UI or capture code.

## Remaining gap: no per-command result

`TryPlayAsync`, `TryPauseAsync`, `TryTogglePlayPauseAsync`,
`TrySkipNextAsync`, `TrySkipPreviousAsync`,
`TryChangePlaybackPositionAsync`, `TryChangeShuffleActiveAsync` and
`TryChangeAutoRepeatModeAsync` failures are logged on the worker only
(`gsmtc_worker.cpp`, lines 521-610). `Mpris` exposes no signal or property for a
command outcome, and no poll or retry is added. The media adapter therefore gates
a request by opt-in and native capability, but never claims a request succeeded
or was applied. Playback state, position and metadata remain the only observable
evidence.

A per-command result (for example a `commandFinished(sessionId, command,
hresult)` signal) would be a separate backend and pin change. This slice does
not request it and works without it.

## What the adapter relies on

- `ready=true` means the last session enumeration succeeded. `ready=false` with
  an empty `lastError` is loading; `ready=false` with a non-empty `lastError` is
  unavailable and the operation/HRESULT is safe to display.
- The list is the native model order, filtered to objects, and only when
  `ready=true`. Stale snapshots are never selectable or controllable.
- Selection order remains upstream's: valid manual object, configured default
  identity/alias, first observed player, otherwise null.
- Capability gates combine the separate control opt-in, list membership and the
  native per-player `canControl`/`canX` flags. `positionSupported` additionally
  gates seeking.
- `metadata`, `trackArtUrl`, `position`, `length`, `isPlaying` and capability
  flags pass through unchanged from the native object; the adapter invents no
  timeline or session state.

## Residual limits

- This is a source audit plus injected fixtures. Real GSMTC initialization,
  session enumeration, removal, denial and recovery need the parent's native
  observation on a desktop with real media sessions.
- A local scan failure's HRESULT text is shown, but Windows may use different
  codes for denied access versus a transient failure; this slice does not map
  codes to policy.
- Transport requests cannot confirm success (gap above). No playback, capture,
  global shortcut, toast, lyrics or network behavior is implemented or
  validated here.
