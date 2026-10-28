# Dictation status indicator

Status/indicator slice of [issue #56](https://github.com/KldsSeeGhosts/caelestia-windows/issues/56).
Adapted from `overlay/quickshell/services/Dictation.qml` and
`modules/dictation/DictationIndicator.qml` in
[caelestia-hypr-dotfiles at 621dccaf](https://github.com/KldsSeeGhosts/caelestia-hypr-dotfiles/tree/621dccaf035e1a1b9bf2f808c18c2aa0d26e7db6).
This does **not** port the Linux ASR engine/recording dispatcher.

## Behaviour and Windows boundary

The combined and production entries stage `DictationIndicator` through
`sources.d/dictation.json`. All Windows-specific files live under
`windows/combined-prototype/adapters/`. The upstream repository files are
unchanged.

- Disabled unless the shell process has `CAELESTIA_WINDOWS_DICTATION=1`.
  Disabled means no status file reader, polling or indicator window.
- Reads `<CAELESTIA_RUNTIME_DIR>/dictation-state.json`, normally
  `%LOCALAPPDATA%\caelestia-windows\runtime\dictation-state.json`.
  `CAELESTIA_DICTATION_STATE` can explicitly override the file path.
  With neither a runtime directory nor an override, no file is read.
- Preserves the overlay's mic badge, five synthetic animated bars, rose
  colours, dimensions, bottom offset and animation timings. The pill is
  extracted into `DictationPill.qml` without redesign. It is shown only for
  `listening`/`processing`, just as on Linux.
- Targets the named shell screen, falling back to the first current screen.
  The native window has an empty input region, cannot take keyboard focus,
  and reserves no work area. Loader opacity is explicitly bound to the native
  window's content, so the original entrance/exit fade actually reaches it.
- Accepts `idle`, `listening`, `processing`, `done`, `error`. Done/error retain
  the original 1800/2600 ms status lifetime but do not show speech.
  Invalid/missing/unreadable files reset to idle. A one-second reload recovers
  late file creation and atomic replacement even if a file watch is lost.
- Drops transcript/error payloads instead of exposing, caching or logging
  them. IPC `dictation getState` returns only the state name;
  `dictation refresh` requests a file reload.
- Never starts a process, records audio, inserts text, changes the clipboard,
  or invokes Linux commands. Cancellation is unsupported (`canCancel=false`);
  there is deliberately no fake-success cancel IPC.

## Producer contract

A Windows ASR producer must publish UTF-8 JSON atomically:

```json
{
  "state": "listening",
  "screen": "",
  "startedAt": 1793130000.0,
  "updatedAt": 1793130000.0
}
```

Timestamps are Unix seconds, not milliseconds. `updatedAt` is required for
non-idle states. Times more than five seconds in the future, invalid timestamps,
unknown states and expired observations are ignored. `startedAt` is optional;
it is used only for the service's elapsed-time counter. `screen` is the optional
Quickshell screen name, not a display number.

Listening/processing expire after five minutes without a fresh `updatedAt`.
This is a Windows safety addition so a crashed producer cannot leave the mic
indicator active forever. A producer should heartbeat at least every 30 seconds
while active, and publish `idle` in its cleanup/finally path. Re-reading the same
file never renews its age. This is an activity indicator, not authoritative proof
that Windows microphone capture has stopped.

`windows/scripts/Set-DictationState.ps1` is an optional native PowerShell
publisher for that contract. It writes only state, screen and timestamps,
uses an atomic same-directory replacement, and accepts no speech parameters.
For a producer integrating with the installed profile:

```powershell
# These commands only publish status. They do not start/stop ASR.
.\windows\scripts\Set-DictationState.ps1 -State listening
.\windows\scripts\Set-DictationState.ps1 -State processing
.\windows\scripts\Set-DictationState.ps1 -State done
.\windows\scripts\Set-DictationState.ps1 -State idle
```

Pass `-RuntimeRoot <isolated-runtime-directory>` for development. This helper
always writes `dictation-state.json` there; if using the reader's custom path
override, the producer must write that path itself. Use a single producer.
The reader opt-in is process-local; this change adds no shortcut, autostart,
profile migration or installation change.

## Isolated verification

```powershell
powershell -NoProfile -File windows/scripts/Test-Dictation.ps1 `
  -QtPrefix "$env:LOCALAPPDATA\caelestia-dev\Qt\6.11.2\msvc2022_64" `
  -BuildRoot C:\b-qsum
```

Use an existing compatible build, or build a dedicated short-path directory
using `Build-Prototype.ps1`. The test does not rebuild or modify that build.
It stages the production graph into a disposable `%TEMP%` run, forces offscreen
Qt, clears inherited service opt-ins and uses synthetic status data only.
It tests:

- status validation, expiry boundaries, screen fallback, privacy projection;
- disabled mode with a populated status file;
- missing-file startup, creation and atomic replacements through real FileView;
- listening/processing, malformed-data reset, recovery, done/error timers,
  stale active-state expiry, fresh recovery and explicit idle cleanup;
- real indicator Loader lifetime/fade and the real pill geometry/rendering;
- the PowerShell publisher's initial write, replacement, UTF-8 and schema.

The test-only `OffscreenDictationWindow.qml` replaces the native window boundary,
because offscreen Qt has no PanelWindow backend. It still loads the production
indicator, service, animation and pill. The native wrapper is **not** exercised.
`qmlformat` parses that wrapper as a syntax-only gate, not a native runtime test.
Each run retains `result.json`, logs, staged source hashes and a tightly cropped
synthetic pill PNG. No logs or screenshots belong in a commit.

Implementation verification used Qt 6.11.2 and the read-only existing
`C:\b-qsum` runtime (backend `2239ffb6fd743fd281e9d60035054e1bb2d010ed`).
The checkout is based on `origin/dev` `988d4d0b` with backend
`10bddb7bf14d33e64ca94828abade248bcc81d3a`; no pins were changed by this slice.
This QML/PowerShell-only port was not rebuilt or exercised against that newer
native backend. The environment check confirms matching source pins and an
unambiguous staging map, but the ordinary agent PATH lacks CMake/Ninja/compiler.
No native build or complete production-shell regression is claimed.

## Residual scope and review handoff

Issue #56 is not complete:

1. A Windows ASR producer must be selected/ported and wired to the contract.
   Linux's `bin/asr-dictate` dispatches to machine-specific Parakeet/Granite
   scripts. There is no corresponding Windows producer in this repository.
   Microphone capture, recognition, text insertion and cancellation are not
   implemented or tested here. No recording shortcut is registered.
2. Dedicated live QA must verify native panel creation, click-through, no
   focus theft, screen naming, named/removed monitor routing, 150%/175% DPI,
   placement, fade and light/dark appearance. This implementation performs no
   desktop operation, install or restart. Claude retains final visual review.
3. The screenshot picker/annotator still needs Windows capture, selection,
   clipboard/export and annotation integration. The custom picker depends on
   Wayland screencopy, `hyprctl`, `/tmp`, `wl-copy`, `notify-send` and `swappy`;
   it is not safely ported by relabelling those commands.
4. GrokBot avatar/roster still needs a verified Windows data location/schema,
   app observation/focus/launch adapter, assets and original bar/popout wiring.
   The Linux service supervises `omabot-watch.py`, reads Linux application
   persistence and uses `pgrep`/Hyprland/machine-specific launch paths.

Review `DictationLogic.js` and `Dictation.qml` for fail-closed status handling,
then compare `DictationPill.qml` with the cited overlay for visual fidelity.
Check the two shell imports/instances and the staging fragment. Run the
offscreen test before arranging the separate live QA/Claude visual review.
Do not mark the full dictation/ASR acceptance, or issue #56, complete on the
strength of these synthetic tests.
