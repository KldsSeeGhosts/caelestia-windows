# Windows port handoff, 2026-10-25

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
