# M2 media observation prototype, 2026-10-25

This archive records the bounded media slice in
[root PR #7](https://github.com/KldsSeeGhosts/caelestia-windows/pull/7), stacked
on battery PR #5, and
[backend PR #3](https://github.com/KldsSeeGhosts/caelestia-quickshell-windows/pull/3),
stacked on backend PR #2. ERM-498 remains **In Progress**. Native tests
observed a healthy GSMTC backend with **no open sessions**. They do not
establish real-session metadata, artwork, removal/recovery or transport.

## Sources and runtime

- Clean root `d9cdcf9a92a6e3dc108403efc8336a42b5aaee92`.
- Clean pushed backend `1401042969e4b7ab3cfb314fc76945ab081db3de`.
  Gitlink and source manifest agree.
- Windows 11 `10.0.26300.0`, Qt 6.11.2, clang-cl 20.1.8, MSVC tools
  14.44.35207, Windows SDK 10.0.26100.0, CMake 4.4.4 and Ninja 1.13.2.
- Incremental native backend/portable-plugin build, not from scratch.
  [Build record](build/build.json), [process-local environment](build/environment.json),
  configure/build/install commands and logs are included.
- Primary monitor at native 150%; secondary at native 175%, x=-3840.

## Delivered scope

The default-off Players adapter separates disabled, loading, unavailable,
healthy-no-sessions and observed states using the native `ready`/`lastError`
boundary. It hides retained snapshots while unavailable and gates controls on
the separate opt-in, list membership, native `canControl` and individual
capabilities. Unsupported stop, raise, quit, openUri and volume stay false.
Selection, aliases, metadata, timeline and artwork URLs preserve the useful
public service API without shortcuts, playback automation or toasts.

The bounded host stages original `modules/dashboard/media/Details.qml` and
`components/controls/StyledSlider.qml`, plus their original support components.
The Details component has a control hook defaulting true for upstream
consumers. The Windows host wires it to the service's `canControl(active)`;
smoke always disables playback opt-in. The full dashboard, player selector,
cover-art UI and lyrics are not included.

Backend review found that the old thumbnail cache bypassed CacheDir and could
prune the shared application cache. The corrected backend resolves the
profile cache on the frontend thread and passes an immutable directory to the
worker. Cache fixtures write PNGs and prune only temporary fixture directories,
preserve another profile's sentinel, retain the new image and reject invalid
image bytes. Real GSMTC thumbnail caching was not observed in this run.

## Results

| Check | Observed result | Evidence |
| --- | --- | --- |
| Native lifecycle status fixtures | 6 passed, 0 failed | [QtTest output](backend-fixtures/mpris_status_test.txt) |
| Native artwork-cache fixtures | 5 passed, 0 failed | [QtTest output](backend-fixtures/mpris_art_cache_test.txt), [result](backend-fixtures/result.json) |
| Offscreen media adapter | 148 assertions, no diagnostics or native imports | [result](fixture/result.json), [staged fixture](fixture/PlayersServiceTest.qml) |
| Disabled at 150% and 175% | Pass; no facade/native loader or original player constructed | [primary](media-disabled-screen0/result.json), [secondary](media-disabled-screen1/result.json) |
| Read-only at 150% and 175% | Pass; successful scan, `no-sessions`, original component loaded, all control gates false | [primary](media-readonly-screen0/result.json), [capture](media-readonly-screen0/capture.png), [secondary](media-readonly-screen1/result.json), [capture](media-readonly-screen1/capture.png) |
| Original M1 regression | Pass | [result](m1-regression/result.json) |
| Battery/shared-script regression | Pass; 128 adapter assertions and four native battery runs | [matrix](shared-regressions/matrix.json) |
| Full audio regression | Pass; 238 assertions, four native audio runs and M1 smoke | [matrix](shared-regressions/audio-regression/matrix.json) |

The lifecycle fixtures exercise the status boundary without a GSMTC worker;
they do not inject real WinRT initialization failures. QML fixtures cover
lifecycle, stale snapshots, selection, progressive metadata, capability gates
and unsupported actions. The native UI runs validate only the actual empty
session state reported here.

[Media matrix](matrix.json) and nested regression matrices record
`sourceDirty=false` at the revisions above. Raw results, logs, source manifests,
screenshots and fixture sources are copied without rewriting paths.
[artifacts.sha256.json](artifacts.sha256.json) identifies all 124 raw artifacts.
Archive attributes preserve their bytes, and the build-directory exception
keeps the build evidence tracked. `archive.ps1` records the copy procedure.

## Preserved state

[Desktop before](desktop-before.json) and [after](desktop-after.json) preserve
Explorer PID 9252, KSG Shell PID 24108, monitor/work rectangles and taskbar
flags. The shared regression independently preserves desktop state and
[power before](shared-regressions/power-before.json) /
[after](shared-regressions/power-after.json): Balanced base scheme
`381b4222-f694-41f0-9685-ff5bb260df2e`, Best-performance overlay
`ded574b5-45a0-4f42-8737-46345c09c238`, AC online and no battery.

Tests sent no pointer/keyboard input or automatic transport request. Playback
controls were disabled; no application was launched to create a session.
No tiling, taskbar, autostart, power, credential or security setting changed.

## Commands

Native PowerShell from the repository root:

```powershell
$devRoot = Join-Path $env:LOCALAPPDATA 'caelestia-dev'
$qtPrefix = "$devRoot\Qt\6.11.2\msvc2022_64"
$llvmBin = "$devRoot\clang+llvm-20.1.8-x86_64-pc-windows-msvc\bin"
powershell -NoProfile -File windows/scripts/Test-Environment.ps1 -Json
powershell -NoProfile -File windows/scripts/Build-Prototype.ps1 `
    -QtPrefix $qtPrefix -LlvmBin $llvmBin `
    -Cli11Include "$devRoot\deps\CLI11-2.5.0\include" `
    -ToolsBin "$devRoot\tools\Scripts"
powershell -NoProfile -File windows/scripts/Test-BackendMedia.ps1 `
    -QtPrefix $qtPrefix -LlvmBin $llvmBin `
    -ToolsBin "$devRoot\tools\Scripts"
powershell -NoProfile -File windows/scripts/Test-MediaPrototype.ps1 `
    -QtPrefix $qtPrefix
powershell -NoProfile -File windows/scripts/Test-BatteryPrototype.ps1 `
    -QtPrefix $qtPrefix
```

The ordinary-session environment report confirms pin alignment but still
reports tools absent from PATH. The build script's process-local environment
passes; neither prerequisite report substitutes for build/runtime results.

## Remaining acceptance

Real session arrival/removal, progressive metadata/art/timeline and selection
are fixture-validated only. Real Windows denial, session loss/recovery and
interactive transport remain unvalidated. The backend does not expose a
per-command result; a permitted request must not be described as confirmed
success. No media playback or application launch was performed to fill those
gaps. ERM-498, ERM-499 and M2 remain incomplete.

M1 checks are smoke regressions, not renewed input/transparency acceptance.
No Linux build, full-shell release or remote CI pass is claimed. Inherited
root Actions remain disabled; backend jobs have been blocked before execution
by account billing/spending limits.
