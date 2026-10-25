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
`isPercentageKnown` distinguishes `BATTERY_PERCENTAGE_UNKNOWN` (255) and
out-of-range values from an actual 0%. `UPower.onBatteryKnown` marks whether
Windows supplied a known AC source. Unknown AC state supplies neither a
discharging state nor a time-to-empty estimate.
A failed read clears the device's level, state, estimate, icon, path and model
instead of retaining the previous reading, and the adapter then reports
`observationAvailable=false` and `status="unavailable"` rather than proven
absence. A successful read that proves no battery reports `status="ready"`,
`absent=true`, no fake level and the original "No battery detected" state.
Energy/health telemetry stays unavailable, matching the backend's stubbed
values. See [backend PR #2](https://github.com/KldsSeeGhosts/caelestia-quickshell-windows/pull/2).

The battery adapter itself stays strictly read-only. It exposes no mutating
methods at all. The default ReadOnly mode never references `PowerProfiles`:
the original components' profile hooks are disabled by the host, the profile
selector does not render, its click handler is disabled, the degradation
warning does not activate, and profile text reports "Power profile
unavailable". No power scheme, overlay, or IdlePower setting is written.

## Power profiles (additive observation and write opt-ins)

The read-only slice also has an additive profile capability that is disabled
unless two further child-process opt-ins are set. `ReadOnly` keeps the original
behavior exactly.

- `CAELESTIA_WINDOWS_POWER_PROFILES=1` enables profile observation and shows
  the original selector read-only when a supported profile is verified. The host loads
  [NativePowerProfilesBackend.qml](../services/battery/NativePowerProfilesBackend.qml),
  a thin facade over the pinned `PowerProfiles` singleton.
  [PowerProfilesService.qml](../services/battery/PowerProfilesService.qml) is a
  pure QtObject importable and fixture-tested without Quickshell.
- `CAELESTIA_WINDOWS_POWER_PROFILE_WRITES=1` separately permits explicit
  writes. It has no effect without the observation opt-in. `-Smoke` always
  forces both the launcher variable and the host permission off, so no smoke
  run can select a profile.

Capability states are explicit: `unknown`, `observing` (a verified mapped
profile), and `unsupported` (backend failure). Write states are `idle`,
`pending`, `confirmed`, `rejected`, and `unconfirmed`. Only a matching
`profileWriteResult(requestedProfile, true, error)` confirms a write. The
reviewed backend emits success only after the native set succeeds and a
re-read maps to the requested profile. A failed result rejects the request
with its error. Property transitions never confirm a write. A missing result
expires as unconfirmed after the bounded timeout, including older backends
without that signal. Selecting the current verified profile sends no write,
starts no timeout, and stays idle without incrementing confirmed writes.

The original popout's injectable `selectProfile` hook defaults to the original
direct setter on Linux. The Windows host routes it through
`Battery.profiles.requestProfile()`, including no-op detection and result
handling. The original icons, layout, and motion are unchanged. The other
additive hooks (`profileStatusEnabled`, `profileControlsEnabled`,
`profileWritesEnabled`, and `availableProfiles`) retain upstream defaults;
unavailable entries use the existing disabled `StateLayer` styling.

### Backend compatibility

The pure [PowerProfilesBackend.qml](../services/battery/PowerProfilesBackend.qml)
facade accepts the native singleton or an injected fake. With the reviewed
backend `327cd09` on `windows/m2-power-profile-results`, it trusts only
`profileKnown === true`, clears the projected profile on an unknown GUID or
failed read, and forwards `lastError`. `rawOverlayGuid` and native notification
`observing` remain available for diagnostics. The backend publishes consistent
snapshots; failed notification registration reports `observing=false` and
uses a 10-second fallback refresh.

Available selection targets require `writeSupported === true`: PowerSaver and
Balanced are mapped, with Performance added only when `hasPerformanceProfile`
is true. This describes API support, not proof that a particular native write
will succeed. Result support is feature-detected from `profileWriteResult`.

The root dependency remains pinned to
`1401042969e4b7ab3cfb314fc76945ab081db3de`; neither the gitlink nor
`windows/sources.lock.json` is changed by this slice. That old backend exposes
no read validity, raw GUID, error, result, or write-support capability. Its
Balanced value can also mean an unknown overlay GUID, and its setter can
update a local property without verifying the effective overlay. Consequently,
**all old-pin profile values remain unknown**, including Balanced and
Performance; profile controls stay unavailable and the facade submits no
writes. A hard-coded legacy performance claim grants no available targets.
There is no latched or non-default-value read heuristic. Updating the pin and
validating the newer backend natively are separate work.

`IdlePower` settings remain out of scope and are never constructed or written.


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
default and never loads the native power backend, the profile backend or the
original UPower components. `ReadOnly` opts into the native UPower observation
(initial status read, 30-second poll and power notifications) with no
PowerProfiles reference. `Profiles` adds read-only PowerProfiles observation. A verified supported
profile renders the original selector with its write path disabled; the old
pin reports unknown and keeps profile controls unavailable.
`ProfileWrites` is the separate write opt-in for explicit human selection; it
is not exercised by the native smoke gate on this workstation. Every `-Smoke`
run forces writes off.

The battery opt-in is a child-process environment variable
`CAELESTIA_WINDOWS_BATTERY`; profile observation and writes add
`CAELESTIA_WINDOWS_POWER_PROFILES` and
`CAELESTIA_WINDOWS_POWER_PROFILE_WRITES`. The launcher sets all three
explicitly, preventing inherited flags from enabling a service in the M1
profile. The M1 profile's default behavior is preserved. This host uses its own
`battery-prototype-profile` and fresh source stage under ignored
`windows/.local/build`.

The original components gained localized Windows hooks, all defaulting to
upstream behavior: `profileStatusEnabled`/`profileControlsEnabled` for the
PowerProfiles read/write paths, `profileWritesEnabled` for a visible read-only
selector, `availableProfiles` for mapped-profile availability, and
`observationAvailable`/`percentageKnown` for the native UPower capability
fields. The host wires the profile hooks to the capability state, so the
selector only renders while a mapped profile is observed and individual
unmapped profiles use the existing disabled styling. The host wires the
observation hooks from the adapter, so a failed or unknown read renders
"Battery status unavailable" or "Battery level unknown" instead of a level,
and the status icon uses `battery_unknown` rather than a zero-level or profile
glyph. Every smoke asserts the truthful absent/unknown/profile glyph before
capture. The popout's `powerSourceKnown` hook follows the adapter's AC-source
validity, and `timeToFullSupported` is false because the backend does not
measure charge time. These hooks retain true defaults for upstream consumers.
An unknown source or unavailable charge-time estimate is labeled explicitly.
Unlike the audio host, the original UPower components are instantiated only in
an observation mode: they bind the native `UPower` singleton directly, so
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
staging only the pure state objects and fixtures. It constructs no native
UPower/PowerProfiles backend. The battery fixture covers
disabled/initializing/unavailable/ready states, proven absence versus failed or
unknown reads, unknown percentage versus a real 0%, charging-state gating,
numeric/state/icon guards, null and stale devices, unready/denied backends, the
`onBattery` truth table and an introspection check that the battery adapter
exposes no write methods. The profile fixture covers every capability state
(disabled, initializing, unsupported, unknown, observing), the mapped
availability set (including conservative old-pin behavior),
write refusal without the separate opt-in, result-only confirmation,
unconfirmed/timeout, native rejection, backend loss,
write-opt-in revocation, no-op selection, stale/unverified reads and the
bounded write timeout. It also exercises both native API shapes through the
pure facade, unknown GUIDs, failed-read cache invalidation, synchronous results,
and an injected selection hook.

The third command snapshots native power state (active scheme, effective
overlay scheme, `GetSystemPowerStatus`, `Win32_Battery`) before and after,
runs both fixture sets, then disabled/read-only/profiles smoke on every
measured connected screen, then the original M1 bar/session regression and a
full [Test-AudioPrototype.ps1](../scripts/Test-AudioPrototype.ps1) re-run as
the shared-script regression gate. No `ProfileWrites` native run is part of
this gate. Each run records source/staged hashes, runtime/build references,
snapshots, logs and a PNG. It rejects QML diagnostics. A workstation without a
battery demonstrates the truthful proven absence path natively; battery-present
behavior, unknown native values and failed reads stay fixture-validated until
run on hardware that produces them. Profiles mode observes the current
effective overlay read-only; it never selects a profile.
After stable snapshots and capture, each enabled smoke invokes the actual
Windows popout selection hook with an invalid target while writes are off.
The service must reject it without incrementing native submission attempts;
this verifies the routing without a native profile write.

For a focused gate limited to native ReadOnly and Profiles smoke, add
`-ReadOnlyProfilesOnly` to the third command. It retains fixtures and power/desktop
identity checks, runs both modes on every measured screen, and skips Disabled,
M1 and audio native runs.

Raw results are under
`windows/.local/build/battery-validation-<timestamp>/result.json`.

[Power-profile acceptance](../validation/2026-10-25-m2-power-profiles/README.md)
records clean `59cf7715`/backend `14010429`: 128 unchanged battery assertions,
96 profile assertions, native Disabled/ReadOnly/Profiles smoke at 150%/175%,
and unchanged base/overlay schemes. [Final read-only
acceptance](../validation/2026-10-25-m2-battery/README.md) retains the earlier
revision's clean-source results and limits. Native profile writes, native
denied writes, PowerSaver observation and battery-present hardware remain
untested.

The [review addendum](../validation/2026-10-25-m2-power-profiles/README.md#review-addendum)
supersedes the earlier heuristic observation and transition-confirmation claims.
