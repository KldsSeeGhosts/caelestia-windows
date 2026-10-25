# M2 read-only battery acceptance, 2026-10-25

ERM-499's bounded slice is implemented: a read-only UPower adapter, the
original battery status icon and popout content with bounded PowerProfiles
hooks, and a separate opt-in host. This archive validates native **read-only
observation** on a desktop **without a battery**, disabled construction,
truthful absence rendering and unchanged native power state. It does not
complete M2 and does not validate a battery-present system.

The original run preceded [root PR #5](https://github.com/KldsSeeGhosts/caelestia-windows/pull/5).
At that recorded revision, the backend gitlink and
`windows/sources.lock.json` were untouched at the audio slice's pin, and no
backend change was made. Inherited GitHub Actions remain disabled at
repository level during bootstrap, so there is no remote CI pass to report.

## Sources and runtime

- Root source: clean `41cf6aae28eb06baf6c87fcffbbdd84fce28223b` on topic
  branch `windows/m2-battery-service` (implementation commit `41cf6aae`,
  branched from merged main `0af60352`).
- Backend: unchanged `8c71bdb8116dffeb274edb31c3803e1c28dbb270`; gitlink and
  `windows/sources.lock.json` untouched.
- Original Caelestia baseline: `2e1c51fa76d94457624b642c678218970aa2517a`.
- Windows 11 `10.0.26300.0`, Qt 6.11.2 `msvc2022_64`, clang-cl 20.1.8,
  MSVC tools 14.44.35207, Windows SDK 10.0.26100.0, CMake 4.4.4 and Ninja
  1.13.2. Exact [build record](build/build.json) and process-local
  [environment report](build/environment.json) (0 warnings) with
  configure/build/install commands and logs are archived.
- This is an **incremental** build at the clean implementation revision, not a
  from-scratch build. No C++ sources changed for this slice; the build reused
  unchanged backend and portable plugin objects.
- Workstation hardware observed by the run: a desktop with **no battery**
  (`GetSystemPowerStatus` BatteryFlag 128, AC online, empty `Win32_Battery`
  list), two monitors at 150% and 175% (negative secondary origin).

## Commands and results

From the repository root in native PowerShell at clean `41cf6aae`:

```powershell
$devRoot = "$env:LOCALAPPDATA\caelestia-dev"
$qtPrefix = "$devRoot\Qt\6.11.2\msvc2022_64"
powershell -NoProfile -File windows/scripts/Build-Prototype.ps1 `
    -QtPrefix $qtPrefix `
    -LlvmBin "$devRoot\clang+llvm-20.1.8-x86_64-pc-windows-msvc\bin" `
    -Cli11Include "$devRoot\deps\CLI11-2.5.0\include" `
    -ToolsBin "$devRoot\tools\Scripts"
powershell -NoProfile -File windows/scripts/Test-BatteryPrototype.ps1 `
    -QtPrefix $qtPrefix
```

The final [matrix](matrix.json) passes all seven records at clean `41cf6aae`
with `sourceDirty=false`. Each UI run has its own result JSON, stdout/stderr,
staged source manifest and PNG; runtime diagnostics fail acceptance and all
final UI logs are clean. Runtime executable hashes and measurement-source
hashes are recorded.

| Check | Observed result | Evidence |
| --- | --- | --- |
| Injected adapter states | 94 assertions pass in offscreen Qt `qml.exe`; no native UPower backend staged | [fixture result](fixture/result.json), [log](fixture/stderr.log), [staged sources](fixture/BatteryService.qml) |
| Disabled, primary | Native DPR 1.5; status `disabled`, backend not constructed, original UPower components not instantiated | [result](battery-disabled-screen0/result.json), [capture](battery-disabled-screen0/capture.png) |
| Read-only, primary | Native DPR 1.5; status `ready`, truthful absence: `hasBattery=false`, percentage 0, "No battery detected" | [result](battery-readonly-screen0/result.json), [capture](battery-readonly-screen0/capture.png) |
| Disabled, secondary | Native DPR 1.75 at x=-3840; backend not constructed | [result](battery-disabled-screen1/result.json), [capture](battery-disabled-screen1/capture.png) |
| Read-only, secondary | Native DPR 1.75 at x=-3840; same truthful absence state | [result](battery-readonly-screen1/result.json), [capture](battery-readonly-screen1/capture.png) |
| Existing M1 regression | Original bar/session rendering/open/close smoke passes with the shared launcher | [result](m1-regression/result.json), [capture](m1-regression/capture.png) |
| Audio slice regression | Full `Test-AudioPrototype.ps1` re-run passes (6 runs: 238 adapter assertions, four audio UI runs, M1 smoke) | [result](audio-regression/result.json) |

The adapter fixtures cover disabled/initializing/unavailable/ready states,
truthful no-battery absence (failed native reads map to `isPresent=false` and
the adapter gates every device projection on presence), the upstream
charging-state gating (`Charging`/`FullyCharged`/`PendingCharge`), percentage
range/NaN/type guards, state/time/icon guards, non-battery-type devices,
battery arrival/withdrawal, replacement device objects, unready/denied
backends, the `onBattery` truth table and an introspection check that no
write-method name exists on the adapter. The smoke runs additionally assert
the percentage range, the no-fake-state absence invariants, the charging
gate, the battery gating identity, and that disabled mode constructed neither
the backend nor the original components.

The read-only capture shows the original popout content rendering
"No battery detected", "Power profile unavailable" and no profile selector.
Review of PR #5 found that the separate status icon retained its default
`profileStatusEnabled=true`, read PowerProfiles and rendered the performance
rocket. The smoke asserted only the popout's hooks, so it did not catch this
error. These captures do not establish that PowerProfiles remained unloaded.
The original machine-generated evidence is retained unchanged; a corrected
run must identify its own source revision and results.

The original native contract also maps an unknown percentage to zero and
failed status reads to absence. The adapter fixtures do not establish that
the original UI distinguishes those states. ERM-499 remains incomplete until
the unknown/unavailable observations and the remaining profile capability,
separate write opt-in and denied-write gates are addressed.

## Isolation and unchanged native state

Read-only power snapshots [before](power-before.json) and
[after](power-after.json) are identity-equal: base power scheme
`381b4222-f694-41f0-9685-ff5bb260df2e` ("Balanced"), effective overlay scheme
`ded574b5-45a0-4f42-8737-46345c09c238` ("Best performance"), AC online
(`ACLineStatus=1`), battery absent, `BatteryLifePercent=255`. The overlay
scheme is the write target of the backend's PowerProfiles profile selection;
the base scheme is the write target of plan changes. Both unchanged across
every run, including the full audio harness re-run. The measurement uses only
`GetSystemPowerStatus`, `PowerGetEffectiveOverlayScheme`,
`powercfg /getactivescheme` and a `Win32_Battery` CIM query; it writes
nothing. Snapshot timestamps show the run took under two minutes, so the
equality is a same-session observation, not a claim about changes outside it.

Desktop snapshots [before](desktop-before.json) and
[after](desktop-after.json) preserve Explorer PID 9252, KSG Shell PID 24108,
both physical monitor/work rectangles and taskbar flags `1`. No prototype
remains. No pointer/keyboard, power, display, autostart, taskbar or tiler
setting was changed.

The test uses fresh stages and a dedicated `battery-prototype-profile`. The
[isolated configuration](isolated-shell.json) has all session commands empty
and other panels disabled. Source manifests distinguish original QML from the
host/adapter: staged originals are `modules/bar/components/status/BatteryStatus.qml`,
`modules/bar/popouts/Battery.qml`, `components/AnchorAnim.qml` and
`utils/Icons.qml`, plus the three adapter files under `services/`. The
`utils/Icons.qml` import of `Quickshell.Services.Notifications` provides only
the urgency enum used by unrelated helpers; importing the module constructs no
`NotificationServer` and claims no session mutex. Fonts and licenses retain
the M1 staging/provenance. The backend still performs normal own-window
virtual-desktop support, instance bookkeeping and stale-AppBar startup
cleanup, and the UPower backend registers power notifications and polls every
30 seconds while enabled. This is not a zero-global-effect claim.

## Failures resolved and limits

Development-only failures, all resolved before the archived clean run and all
reproduced only in unarchived earlier runs:

- The fixture's typed fake-device fields rejected invalid values at
  assignment, so the numeric guards were untestable; the fake device fields
  are now untyped and the adapter performs all rejection.
- The first adapter revision read device projections without a presence gate,
  so a withdrawn device could report its stale level; projections are now
  gated on `present`, matching the backend's zero-on-absence refresh.
- The host initially referenced the popout's inner component id from outside
  its loader component, producing a `ReferenceError` QML warning; the binding
  now goes through the loader item.
- The orchestrator's assertion helper initially declared a `[bool]`
  parameter while a measurement string was passed; the parameter is untyped.

Not validated here:

- **A battery-present system.** This workstation has no battery, so the
  native read-only runs exercise only the truthful absence path. Charging,
  discharging, time-remaining estimates, `onBattery=true` and icon updates on
  real hardware are fixture-validated only.
- Real overlay/profile writes, IdlePower settings, power-plan changes,
  sleep/wake, low-battery behavior and the UI interactions (clicking profile
  buttons is disabled and hidden in this slice).
- Same-window monitor transfer or a fresh M1 input/transparency matrix; M1's
  earlier native input evidence remains revision-specific.
- Windows access denial around `GetSystemPowerStatus` (the API's failure path
  maps to absence by backend contract, exercised via fixtures), hot dock
  transitions and notification-driven refresh latency beyond the 30-second
  backend poll.
- Cava/beat or other audio-visualizer concerns, other Windows services, full
  shell, tiling, packaging and Linux builds.

The adapter reports no initialization failure flag because the pinned native
UPower singleton exposes none; construction completing means the initial
synchronous status read happened, and a failed read is reported as absence,
not as an error. `hasBattery` follows upstream's `isLaptopBattery` display
gating; upstream's `isLaptopBatteryPresent` is not referenced anywhere.

Machine-generated evidence is copied byte-for-byte. Local `.gitattributes`
prevents line-ending/whitespace rewriting. `artifacts.sha256.json` identifies
the archived evidence bytes. Original absolute paths in raw logs identify this
workstation; this README links to their portable archived copies.
