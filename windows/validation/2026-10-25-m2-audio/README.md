# M2 audio integration acceptance, 2026-10-25

ERM-495's service audit, ERM-496's bounded audio integration and ERM-497's
backend capability/error patch are implemented. This archive validates native
**read-only observation**, original audio UI loading, disabled construction,
mutation guards and deterministic injected failures. It does not complete M2.

## Sources and runtime

- Root source: clean `fb6665ab4c901cf60871b4847d7e62d3e6777742`.
- Backend: clean `8c71bdb8116dffeb274edb31c3803e1c28dbb270`, committed in the
  [dedicated fork PR #1](https://github.com/KldsSeeGhosts/caelestia-quickshell-windows/pull/1).
  The gitlink and `windows/sources.lock.json` agree.
- Original Caelestia baseline: `2e1c51fa76d94457624b642c678218970aa2517a`.
- Windows 11 `10.0.26300.0`, Qt 6.11.2 `msvc2022_64`, clang-cl 20.1.8,
  MSVC tools 14.44.35207, Windows SDK 10.0.26100.0, CMake 4.4.4 and Ninja
  1.13.2. Exact [build record](build/build.json), process-local
  [environment report](build/environment.json) and commands/logs are archived.
- This is a clean-source **incremental build**, not a from-scratch build or
  clean-profile install. Build output reused unchanged portable plugin objects.
  The backend's changed sources were compiled before this clean-source record.
- Ordinary PowerShell's [environment report](build/m2-environment-ordinary.json)
  correctly reports missing development tools on PATH. The build script's
  process-local report passes. Neither report alone proves runtime compatibility.

## Commands and results

From the repository root in native PowerShell:

```powershell
$devRoot = "$env:LOCALAPPDATA\caelestia-dev"
$qtPrefix = "$devRoot\Qt\6.11.2\msvc2022_64"
powershell -NoProfile -File windows/scripts/Build-Prototype.ps1 `
    -QtPrefix $qtPrefix `
    -LlvmBin "$devRoot\clang+llvm-20.1.8-x86_64-pc-windows-msvc\bin" `
    -Cli11Include "$devRoot\deps\CLI11-2.5.0\include" `
    -ToolsBin "$devRoot\tools\Scripts"
powershell -NoProfile -File windows/scripts/Test-BackendAudio.ps1 `
    -QtPrefix $qtPrefix `
    -LlvmBin "$devRoot\clang+llvm-20.1.8-x86_64-pc-windows-msvc\bin" `
    -ToolsBin "$devRoot\tools\Scripts"
powershell -NoProfile -File windows/scripts/Test-AudioPrototype.ps1 `
    -QtPrefix $qtPrefix
```

The final [matrix](matrix.json) passes all six runs at clean `fb6665ab`.
Each UI run has its own result JSON, stdout/stderr, staged source manifest
and PNG. Runtime diagnostics fail acceptance; all final UI logs are clean.
Runtime executable hashes and measurement-source hashes are recorded.

| Check | Observed result | Evidence |
| --- | --- | --- |
| Injected adapter state/mutations | 238 assertions pass in offscreen Qt `qml.exe`; no native audio backend staged | [fixture result](fixture/result.json), [log](fixture/stderr.log) |
| Native fake-COM backend | 16 QtTest cases pass, including init/cleanup and eight role-failure combinations | [result](native-fixtures/result.json), [case log](native-fixtures/fixtures.txt) |
| Disabled, primary | Native DPR 1.5, 640x620; backend not constructed; no endpoints/streams observed | [result](audio-disabled-screen0/result.json), [capture](audio-disabled-screen0/capture.png) |
| Read-only, primary | Native DPR 1.5; four outputs, one input, nine application streams; original controls render | [result](audio-readonly-screen0/result.json), [capture](audio-readonly-screen0/capture.png) |
| Disabled, secondary | Native DPR 1.75 at x=-3840; backend not constructed | [result](audio-disabled-screen1/result.json), [capture](audio-disabled-screen1/capture.png) |
| Read-only, secondary | Native DPR 1.75 at x=-3840; same 640x620 logical UI and endpoint state | [result](audio-readonly-screen1/result.json), [capture](audio-readonly-screen1/capture.png) |
| Existing M1 regression | Original bar/session rendering/open/close smoke passes with updated backend | [result](m1-regression/result.json), [capture](m1-regression/capture.png) |

Backend tests use stack-owned fake COM interfaces. Expected QWARN lines are
deliberately failed setters, not accepted prototype runtime diagnostics.
They cover missing interface, denied session/endpoint writes, failed reads
without invented state, device invalidation/recovery in fixtures, failed
notification registration, finite/channel guards, partial channel writes and
all eight success/failure combinations for the three Windows default roles.
They do not construct a device enumerator or change real audio.

The adapter tests cover disabled/loading/unready/denied states, reactive
arrival/removal/default changes, stale/reused identity, missing input/output,
read-only and per-node control guards, failed state reads, native error
propagation, wrong-direction nodes, stream helpers, finite/range limits and
failed routing without changing its observed default.

Every UI smoke attempts eleven public mutation routes and requires each to
return false. Controls and native input/focus activation stay disabled.
The read-only host observes Windows' existing output at approximately 32% and
microphone at 100%, both unmuted. Snapshot metadata records interface presence
and successful state reads independently of the controls opt-in.

## Isolation and unchanged native state

Independent getter-only Core Audio snapshots
[before](audio-before.json) and [after](audio-after.json) are equal:
all five active endpoints retain volume, mute and channel levels, and all six
Console/Multimedia/Communications input/output default-role hashes match.
No snapshot errors occurred. These measurements do not record application
session levels; application stream write guards are covered by fixtures and
the in-process smoke assertions.

Desktop snapshots [before](desktop-before.json) and
[after](desktop-after.json) preserve Explorer PID 9872, KSG Shell PID 32044,
both physical monitor/work rectangles and taskbar flags `1`.
No prototype remains. No pointer/keyboard, system transparency, display,
autostart, taskbar or tiler setting was changed.

The test uses fresh stages and a dedicated audio config/state/runtime profile.
The [isolated configuration](isolated-shell.json) has all session commands
empty and other panels disabled. Source manifests distinguish original QML
from the host/adapter. Fonts and licenses retain the M1 staging/provenance.
The backend still performs normal own-window virtual-desktop support, instance
bookkeeping and stale-AppBar startup cleanup. This is not a zero-global-effect
claim. The backend queries application process names while enumerating audio
sessions, but recorded in-app snapshots expose only a stream count.

## Failures resolved and limits

An early development disabled-panel run reported two undefined fixed palette
colors for the statically declared settings button. Adding their original
upstream defaults fixed it. No warned run is counted above.

The native Qt test executable initially failed to start because LLVM 20's
manifest merge namespaced the `requestedExecutionLevel` attributes incorrectly.
Switching the test target to the installed Microsoft linker and SDK `mt.exe`
preserved the ordinary `asInvoker` manifest; UAC/security settings were unchanged.
Changing only `mt.exe` was insufficient. The production runtime's linker was
unchanged and its manifest remained valid.

Not validated here:

- Actual Windows access denial, hot-plug/removal, sleep/wake or hardware recovery.
- Real volume/mute writes, device-role changes, native pointer/keyboard audio
  interactions, scrolling under long device lists or interactive error recovery.
- Same-window monitor transfer or a fresh M1 input/transparency matrix.
  M1's earlier native input evidence remains revision-specific.
- Cava/beat analysis, other Windows services, full shell, tiling or packaging.
- Linux builds.

`controlAvailable` means a native interface exists, not guaranteed permission
for every future operation. The backend exposes HRESULT errors and observed
state; the adapter does not retry. The separate interactive mode is implemented
but remains opt-in and outside this acceptance claim. Remaining live audio
validation is tracked in ERM-508 before M2 can close.

Machine-generated evidence is copied byte-for-byte. Local `.gitattributes`
prevents line-ending/whitespace rewriting. `artifacts.sha256.json` identifies
the archived evidence bytes. Original absolute paths in raw logs identify this
workstation; this README links to their portable archived copies.
