# Windows media prototype

ERM-498's bounded M2 media slice projects the pinned backend's
`Quickshell.Services.Mpris` GSMTC sessions through a default-off adapter and
loads one **original** Caelestia player component in a separate native window.
No player controls are reimplemented.

## Scope and the original component

This revision has no bar media entry or media popout; the original bar popouts
are audio, battery, network, Bluetooth, active window, lock status, keyboard
layout and tray. The smallest meaningful original player surface is the
dashboard media details component:
[`modules/dashboard/media/Details.qml`](../../modules/dashboard/media/Details.qml).
It owns the original title/artist/album labels, position slider, shuffle, loop,
previous, play/pause and next controls. The host stages it unchanged apart from
one localized control hook (below) and places it in a window of at most 560x460
logical pixels, inset 80 from the chosen screen. Escape closes an interactive
run.

The full dashboard `Media.qml` tab and `dash/Media.qml` card are excluded:
they require M3Shapes, `Caelestia.Services`, `Audio.beatTracker`, cover art
modules, lyrics/network paths or the media-GIF `AnimatedImage`. Excluding them
keeps this slice to observation, metadata, timeline and transport capability,
without additional artwork UI, lyrics, network capture, global shortcuts or
toasts. The native backend may still cache session thumbnails under the isolated
profile cache's `mpris-art` directory, as recorded in the
[backend audit](../audits/M2-MEDIA-BACKEND-GAPS.md).

## Service states

[`PlayersService.qml`](../services/media/PlayersService.qml) imports no native
module and exposes no transport method. The singleton wrapper
[`Players.qml`](../services/media/Players.qml) preserves the useful upstream
`services/Players.qml` surface: `list`, `active`, `manualActive`,
`getIdentity()` and `getArtUrl()`. Selection order is upstream's: a valid
manual selection, the configured `defaultPlayer` identity (including a player
alias), the first observed player, otherwise null. A manual selection only wins
while that exact object is still observed, so a removed or foreign object cannot
stay selected.

Five states distinguish lifecycle from session count:

| state | meaning |
| --- | --- |
| `disabled` | observation opt-in absent; no native backend is resolved |
| `loading` | backend present, no successful scan reported yet |
| `unavailable` | scan/init failed; `lastError` carries operation and HRESULT |
| `no-sessions` | successful scan, no media sessions open (healthy) |
| `observed` | successful scan with one or more sessions |

The backend pin `2dff3ef2` reports `Mpris.ready` and `Mpris.lastError`. Native
player snapshots can remain in the model after a failed scan, so the adapter
hides the entire list and every control whenever `ready` is false; object
presence alone is never health. A successful scan clears stale errors.

Capability gates combine the separate control opt-in, list membership and the
native per-player `canControl`/`canX` flags; seeking also requires
`positionSupported`. Positive native capabilities still pass through to the
original component. `stop`, `raise`, `quit`, `openUri` and player volume have no
GSMTC implementation, so their service flags and gates are always false. The
adapter exposes no stop/raise/quit/openUri/volume method.

Transport requests have **no observable per-command result**. Native failures
are logged by the backend worker only. A control being enabled means a request
may be sent with the native capability guard; it never means the request
succeeded or was applied. Playback state, position and metadata remain the only
evidence.

The original `Details.qml` gained one Windows-localized property,
`controlsEnabled`, defaulting to upstream `true`. The host wires it to
`Players.controlsEnabled && Players.ready`, and the component additionally
checks it before the slider interaction writes a position. Every transport
button keeps its existing native capability check, so read-only mode cannot send
a request even if a stale capability snapshot says it could. No second
availability property was added: the adapter's `list`/`active` already become
empty/null whenever the backend is not ready, so the original component's own
empty state is used instead of an invented unavailable visual.

## Opt-ins and launch

Both opt-ins are child-process environment variables; the launcher sets them
explicitly so inherited flags cannot enable media in the M1 profile.

- `CAELESTIA_WINDOWS_MEDIA=1` observes sessions (starts the GSMTC worker after
  the first frame).
- `CAELESTIA_WINDOWS_MEDIA_CONTROLS=1` additionally permits explicit transport
  and seek requests. It is only set for a non-smoke `Interactive` run.

```powershell
$qtPrefix = "$env:LOCALAPPDATA\caelestia-dev\Qt\6.11.2\msvc2022_64"
powershell -NoProfile -File windows/scripts/Start-ShellPrototype.ps1 `
    -QtPrefix $qtPrefix -Media -MediaMode ReadOnly -Wait
```

`-Media` selects this entry point. `Disabled` is the default and never loads
`NativeMediaBackend.qml`. `ReadOnly` observes metadata/timeline/art and keeps
the original controls disabled. `Interactive` also enables the control hook for
explicit user interaction; it is not validated by this slice and sends no
automatic playback. Every `-Smoke` run is read-only regardless of the requested
mode. The M1 entry point and the audio/battery prototypes keep their own
profiles and flags.

The wrapper's `defaultPlayer` and `playerAliases` come from the isolated
profile's `GlobalConfig`, like upstream. No persistent manual selection is
written; the upstream `PersistentProperties` store, IPC handler, global
shortcuts (`mediaToggle`/`mediaPrev`/`mediaNext`/`mediaStop`) and
now-playing-toast path are intentionally not staged.

## Validation

```powershell
powershell -NoProfile -File windows/scripts/Test-MediaService.ps1 `
    -QtPrefix $qtPrefix
powershell -NoProfile -File windows/scripts/Test-MediaPrototype.ps1 `
    -QtPrefix $qtPrefix
```

`Test-MediaService.ps1` stages only the adapter and fixture into Qt's offscreen
`qml.exe`. It rejects native imports, staging hash mismatches and QML
diagnostics. The 148 injected assertions cover:

- safe disabled construction and the absence of transport members;
- alias identity, default selection ordering, stale/foreign manual selection
  and reordering;
- disabled/loading/unavailable/healthy-empty/observed transitions;
- native operation/HRESULT exposure, stale-error clearing on recovery and
  retained-snapshot hiding while unavailable;
- removal, re-arrival and scan-outage recovery;
- progressive title/artist/album/uniqueId/position/length/playback updates;
- native art URLs, the preserved YouTube metadata fallback and invalid values;
- positive and negative capability gates, non-boolean native values, seeking
  without `positionSupported`, and unconditionally false unsupported actions;
- malformed backend/model shapes without invented state.

`Test-MediaPrototype.ps1` runs the fixture, then disabled/read-only smoke on
every measured connected screen, then the original M1 bar/session regression.
Each smoke asserts the disabled mode leaves the native backend loader inactive,
with no facade and no original component; an enabled run loads the original
`Details` window with the control hook disabled and rejects QML diagnostics;
each run records source and staged hashes, initial/final state, logs and a PNG. The parent agent owns native
real-session observation, interactive controls and the remaining regressions on
a desktop; this checkout records only the offscreen fixture run unless a native
harness is available.

Raw results are under `windows/.local/build/media-validation-<timestamp>/`.

## Limits

- Real GSMTC initialization, session enumeration, metadata, art caching,
  removal, denial and recovery are validated by the parent's native observation,
  not by the offscreen fixture. No session or playback claim is made here.
- The control opt-in only gates requests. There is no per-command confirmation,
  no retry loop, no playback automation and no toast/shortcut/IPC side path.
  The upstream slider's custom mouse area is not disabled by `enabled: false`,
  so a read-only drag can still animate the handle visually; `onInteraction`
  returns before any position write, so no transport request is sent.
- Cover art, lyrics, the player selector, the full dashboard media tab and the
  media GIF are outside this smallest meaningful original subset.
- No backend source, gitlink or `sources.lock.json` change is part of this
  slice; the backend status boundary is pinned and audited in
  [M2-MEDIA-BACKEND-GAPS.md](../audits/M2-MEDIA-BACKEND-GAPS.md).
