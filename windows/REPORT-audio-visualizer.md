# Audio visualiser and beat tracking on Windows

Caelestia's audio visualiser and beat/audio analysis now run on Windows without
libcava, aubio, PipeWire or any backend-fork change.

## What works

- **System-output capture.** `AudioCollector` opens the default render endpoint
  with WASAPI loopback (`IAudioClient`/`IAudioCaptureClient`,
  `AUDCLNT_STREAMFLAGS_LOOPBACK`, shared mode, the endpoint's own mix format).
  It registers an `IMMNotificationClient` and rebuilds the client when the
  default output changes, retries quietly when no endpoint exists, and pushes
  mono 44.1 kHz frames into the same ring buffer the upstream processors read.
  Shared-mode 32-bit float, 16-bit PCM and 32-bit PCM mixes are downmixed and
  linearly resampled; silence and idle endpoints decay the bars to zero.
- **Bars (cava port).** `CavaPlan` ports the cava path used upstream: 2048-point
  Hann FFT, logarithmically spaced bands between the configured low/high cut,
  noise floor, bounded auto-sensitivity and fast-attack/slow-release smoothing.
  The original `CavaProcessor` still applies its own monstercat pass and emits
  the same `values`.
- **Beats (aubio replacement).** `OnsetDetector` uses spectral flux with a short
  adaptive threshold, a refractory window and the median of recent inter-onset
  intervals folded into 70-180 BPM. `BeatTracker.bpm` keeps the upstream
  default of 120 and updates only on detected onsets.
- **Same QML API.** `CavaProvider`, `BeatTracker` and `ServiceRef` keep their
  upstream names, properties and ref/unref lifetime; they are built into a new
  `Caelestia.Windows.Audio` module (`plugin/src/Caelestia/Windows/Audio`).
  `Audio.cava`/`Audio.beatTracker` in the Windows `services/Audio.qml` facade
  hold the real providers once the existing `CAELESTIA_WINDOWS_AUDIO` opt-in is
  on; before that they return the disabled compatibility objects.
- **Original components.** The combined-only `CoverVisualiser` and
  `dash/Media.qml` adapters are deleted and the upstream files are staged
  again: the dashboard media panel renders the ring of bars around the cover
  and the beat-driven media GIF from `Audio.cava.values` and
  `Audio.beatTracker.bpm`. `modules/background/Visualiser.qml` consumes the
  same `Audio.cava.values`; this bounded host stages no background, so that
  path is wired but not exercised here.

## Branch and commits

Branch `t3/audio-visualizer`, based on `origin/t3/combined-modules`
(`6026f947`):

- `1fc8b8e6` `windows: add WASAPI loopback audio analysis to the plugin`
- `18385298` `windows: restore the original visualiser and beat tracker in the combined preview`
- the report commit (`windows: report the audio visualiser port`)

No backend-fork changes: capture and analysis live entirely in this
repository's C++ plugin. `windows/sources.lock.json` and the Quickshell gitlink
are unchanged.

## Launch

```powershell
$qtPrefix = "$env:LOCALAPPDATA\caelestia-dev\Qt\6.11.2\msvc2022_64"
powershell -NoProfile -File windows/scripts/Build-Prototype.ps1 `
    -QtPrefix $qtPrefix `
    -LlvmBin "$env:LOCALAPPDATA\caelestia-dev\clang+llvm-20.1.8-x86_64-pc-windows-msvc\bin" `
    -Cli11Include "$env:LOCALAPPDATA\caelestia-dev\deps\CLI11-2.5.0\include" `
    -ToolsBin "$env:LOCALAPPDATA\caelestia-dev\tools\Scripts"
powershell -NoProfile -File windows/scripts/Start-ShellPrototype.ps1 `
    -QtPrefix $qtPrefix -BuildRoot <this worktree>\windows\.local\build -Combined -Live
```

Open the dashboard's Media tab (top edge, then Media) to see the bars; the
Dashboard tab's media GIF follows the detected tempo.

## Verification

- Native build passes with Qt 6.11.2 `msvc2022_64`, clang-cl 20.1.8 and the
  pinned backend `525786f` (no fork patch).
- `Test-AudioService.ps1`: 238 assertions pass; the disabled/unavailable
  `Audio.cava`/`Audio.beatTracker` shapes are unchanged for the fixture.
- Measured bars/beat with a synthetic 120 BPM tone (100 Hz pulse plus a 1.2 kHz
  click) played through the default output, read from a standalone QML harness
  that constructs the original `CavaProvider`/`BeatTracker` types: `bars 48`,
  peak `0.85-0.89` during each pulse down to `0.00` between pulses, reported
  tempo `114.1-114.7` BPM. This proves capture, FFT bars and the onset detector
  end to end; it is not a music-genre accuracy claim.
- `Start-ShellPrototype.ps1 -Combined -Smoke` passes: `passed: true`,
  `CAELESTIA_COMBINED_PASS 6.11.2`, and the dashboard Media step logs
  `CAELESTIA_COMBINED_AUDIO_ANALYSIS {"bars":60,"values":60,"bpm":120}` — the
  original CoverVisualiser is bound to the native provider, not the
  unavailable compatibility object. All dashboard, popout, launcher,
  notification and session steps pass with no runtime warnings.

## Known limits

- Earlier smoke attempts failed at the unrelated notification-popup assertion
  while two to three other agents' `qs.exe` instances were running on this
  session; the same failure reproduced at `6026f947` with this work stashed.
  The final run, with the providers enabled, passed every step.
- One earlier combined run (both with and without these changes) exited with
  code -1 during the Weather tab; retries completed. Not investigated here.
- Analysis is a design port, not a byte-for-byte cava/aubio match: bar scaling,
  band edges and tempo folding will not equal libcava/aubio output. Bar cadence
  is 512 samples (~11.6 ms) with a 2048-sample FFT window.
- Only the default *render* endpoint in `eConsole`/`eMultimedia` is captured
  (loopback); per-application capture, microphone input and exclusive-mode
  streams are out of scope.
