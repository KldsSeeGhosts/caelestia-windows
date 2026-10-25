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

## Review addendum

The review fixes were validated at clean root
`18523825ee58c64307c65723620a7d2bc3ff8672`, following reviewed root `a0b6317b`.
This addendum supersedes the heuristic-read and property-transition
confirmation claims above. The root gitlink and `windows/sources.lock.json`
remain unchanged at backend `14010429`. The reviewed reference was backend
`327cd09` (`windows/m2-power-profile-results`), inspected without modifying
either backend checkout. The shared native build was not rebuilt and still
uses the **old backend pin**.

- **Selector lifecycle:** the original popout now has an injectable
  `selectProfile` hook, defaulting to its original direct setter on Linux.
  The Windows host routes selections through `Battery.profiles.requestProfile`.
  Selecting the current verified profile is idle, sends no write, starts no
  timer and does not count as a confirmed write. Original icons, layout and
  transitions are unchanged.
- **Write results:** a matching `profileWriteResult(requested, true, error)` is
  the only confirmation path. Matching failure results are rejected with the
  supplied error. Matching property changes alone remain pending, and missing
  results expire as unconfirmed. Result-less backend submissions cannot
  confirm. Synchronous results during the setter are handled.
- **Truthful observation:** the injectable pure facade requires
  `profileKnown === true`, invalidates projected values after unknown/failed
  reads and reports `lastError`. Available targets require `writeSupported`,
  with Performance additionally requiring `hasPerformanceProfile`.
  Old-pin members are feature-detected; every legacy profile value remains
  unknown, with an empty available set and no native submissions.

The original battery fixture still passes **128 assertions**. The profile
fixture passes **132 assertions**, up from 96, covering new and legacy backend
shapes, optimistic setters, result success/failure, mismatched and late results,
timeout, no-op selection, injected selection routing, unknown GUIDs, failed-read
cache invalidation and capability-derived availability.
Existing expectations changed where required by the fix: property transitions
now need an explicit result; current-profile no-ops stay idle without increasing
confirmed writes; refused native submissions are rejected rather than
unconfirmed. There were no QML diagnostics in the passing fixture runs.

The [focused harness matrix](review/matrix.json) passes five records: both
fixtures plus four native smoke runs, ReadOnly and Profiles on each screen
(150% primary and 175% negative-origin secondary). The actual Windows popout
hook was invoked after each capture with an invalid target while writes were
off. All four runs logged `CAELESTIA_BATTERY_SELECTOR_PASS` and verified service
rejection with no native submission attempt. This checks the host wiring
without a profile write. Profiles snapshots correctly report `unknown`,
`profile=-1`, `availableProfiles=[]`, controls unavailable, and writes idle/off
with the old runtime. ReadOnly still leaves PowerProfiles unloaded.

[Power before](review/power-before.json) and
[after](review/power-after.json) are identity-equal: base scheme
`381b4222-f694-41f0-9685-ff5bb260df2e` (Balanced), overlay
`ded574b5-45a0-4f42-8737-46345c09c238` (Best performance), AC online, battery
absent and raw charge 255. A separate full-task before/after comparison also
passed. Desktop identity (shell processes, work areas and taskbar flags) passed.
No native ProfileWrites run, power profile/overlay/plan change, input takeover
or backend modification occurred.

Commands used from the specified worktree in native PowerShell:

```powershell
$qtPrefix = "$env:LOCALAPPDATA\caelestia-dev\Qt\6.11.2\msvc2022_64"
$buildRoot = 'D:\AiStack\caelestia-windows\windows\.local\build'
powershell -NoProfile -File windows/scripts/Test-BatteryService.ps1 `
    -QtPrefix $qtPrefix -BuildRoot $buildRoot
powershell -NoProfile -File windows/scripts/Test-BatteryPrototype.ps1 `
    -QtPrefix $qtPrefix -BuildRoot $buildRoot -ReadOnlyProfilesOnly
powershell -NoProfile -File windows/scripts/Test-Environment.ps1 -Json
```

The focused option was added to honor the review's native ReadOnly/Profiles
restriction. It skips Disabled, M1 and audio native runs, preserving the full
harness defaults for other sessions. The environment report matched the
unchanged pin but reported cmake, ninja, compiler and Qt tools missing from the
ordinary process PATH; it is not a new build claim. The explicit Qt prefix and
existing shared build supplied the fixture/smoke runtimes.

Raw final results:
`windows/.local/build/battery-validation-20261025-191123-280/result.json`.
[Archived source hashes, logs, snapshots and captures](review/artifacts.sha256.json)
cover 37 artifacts. The standalone fixture also passed from clean `18523825`
at `battery-fixture-20261025-191122-270`.

**Untested:** native operation against backend `327cd09`, native successful or
denied profile writes and verification, real battery hardware, interactive
selector clicks/motion, and Linux runtime behavior. The newer backend shape
and result forwarding are fixture-validated only. Notification registration
failure/fallback behavior was reviewed in the backend source, not rerun here.
The full Disabled/M1/audio regression harness was intentionally not run in this
review. Earlier acceptance results retain their original scope.

## Final review note

The final review of `11639abd` found no blocking defects. Its one minor
finding: results carry only the target profile, so a late success for an
expired request could confirm a newer request for the same profile. The
service now attributes a late result to the oldest unanswered expired request
for that target and never lets it confirm a newer one. The fixture covers the
expire-retry-late-result ordering: 128 battery and 137 profile assertions pass
(`Test-BatteryService.ps1`, dirty follow-up tree). No native power write was
made.
