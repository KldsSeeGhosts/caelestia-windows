# Windows battery prototype

ERM-499's read-only M2 slice loads the original
[`BatteryStatus.qml`](../../modules/bar/components/status/BatteryStatus.qml)
status icon and the original
[`Battery.qml`](../../modules/bar/popouts/Battery.qml) popout content in a
separate bounded native window. The window is at most 640x620 logical pixels,
inset 80 from the chosen screen. Escape closes an interactive run.

The [Battery adapter](../services/battery/BatteryService.qml) projects the
pinned backend's native `Quickshell.Services.UPower` display device and
`onBattery` source: explicit disabled/initializing/unavailable/ready states,
truthful battery presence (`present`/`absent`), a percentage guarded to finite
0..1, the upstream charging-state gating, and null-safe behavior when the
device is missing, stale, or a native read failed.

The backend pin now carries capability fields rather than inferring absence
from missing data. `UPowerDevice.isAvailable` records whether the
`GetSystemPowerStatus` read succeeded, `isPresenceKnown` distinguishes Win32's
"battery flag unknown" (255) from the proven "no battery" flag (128), and
`isPercentageKnown` distinguishes `BATTERY_PERCENTAGE_UNKNOWN` (255) from an
actual 0%. `UPower.onBatteryKnown` marks whether the AC source read succeeded.
A failed read clears the device's level, state, estimate, icon, path and model
instead of retaining the previous reading, and the adapter then reports
`observationAvailable=false` and `status="unavailable"` rather than proven
absence. A successful read that proves no battery reports `status="ready"`,
`absent=true`, no fake level and the original "No battery detected" state.
Energy/health telemetry stays unavailable, matching the backend's stubbed
values. See [backend PR #2](https://github.com/KldsSeeGhosts/caelestia-quickshell-windows/pull/2).

This slice is strictly read-only. The adapter exposes no mutating methods at
all. `PowerProfiles` is never referenced by the adapter or the host, and the
original components' profile hooks are disabled by the host: the profile
selector does not render, its click handler is disabled, the degradation
warning does not activate, and profile text reports "Power profile
unavailable". No power scheme, overlay, or IdlePower setting is written.
`IdlePower` and profile selection remain a separate later issue.

No notifications, network, Bluetooth, brightness, app catalog, tray, media,
session actions, global shortcuts or unrelated services are created. The
backend retains ordinary instance bookkeeping, own-window desktop support and
stale-AppBar startup cleanup as documented for M1.

## Launch

Build using [NATIVE-BUILD.md](../NATIVE-BUILD.md). In native PowerShell:

```powershell
$qtPrefix = "$env:LOCALAPPDATA\caelestia-dev\Qt\6.11.2\msvc2022_64"
powershell -NoProfile -File windows/scripts/Start-ShellPrototype.ps1 `
    -QtPrefix $qtPrefix -Battery -BatteryMode ReadOnly -Wait
```

`-Battery` selects this separate entry point. `-BatteryMode Disabled` is the
default and never loads the native power backend or instantiates the original
UPower components. `ReadOnly` opts into the native UPower observation (its
initial status read, 30-second poll and power notifications). There is no
`Interactive` mode: this slice has no writes.

The opt-in is a child-process environment variable
`CAELESTIA_WINDOWS_BATTERY`. The launcher sets it explicitly, preventing
inherited flags from enabling the service in the M1 profile. Every `-Smoke`
run is read-only by construction. The M1 profile's default behavior is
preserved. This host uses its own `battery-prototype-profile` and fresh source
stage under ignored `windows/.local/build`.

The original components gained localized Windows hooks, all defaulting to
upstream behavior: `profileStatusEnabled`/`profileControlsEnabled` for the
PowerProfiles read/write paths, and `observationAvailable`/`percentageKnown`
for the native UPower capability fields. The host wires the latter two from
the adapter, so a failed or unknown read renders "Battery status unavailable"
or "Battery level unknown" instead of a level, and the status icon uses
`battery_unknown` rather than a zero-level or profile glyph. The status icon
also sets `profileStatusEnabled: false` explicitly; every read-only smoke
asserts that guard and the truthful absent/unknown glyph before capture.
Unlike the audio host, the original UPower components are instantiated only
in the read-only mode: they bind the native `UPower` singleton directly, so
disabled mode keeps them unloaded through host loaders. All battery display
gating remains the original component logic; the adapter's `hasBattery`
matches upstream's `isLaptopBattery` display gate.

## Validation

```powershell
$devRoot = "$env:LOCALAPPDATA\caelestia-dev"
$qtPrefix = "$devRoot\Qt\6.11.2\msvc2022_64"
powershell -NoProfile -File windows/scripts/Test-BackendBattery.ps1 `
    -QtPrefix $qtPrefix `
    -LlvmBin "$devRoot\clang+llvm-20.1.8-x86_64-pc-windows-msvc\bin" `
    -ToolsBin "$devRoot\tools\Scripts"
powershell -NoProfile -File windows/scripts/Test-BatteryService.ps1 `
    -QtPrefix $qtPrefix
powershell -NoProfile -File windows/scripts/Test-BatteryPrototype.ps1 `
    -QtPrefix $qtPrefix
```

The first command builds and runs the backend's `upower_status_test` with the
Microsoft linker and SDK `mt.exe`. It uses pure fake `SYSTEM_POWER_STATUS`
values, not a hardware read: proven absence (flag 128), unknown presence (flag
255), unknown percentage (255), failed-read stale clearing, state/time mapping
and the `onBattery` truth table. It also builds `device.cpp` with clang-cl,
which catches native projection regressions before integration.

The second command runs injected QML fixtures in Qt's offscreen `qml.exe`,
staging only the state object and fixtures. It constructs no native UPower
backend and covers disabled/initializing/unavailable/ready states, proven
absence versus failed or unknown reads, unknown percentage versus a real 0%,
charging-state gating, numeric/state/icon guards, null and stale devices,
unready/denied backends, the `onBattery` truth table and an introspection check
that the adapter exposes no write methods.

The third command snapshots native power state (active scheme, effective
overlay scheme, `GetSystemPowerStatus`, `Win32_Battery`) before and after,
runs the adapter fixtures, then disabled/read-only smoke on every measured
connected screen, then the original M1 bar/session regression and a full
[Test-AudioPrototype.ps1](../scripts/Test-AudioPrototype.ps1) re-run as the
shared-script regression gate. Each run records source/staged hashes,
runtime/build references, snapshots, logs and a PNG. It rejects QML
diagnostics. A workstation without a battery demonstrates the truthful proven
absence path natively; battery-present behavior, unknown native values and
failed reads stay fixture-validated until run on hardware that produces them.

Raw results are under
`windows/.local/build/battery-validation-<timestamp>/result.json`.

[Final acceptance](../validation/2026-10-25-m2-battery/README.md) records the
earlier revision's clean-source results and limits. The capability contract in
this README needs a new acceptance run and archive after the backend pin is
reviewed; this document does not extend that archive's claims.
