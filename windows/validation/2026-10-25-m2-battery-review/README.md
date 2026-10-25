# M2 battery review corrections, 2026-10-25

This run validates the corrected read-only battery subset in
[root PR #5](https://github.com/KldsSeeGhosts/caelestia-windows/pull/5), using
[backend PR #2](https://github.com/KldsSeeGhosts/caelestia-quickshell-windows/pull/2).
ERM-499 remains **In Progress**, with profile capability, separate write
opt-in, denied writes and battery-present hardware acceptance outstanding.

## Recorded sources and environment

- Clean root `96788c8a4e009466dadd94fde89b9287263ebd20`.
- Clean backend `5d0a33d36b17cb41d658b4a4a699c56ae91d6b5e`, pushed to the
  dedicated backend fork. Gitlink and source manifest agree.
- Windows 11 `10.0.26300.0`, Qt 6.11.2, clang-cl 20.1.8, MSVC tools
  14.44.35207, Windows SDK 10.0.26100.0, CMake 4.4.4, Ninja 1.13.2.
- Incremental native build, not a from-scratch build. The
  [build record](build/build.json), [process-local environment](build/environment.json),
  and configure/build/install commands and logs are included.
- Hardware: no battery; primary monitor at native 150%, secondary at native
  175%, x=-3840. There is no battery-present hardware claim.

## Changes and results

The original status icon now has `profileStatusEnabled=false`. Smoke checks
assert that guard, both popout profile guards, source-validity wiring,
unsupported charge-time policy and the expected absent/unknown glyphs.
The captured batteryless icon is `battery_alert`, not the performance rocket.
Unknown charge, failed reads and unknown presence are separate capabilities,
not measured zero or proven absence. Unknown AC source supplies neither a
discharging state nor a time-to-empty estimate. Unsupported charge time is
labeled unavailable by the Windows host.

| Check | Result | Evidence |
| --- | --- | --- |
| Native fake-status fixtures | 9 passed, 0 failed | [result](backend-fixtures/result.json), [QtTest output](backend-fixtures/fixtures.txt) |
| Offscreen battery adapter | 128 assertions, no runtime diagnostics | [result](fixture/result.json), [staged fixture](fixture/BatteryServiceTest.qml) |
| Disabled at 150% and 175% | Pass; backend and original battery components remain unloaded | [primary](battery-disabled-screen0/result.json), [secondary](battery-disabled-screen1/result.json) |
| Read-only at 150% and 175% | Pass; known absence, no percentage, guarded battery-alert glyph | [primary result](battery-readonly-screen0/result.json), [capture](battery-readonly-screen0/capture.png), [secondary result](battery-readonly-screen1/result.json), [capture](battery-readonly-screen1/capture.png) |
| Original M1 smoke | Pass | [result](m1-regression/result.json) |
| Full audio regression harness | Pass; 238 assertions, four native audio smokes and M1 smoke | [matrix](audio-regression/matrix.json) |

The [battery matrix](matrix.json) and nested audio matrix both record clean
source. Each UI run includes its raw result, stdout/stderr, source manifest
and screenshot. [artifacts.sha256.json](artifacts.sha256.json) covers all 90
raw evidence artifacts, including build logs. The local ignore exception
keeps the build archive tracked. Raw evidence retains original absolute
workstation paths; copies are not rewritten.

## Native state preservation

[Power before](power-before.json) and [after](power-after.json) are
identity-equal: base scheme `381b4222-f694-41f0-9685-ff5bb260df2e` (Balanced),
effective overlay `ded574b5-45a0-4f42-8737-46345c09c238` (Best performance),
AC online, battery absent, raw unknown charge 255. The adapter correctly
reports `percentageKnown=false` for this absent device.

[Desktop before](desktop-before.json) and [after](desktop-after.json)
preserve Explorer PID 9252, KSG Shell PID 24108, both monitor/work rectangles
and taskbar flags. The harness supplied no pointer or keyboard input, power
writes, taskbar changes, tiling, autostart or shell takeover.

## Commands

From the repository root in native PowerShell:

```powershell
$devRoot = Join-Path $env:LOCALAPPDATA 'caelestia-dev'
$qtPrefix = "$devRoot\Qt\6.11.2\msvc2022_64"
$llvmBin = "$devRoot\clang+llvm-20.1.8-x86_64-pc-windows-msvc\bin"
powershell -NoProfile -File windows/scripts/Test-Environment.ps1 -Json
powershell -NoProfile -File windows/scripts/Build-Prototype.ps1 `
    -QtPrefix $qtPrefix -LlvmBin $llvmBin `
    -Cli11Include "$devRoot\deps\CLI11-2.5.0\include" `
    -ToolsBin "$devRoot\tools\Scripts"
powershell -NoProfile -File windows/scripts/Test-BackendBattery.ps1 `
    -QtPrefix $qtPrefix -LlvmBin $llvmBin `
    -ToolsBin "$devRoot\tools\Scripts"
powershell -NoProfile -File windows/scripts/Test-BatteryPrototype.ps1 `
    -QtPrefix $qtPrefix
```

The ordinary-session environment report confirms pin alignment but still
reports tools missing from PATH. The build script's process-local toolchain
environment passes. Neither prerequisite report substitutes for the recorded
build and runtime tests. `archive.ps1` records the evidence-copy procedure.

## Limits and historical evidence

Unknown charge/presence/source, failed reads and stale-value clearing are
fixture-validated. Actual battery-present hardware, Windows read failures,
device recovery, sleep/wake, profile/overlay writes, denied writes and
IdlePower remain unvalidated. A native absence run does not close those gates.
The M1 regression is a smoke, not a new input/transparency acceptance matrix.
No Linux build or remote CI pass is claimed; backend jobs remain affected by
the account billing/spending-limit block.

The [earlier archive](../2026-10-25-m2-battery/README.md) retains its original
source and raw artifacts, including the incorrect profile icon. Its corrected
notes identify what that run did not validate. The 12 build artifacts omitted
from the original PR are now tracked with their original hashes.
