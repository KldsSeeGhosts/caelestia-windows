# Windows port handoff, 2026-10-25

## M2 continuation

M0/M1 are complete and PR #3 is merged. Current topic branch:
`windows/m2-battery-service`, based on merged main `0af60352`.
[PR #4](https://github.com/KldsSeeGhosts/caelestia-windows/pull/4) and backend
PR #1 track the audio integration; consult their linked merge state. Backend
GitHub CI could not start because GitHub reports an account billing/spending-
limit block. Local native checks pass; no remote CI pass is claimed. The
battery review corrections add explicit UPower observation validity in
[backend PR #2](https://github.com/KldsSeeGhosts/caelestia-quickshell-windows/pull/2).
The root gitlink and `windows/sources.lock.json` agree at pushed backend
`5d0a33d36b17cb41d658b4a4a699c56ae91d6b5e`; the PR remains open.
M2 implementation order so far:
ERM-495 is the complete [service source audit](audits/M2-SERVICES.md);
ERM-496 adds the core Audio adapter and original AudioPopout;
ERM-497 adds truthful native audio capability/errors;
ERM-499 adds the [read-only battery slice](battery-prototype/README.md).
ERM-495/496/497 are complete for the bounded audio slice. ERM-499 remains
open: the read-only battery subset does not complete its unknown-reading,
profile capability, separate write opt-in and denied-write acceptance gates.
ERM-498 (GSMTC media), the remaining ERM-499 work, ERM-500 through ERM-507
and ERM-508 (live audio control/denial/recovery) track remaining services.
M2 is not complete.

Clean root `96788c8a` passes 128 battery adapter assertions, 9 native
fake-status QtTest cases, disabled/read-only
UI runs at native 150%/175% (negative secondary origin) with truthful
no-battery rendering, unchanged base power scheme `381b4222` and effective
overlay scheme `ded574b5`, unchanged Explorer/KSG Shell PIDs, work areas and
taskbar flags, the existing M1 bar/session smoke regression and a full audio
harness re-run.
[Corrected evidence](validation/2026-10-25-m2-battery-review/README.md) records exact
sources, commands, hashes, native state comparisons, screenshots and limits.
This workstation has no battery, so battery-present behavior remains
fixture-validated only. Review fixes disable and assert the status-icon
profile hook, distinguish unknown charge/presence/source and failed reads,
clear stale values and label unsupported charge time. The 12 missing
historical build artifacts are tracked with their original hashes.
The earlier archive retains its recorded sources and limitations.

```powershell
$qtPrefix = "$env:LOCALAPPDATA\caelestia-dev\Qt\6.11.2\msvc2022_64"
powershell -NoProfile -File windows/scripts/Test-BatteryPrototype.ps1 `
    -QtPrefix $qtPrefix
powershell -NoProfile -File windows/scripts/Start-ShellPrototype.ps1 `
    -QtPrefix $qtPrefix -Battery -BatteryMode ReadOnly -Wait
```

The battery adapter defaults disabled and is strictly read-only: it exposes no
mutating methods, never references PowerProfiles, and the host instantiates
the original UPower components only after the read-only opt-in because they
bind `UPower` directly. `CAELESTIA_WINDOWS_BATTERY` is the only opt-in; there
is no interactive mode. The original
[BatteryStatus](../modules/bar/components/status/BatteryStatus.qml) and
[Battery](../modules/bar/popouts/Battery.qml) components gained
`profileStatusEnabled`/`profileControlsEnabled` hooks with upstream-preserving
defaults. The corrected host disables both original components' profile hooks
and wires observation/percentage/source validity. The original run omitted
the status-icon hook; the corrected native smoke covers both components.
No other services, global shortcuts, toasts or shell controllers
are enabled. The normal M1 entry point and the audio prototype remain
available. Do not claim the read-only gate validates battery-present
hardware, profile selection, IdlePower settings or the full M2 milestone.

The next M2 work is ERM-498: GSMTC media players. Preserve player
selection/metadata and the original transport UI, capability-gate unsupported
actions, and distinguish absent sessions from an unavailable backend. No
automatic playback, shortcuts, toasts or capture. Re-check the
[audit](audits/M2-SERVICES.md) candidate list before starting.

Backend pin `5d0a33d36b17cb41d658b4a4a699c56ae91d6b5e` preserves M1's hover fix
and adds Core Audio interface/state availability, initialization/control errors,
and observed default routing after partial role failures.
It also carries UPower read/presence/percentage and AC-source validity,
single-read projections and stale-value clearing from backend PR #2.
[Backend PR #1](https://github.com/KldsSeeGhosts/caelestia-quickshell-windows/pull/1)
holds the committed fork patch. Native fake-COM fixtures pass 16 QtTest cases;
actual hardware denial, hot removal and live writes remain unvalidated.
The root gitlink and sources.lock.json move together.

The standalone backend tests build from
`windows/deps/quickshell/src/windows/test` with Qt 6.11.2 and clang-cl 20.1.8.
Use `-DCMAKE_LINKER_TYPE=MSVC` and SDK `mt.exe` for this target. LLVM 20's
manifest merge produced invalid namespaced execution-level attributes for the
Qt-generated test manifest; no UAC/security changes were made.

## Previous M1 handoff and historical evidence

The remainder records the completed M1 revision and its validation limits.
Its pin, topic branch and next-work statements are historical; the M2 section
above owns current continuation instructions.

## Current milestone

M0 and the bounded M1 compatibility prototype are complete. ERM-489 through
ERM-494 are done. M2-M4 remain unstarted. The next work is Windows service
adaptation, not packaging or a full desktop takeover.

Read the [final acceptance record](validation/2026-10-25-m1-acceptance/README.md)
for exact evidence and limitations. Clean source `24229c9a` passes two
36-scenario native input matrices with transparency on and off, synthetic
100%/150%/175% rendering, and a secondary-origin native monitor cycle.
The input matrices transfer the same 900x620 window through primary 150% ->
secondary 175% at x=-3840 -> primary. They cover stationary hover, rapid
crossings, original bar pin/unpin and session drag, keyboard traversal,
Escape/focus return, outside-click pass-through, early app switching and
repeated open/close. Final runtime logs contain no QML warnings/errors.

The original ContentWindow/StyledWindow, Regions/Interactions, Bar/Clock/Power
and Session.Wrapper/Content remain in use, including blob surfaces, motion,
fonts and icons. Other panels and services are explicit unavailable adapters.
The isolated session adapter consumes commands without executing them.
Drawers/Exclusions and Taskbar/Tiling controllers are not instantiated.

## Sources and review

The topic branch is `windows/m1-bar-drawer`; [PR #3](https://github.com/KldsSeeGhosts/caelestia-windows/pull/3)
contains the M1 work. `origin` is the private Caelestia Windows repository;
`upstream` is original Caelestia. Use `gh -R KldsSeeGhosts/caelestia-windows`.
Preserve newer edits and use topic branches.

The backend is now pinned to `84604c258da92a004b46d62a89718ae615840b98` in the
private `KldsSeeGhosts/caelestia-quickshell-windows` fork. The gitlink,
`.gitmodules` and sources.lock.json agree. Its history retains audited baseline
`e8ae0ef1`; the cumulative patch changes only input_mask.cpp. It defers a guarded
local Qt enter when native input routing becomes interactive, and delivers
leave on pass-through. This resolves the missed stationary hover handoff after
rapid boundaries. Original Interactions also handles unchanged-coordinate
entry. Do not advance the pin without review. See the
[backend audit addendum](audits/M1-BACKEND-API.md#focus-dismissal-and-return).

The clean native build record is `9bb447aa` with Qt 6.11.2 and clang-cl 20.1.8.
Later code commits affect only tests and documentation. The final staged source
manifests identify runtime bytes at `24229c9a`. Earlier validation archives keep
their own older source revisions and incomplete status.

## Resume on this workstation

Read AGENTS.md, [README.md](README.md), [ROADMAP.md](ROADMAP.md),
[NATIVE-BUILD.md](NATIVE-BUILD.md), and the prototype README before widening the
component graph. The developer toolchain is under
`$env:LOCALAPPDATA\caelestia-dev`. Build with the documented native script;
its Visual Studio/Qt PATH changes are process-local.

```powershell
$devRoot = Join-Path $env:LOCALAPPDATA 'caelestia-dev'
powershell -NoProfile -File windows/scripts/Build-Prototype.ps1 `
    -QtPrefix "$devRoot\Qt\6.11.2\msvc2022_64" `
    -LlvmBin "$devRoot\clang+llvm-20.1.8-x86_64-pc-windows-msvc\bin" `
    -Cli11Include "$devRoot\deps\CLI11-2.5.0\include" `
    -ToolsBin "$devRoot\tools\Scripts"
powershell -NoProfile -File windows/scripts/Start-ShellPrototype.ps1 `
    -QtPrefix "$devRoot\Qt\6.11.2\msvc2022_64" -Wait
```

`-Smoke` performs bounded no-input rendering. `-MonitorCycle -Smoke` transfers
out/back from the selected ScreenIndex. Native/1/1.5/1.75 scaling is supported.
An absent screen fails explicitly. Exact-instance IPC provides state, capture,
moveToScreen and quit; never broadcast to another Quickshell session.
`-TraceInput` enables native mask and QML hover tracing.

For the repeatable native input matrix, keep the pointer/keyboard idle and use
`Test-ShellPrototypeInput.ps1 -QtPrefix <path> -AllowDesktopInput`.
Add `-TestTransparencyOff` for startup under the real system preference;
Windows UISettings independently confirms it and finally restores it.
The runner owns only its prototype/fixture and restores pointer/focus.
It uses SendInput through Windows routing, not physical-hardware observations.
See the [prototype instructions](shell-prototype/README.md).
The original session vimKeybinds option is enabled in this isolated profile
for Tab traversal. Unsupported actions remain consumed.

## Desktop and remaining boundaries

The final runs preserve Explorer PID 9872 and KSG Shell PID 32044, work areas,
taskbar flags and ordinary configuration. No prototype or fixture remains.
The normal transparency preference is restored to 1 with advanced effects true.

A rejected preliminary test broadcast a live desktop-wide settings notification
and exposed an existing KSG Shell RefCell panic in app_bar.rs:101. Its PID 16436
exited. The unchanged installed shell was restored as PID 32044, with original
work areas and user application sessions preserved. This separate KSG defect
was not fixed here. Its evidence is archived. The final test establishes
prototype startup with transparency off without that unrelated desktop-wide
broadcast; live global reconfiguration of other shells is not certified.

Keep one active tiler. Desktop takeover, taskbar changes, autostart and tiling
remain opt-in. The backend still performs normal native-window support,
input-mask bookkeeping, stale-AppBar startup cleanup and Quickshell instance
bookkeeping. Do not claim zero global bookkeeping.

The palette remains fixed and backend blur is disabled. Fonts are process-local,
with provenance/licenses under windows/assets. Dynamic themes, actual Windows
services, hardware denial/unavailability, full shell panels, installation,
sleep/wake and packaging belong to later milestones. Inherited Linux/release
workflows remain disabled. Linux was not rebuilt in this session.
