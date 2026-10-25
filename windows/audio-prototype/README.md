# Windows audio prototype

ERM-496's first M2 slice loads the original
[`AudioPopout.qml`](../../modules/bar/popouts/AudioPopout.qml),
`PopoutState`, radio buttons and slider in a separate bounded native window.
The window is at most 640x620 logical pixels, inset 80 from the chosen screen.
Long device lists scroll. Escape closes an interactive run.

The [Audio adapter](../services/audio/AudioService.qml) preserves the core
public `services/Audio.qml` API using native Core Audio endpoints/sessions.
The upstream Linux service is unchanged. Explicit disabled, initializing,
unavailable and ready states distinguish observation from control capability.
Missing defaults, failed reads, stale/wrong-direction nodes and invalid numbers
cannot produce writes. Windows volume is capped at 100%, even if the upstream
maximum allows amplification. Volume changes retain upstream's unmute-first
behavior; a failed unmute stops the volume request.

No Cava/beat analysis, global shortcuts, IPC audio mutations, device-change
toasts, Nexus/settings detachment or unrelated services are created. The
visualizer compatibility objects are explicitly unavailable and cannot satisfy
native `ServiceRef` consumers. Real session actions remain unavailable.
Taskbar, tiling, autostart and desktop controllers are not instantiated.
The backend retains ordinary instance bookkeeping, own-window desktop support
and stale-AppBar startup cleanup as documented for M1.

## Launch

Build using [NATIVE-BUILD.md](../NATIVE-BUILD.md). In native PowerShell:

```powershell
$qtPrefix = "$env:LOCALAPPDATA\caelestia-dev\Qt\6.11.2\msvc2022_64"
powershell -NoProfile -File windows/scripts/Start-ShellPrototype.ps1 `
    -QtPrefix $qtPrefix -Audio -AudioMode ReadOnly -Wait
```

`-Audio` selects this separate entry point. `-AudioMode Disabled` is the
default and never loads the native audio backend. `ReadOnly` opts into COM
enumeration, endpoint/session notifications and existing levels/defaults.
`Interactive` also permits explicit UI volume and device-selection requests.
Device selection affects Windows Console, Multimedia and Communications roles.
Live writes and actual hardware-denial/recovery are not certified by the
read-only acceptance run.

Both opt-ins are child-process environment variables
`CAELESTIA_WINDOWS_AUDIO` and `CAELESTIA_WINDOWS_AUDIO_CONTROLS`.
The launcher sets them explicitly, preventing inherited flags from enabling
services in the M1 profile. Every `-Smoke` run disables controls and input,
including when `Interactive` was requested. The M1 profile's default behavior
is preserved. This host uses its own `audio-prototype-profile` and fresh source
stage under ignored `windows/.local/build`.

The original audio component has localized properties for output/input control
availability, output selection, missing volume and settings visibility.
Defaults preserve upstream behavior. These hooks allow read-only/unavailable
Windows states without substituting the original controls. Two fixed palette
colors were added from upstream defaults.

## Validation

```powershell
powershell -NoProfile -File windows/scripts/Test-AudioService.ps1 `
    -QtPrefix $qtPrefix
powershell -NoProfile -File windows/scripts/Test-AudioPrototype.ps1 `
    -QtPrefix $qtPrefix
```

The first command runs injected QML fixtures in Qt's offscreen `qml.exe`,
staging only the state object and fixtures. It constructs no native audio
backend and tests reactive models, removal/default changes, numeric guards,
denial/unready states and mutation policy. Native backend fixtures use fake COM
interfaces, documented in the acceptance archive. Neither simulates a real
device unplug or actual Windows permission change.

Reproduce the native fake-COM fixtures without touching audio hardware:

```powershell
$devRoot = "$env:LOCALAPPDATA\caelestia-dev"
powershell -NoProfile -File windows/scripts/Test-BackendAudio.ps1 `
    -QtPrefix $qtPrefix `
    -LlvmBin "$devRoot\clang+llvm-20.1.8-x86_64-pc-windows-msvc\bin" `
    -ToolsBin "$devRoot\tools\Scripts"
```

The second command runs disabled/read-only smoke on every measured connected
screen, then the original M1 bar/session regression. Each run records
source/staged hashes, runtime/build references, snapshots, logs and a PNG.
It rejects QML diagnostics and checks that all attempted read-only mutations
return false. Independent read-only Core Audio measurements compare all active
endpoint levels, mute, channels and default roles before/after. Endpoint IDs
are hashed; this independent measurement records no application metadata.
The backend itself still queries session process names during enumeration.
In-app evidence records only a stream count, not per-application metadata.

The harness also compares shell PIDs, taskbar flags and physical monitor/work
areas. It changes no pointer, keyboard, audio, system preference or monitor
settings. External endpoint changes during the run cause an honest failure,
not automatic restoration. Raw results are under
`windows/.local/build/audio-validation-<timestamp>/result.json`.

The [M2 source audit](../audits/M2-SERVICES.md) records the previous pin's
limitations. Backend `8c71bdb8` adds `Pipewire.lastError`,
`defaultSelectionError`/`defaultSelectionFinished` and
`PwNodeAudio.controlAvailable`, `stateAvailable`, `controlError`.
Failed reads retain the last complete snapshot but mark it unavailable.
Default selection reports all role failures and refreshes the observed
console default rather than assigning a requested node optimistically.
Control availability means an interface exists; an individual write can still
fail. The adapter exposes those synchronous errors and makes no retry loop.
