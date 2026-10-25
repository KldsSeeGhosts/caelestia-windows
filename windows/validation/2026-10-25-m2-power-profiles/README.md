# M2 power profile capability and separated writes, 2026-10-25

This run validates the additive PowerProfiles capability in ERM-499's battery
slice. It implements truthful profile observation, read-only profile UI and a
separate write opt-in on top of the read-only battery slice. It does not close
the native write, native denial, PowerSaver-observation or battery-present
hardware gates.

## Recorded sources and environment

- Clean root `59cf771519826413e2cc504d3d6cdbf16defb57d` (`59cf7715`):
  implementation `20ae8233`, acceptance scaffolding `7712440a`, documentation
  clarification `59cf7715`.
- Clean pinned backend `1401042969e4b7ab3cfb314fc76945ab081db3de`
  (`14010429`). Gitlink and [source manifest](../../sources.lock.json) agree; no
  backend change is claimed.
- Shared incremental native build
  `D:\AiStack\caelestia-windows\windows\.local\build`, built at root
  `d9cdcf9a`/backend `14010429`; it was not rebuilt or deleted. The change is
  QML/PowerShell only, and every staged run records its source hashes in
  `sources.json`.
- Windows 11 `10.0.26300.0`, Qt 6.11.2, clang-cl 20.1.8, MSVC tools
  14.44.35207, Windows SDK 10.0.26100.0, CMake 4.4.4, Ninja 1.13.2.
- Hardware: no battery; primary 3840x2160 at 150%, secondary x=-3840 at 175%.
  There is no battery-present hardware claim.

## Implemented behavior

`windows/services/battery/PowerProfilesService.qml` is a pure QtObject with no
Quickshell/native import. `NativePowerProfilesBackend.qml` is the thin facade
over the pinned `PowerProfiles` singleton, loaded only after the observation
opt-in. The capability states are `unknown`, `observing`, `unsupported`,
`write-pending`, `write-confirmed` and `write-unconfirmed`; the mapped
`availableProfiles` set is exposed separately.

- `CAELESTIA_WINDOWS_BATTERY=1` remains the read-only battery opt-in and never
  references PowerProfiles.
- `CAELESTIA_WINDOWS_POWER_PROFILES=1` adds profile observation and the
  original selector, read-only. `-BatteryMode Profiles` sets it.
- `CAELESTIA_WINDOWS_POWER_PROFILE_WRITES=1` separately permits explicit
  writes. `-BatteryMode ProfileWrites` sets it. `-Smoke` forces it off in both
  the launcher and the host.
- The original components wire `profileStatusEnabled`/`profileControlsEnabled`
  to the observed capability. A read-only selector is kept visible with a new
  `profileWritesEnabled` hook; mapped-profile availability uses
  `availableProfiles` and the existing disabled `StateLayer` styling. Upstream
  defaults are unchanged.
- The available set comes from the explicit overlay GUID mapping, not from the
  backend's hard-coded `hasPerformanceProfile`. Performance is mappable but its
  platform acceptance is unverified until an observed write.
- The facade verifies a non-default Balanced/Performance read and reports
  PowerSaver as unknown, because the pinned backend has no read-success field.
  A write is confirmed only from an observed overlay-mapped transition within
  the bounded timeout.

Backend gaps and the proposed fork fix outline are recorded in
[the battery prototype README](../../battery-prototype/README.md#pinned-backend-gaps):
hard-coded performance availability, log-only notification/read/write failures,
no read-success or write-result property, notification-only refresh, and the
PowerSaver/read-failure ambiguity.

## Results

| Check | Result | Evidence |
| --- | --- | --- |
| Existing battery fixture | 128 assertions, unchanged | [result](fixture/result.json), [battery log](fixture/battery.stdout.log) |
| New profile fixture | 96 assertions | [result](fixture/result.json), [profile log](fixture/profiles.stdout.log) |
| Disabled at 150% and 175% | Pass; no battery/profile backend or original component | [primary](battery-disabled-screen0/result.json), [secondary](battery-disabled-screen1/result.json) |
| Read-only at 150% and 175% | Pass; profiles disabled, no PowerProfiles reference | [primary](battery-readonly-screen0/result.json), [secondary](battery-readonly-screen1/result.json) |
| Profiles at 150% and 175% | Pass; observed Performance read-only, mapped set `[0,1,2]`, writes idle and off, rocket glyph | [primary](battery-profiles-screen0/result.json), [capture](battery-profiles-screen0/capture.png), [secondary](battery-profiles-screen1/result.json), [capture](battery-profiles-screen1/capture.png) |
| Original M1 smoke | Pass | [result](m1-regression/result.json) |
| Full audio regression harness | Pass; 238 assertions, four native audio smokes and M1 smoke | [matrix](audio-regression/matrix.json) |
| Media service fixture re-run | Pass; 148 assertions, no native imports or diagnostics | [result](media-service/result.json) |

The [battery matrix](matrix.json) records the clean source and 9 runs. The
fixture covers every capability state, mapped-set sanitation, the ignored
performance claim, writes refused without the separate opt-in, pending and
confirmed writes, an unrelated overlay transition, bounded timeout failure,
native rejection, backend loss, write-opt-in revocation, no-op selection,
stale/unverified reads and disabling. Native Profiles smoke observed
`Performance` with `writeState=idle`, `profileWritesRequested=false` and
`profileWritesEnabled=false` on both screens.

One earlier clean attempt failed only the desktop-process identity check; its
power identity was unchanged and no `qs` process remains in either snapshot. A
quiet rerun at `59cf7715` passed; the failed attempt is not evidence.

## Native state preservation

[Power before](power-before.json) and [after](power-after.json) are
identity-equal: base scheme `381b4222-f694-41f0-9685-ff5bb260df2e` (Balanced),
effective overlay `ded574b5-45a0-4f42-8737-46345c09c238` (Best performance),
AC online, battery absent and raw unknown charge 255. Profiles mode constructs
the PowerProfiles singleton and registers its read-only effective-mode
notification, but the unchanged base/overlay prove no profile write occurred.

[Desktop before](desktop-before.json) and [after](desktop-after.json) preserve
Explorer PID 9252, KSG Shell PID 24108, both monitor/work rectangles and
taskbar flags (auto-hide on, always-on-top off). No pointer or keyboard input,
power write, taskbar change, tiling, autostart or shell takeover was performed.
`profileWritesEnabled` false and the smoke assertions prevent a staged
selection; no `ProfileWrites` native run was made.

## Commands

From the repository root in native PowerShell:

```powershell
$qtPrefix = "$env:LOCALAPPDATA\caelestia-dev\Qt\6.11.2\msvc2022_64"
$buildRoot = 'D:\AiStack\caelestia-windows\windows\.local\build'
powershell -NoProfile -File windows/scripts/Test-BatteryService.ps1 `
    -QtPrefix $qtPrefix -BuildRoot $buildRoot
powershell -NoProfile -File windows/scripts/Test-BatteryPrototype.ps1 `
    -QtPrefix $qtPrefix -BuildRoot $buildRoot
powershell -NoProfile -File windows/scripts/Test-MediaService.ps1 `
    -QtPrefix $qtPrefix -BuildRoot $buildRoot
```

The individual smoke path used by the harness is:

```powershell
powershell -NoProfile -File windows/scripts/Start-ShellPrototype.ps1 `
    -QtPrefix $qtPrefix -BuildRoot $buildRoot `
    -Battery -BatteryMode Profiles -Smoke -ScaleFactor native -ScreenIndex 0
```

Raw results are under
`windows/.local/build/battery-validation-20261025-182102-475/result.json`.
The archive was produced by [archive.ps1](archive.ps1);
[artifacts.sha256.json](artifacts.sha256.json) covers all 92 raw evidence
artifacts. The build record is [build/build.json](build/build.json) and the
isolated shell profile is [isolated-shell.json](isolated-shell.json). Raw
evidence retains original absolute workstation paths.

## Limits and untested items

- **No native profile write:** `ProfileWrites` was never run natively. Native
  write-confirmed, write-unconfirmed and denied-write outcomes remain untested;
  the fixture covers the implemented contract only.
- **PowerSaver observation:** the pinned backend cannot distinguish a real
  PowerSaver overlay from a failed read. The facade reports it as `unknown`;
  only Balanced/Performance observation was exercised natively (Performance).
- **Read verification is heuristic:** a non-default value proves the read
  because this host does not write before observation. This does not replace the
  backend read-success field proposed for the fork.
- **Write confirmation is an observed backend property transition**, not an
  independent `PowerGetEffectiveOverlayScheme` re-read. The backend publishes no
  write result.
- **Battery-present hardware:** aggregate AC/battery observation, unknown native
  values and failed reads remain fixture-validated. This workstation has no
  battery.
- **Performance support:** only the explicit GUID mapping is established;
  platform acceptance was not tested because it requires a write.
- **Media regression:** the `Test-MediaService.ps1` re-run is a fixture gate,
  not a new media session or UI acceptance.
- No Linux build or remote CI pass is claimed; backend CI remains subject to the
  account billing/spending-limit block. IdlePower settings remain out of scope.
