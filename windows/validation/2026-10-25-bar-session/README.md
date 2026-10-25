# Native bar and session validation, 2026-10-25

The original bar and session drawer load and render through the isolated
Windows platform boundaries. This satisfies the loading slice in ERM-492.
M1 remains open for input and lifecycle coverage, including a hover entry
case observed below. No complete shell or Windows service integration is claimed.

## Sources and runtime

- Implementation: `b9f07e34b74ed200aa262bc1e41d9bf54467d38a`.
- Final startup handling: `b534ae2690f90e7252c165b4df042ad94a622ae2`.
  That patch changes only QML/launcher startup handling.
- Backend gitlink and lock: `e8ae0ef124b1c14b547c80d00422d2ffbd423d81`,
  unchanged and clean.
- Native build: [build.json](build.json), clean `b9f07e34`, Qt 6.11.2,
  clang-cl 20.1.8, SDK 10.0.26100.0, MSVC tools 14.44.35207,
  CMake 4.4.4, Ninja 1.13.2. Windows reports build 26300.
- Rendering: Qt Quick Direct3D 11 (`GraphicsInfo.api=4`).
- Native helper DLL hashes: [windows-plugin-sha256.json](windows-plugin-sha256.json).
- Configuration: [profile-shell.json](profile-shell.json).
  The staged source manifests record each copied original and adapter hash.

The entry point loads original `ContentWindow`, `StyledWindow`, `Regions`,
`Interactions`, `Bar`, `BarWrapper`, `Clock`, `Power`, and session
`Wrapper`/`Content`. Original blob surfaces, deformation, fonts and motion
are retained. The native host is bounded to 900 by 620 logical pixels,
80 pixels from the monitor's top/left. It omits `Drawers`/`Exclusions`.

Required body font, Rubik and Material Symbols are process-local; their source
pins and licenses are recorded in [assets/README.md](../../assets/README.md).
The palette is fixed and opaque. Disabled bar entries, other panels, compositor
operations and session actions use explicit unavailable adapters. Unknown
session commands are consumed without execution, including the smoke probe.

## Rendering and startup results

| Check | Observed result | Record |
| --- | --- | --- |
| Synthetic 100% | Pass, DPR 1, original bar/session open and close | [100.json](100.json), [image](100.png) |
| Synthetic 150% | Pass, DPR 1.5 | [150.json](150.json), [image](150.png) |
| Synthetic 175% | Pass, DPR 1.75 | [175.json](175.json), [image](175.png) |
| Native same-window transfer | Pass: 150% primary, 175% secondary at x=-3840, then 150% primary | [native-cycle.json](native-cycle.json), [log](native-cycle.stdout.log) |
| Missing screen 15 | Expected exit 1 before rendering, no runtime warnings | [assertion](invalid-screen-assertion.json), [log](invalid-screen.stdout.log) |
| Initial transfer implementation | Failed correctly on binding-loop warnings, despite producing captures | [failed result](failed-transfer.json), [log](failed-transfer.stdout.log) |

Synthetic results are from clean `b9f07e34`. The final native cycle and missing
screen result are from clean `b534ae26`, using the same native build.
The native cycle captured the [initial primary](native-cycle.png),
[175% negative-origin display](native-175-negative-origin.png), and
[return to the primary](native-150-return.png). Each placement retained
900 by 620 logical dimensions; the screenshots were inspected.
Passing runs contain no runtime warnings/errors.

Smoke disables native input, focus grabs and keyboard activation through
`interactionEnabled=false`. It programmatically opens/closes the original
content and verifies dimensions, fonts, DPR and the unavailable action
boundary. It does not establish pointer routing or keyboard behavior.
The transfer uses one native window; it is not three independent launches.

The first transfer exposed right-margin binding loops. The final host uses
left/top anchoring with explicit dimensions. The missing-screen negative
test also exposed an early engine-exit signal without a connected receiver.
The final startup defers exit until Quickshell attaches its handler and
disables the rendering timer for an invalid selection.

## Real input observations

These are earlier working-tree observations at native 150%, with cua-driver
0.37.0 and a dedicated external WinForms fixture. They are not a final clean
commit input certification. [manual-input.json](manual-input.json) records
the dirty source state; [manual-input.sources.json](manual-input.sources.json)
and [manual-source-comparison.json](manual-source-comparison.json) identify
the bytes. All 47 staged files other than the later-revised host entry point
match the final checkout. The original component and adapter files match.

- Continuous pointer movement into the left edge opened the bar to width 60;
  leaving closed it to width 10. See [hover capture](native-hover.png).
- The original Power control opened the original session content.
- Escape closed it. Direct `GetForegroundWindow` observations showed
  prototype PID 20428 before dismissal and fixture PID 2880 afterward;
  the helper reported `restore-succeeded`.
- A click through the transparent center incremented the fixture click count
  from 1 to 2, dismissed the session, and reported
  `restore-skipped-foreground-changed`. The outside-click target kept focus.
- One pointer jump into the closed edge did **not** open the bar while
  stationary; subsequent movement did. This needs a controlled reproduction
  and investigation. Native input-mask handoff timing is a hypothesis,
  not an established cause.

See [input-observations.json](input-observations.json),
[outside-click state](m1-outside-click.json),
[fixture events](m1-input-target.jsonl), and
[runtime log](manual-input.stdout.log). Cua reported a foreground mismatch
on the outside click because the click landed on the underlying fixture
rather than its expected panel HWND. The fixture counter and exact-instance
IPC state independently verified the intended result. Driver success is not
claimed for that call.

A Down key was posted but button traversal was not independently verified.
The new 550 ms external-foreground reconciliation was reviewed statically,
but its early app-switch scenario was not recorded.

## Desktop lifecycle and limits

[Before](m1-desktop-before.json), [after](m1-desktop-after.json), and
[comparison](m1-lifecycle.json) show identical monitor/work-area rectangles
and taskbar state flags. Existing `ksg-shell` PID 16436 remained active.
The prototype and fixture exited; no `qs` process remained at the comparison.
Existing application sessions were preserved. No taskbar, tiler, autostart,
authentication, display-scale or ordinary Caelestia configuration was changed.

The backend still initializes support for its own panel window, routes
input masks, performs shared stale-AppBar startup cleanup, and writes its
normal Quickshell instance bookkeeping. This is not a zero-bookkeeping claim.

Windows `EnableTransparency` was 1. The fixed opaque palette and child-only
`QS_WINDOWS_BLUR=0` were exercised. Actual system-transparency-off behavior
was not tested and the user's setting was preserved.

ERM-493/494 remain open for the single-jump hover case, rapid boundary input,
native 175% pointer masks/focus, keyboard traversal, configured bar/session
drag and pin scenarios, early app switching, system transparency off, and
remaining lifecycle scenarios. M2-M4 remain outside this validation.

## Reproduce

Use [NATIVE-BUILD.md](../../NATIVE-BUILD.md) for the recorded build command.
The command argument JSON and configure/build/install logs are included here.
The environment report is a prerequisite result, not runtime acceptance.

```powershell
$qtPrefix = "$env:LOCALAPPDATA\caelestia-dev\Qt\6.11.2\msvc2022_64"
foreach ($scale in @('1', '1.5', '1.75')) {
    powershell -NoProfile -File windows/scripts/Start-ShellPrototype.ps1 `
        -QtPrefix $qtPrefix -Smoke -ScaleFactor $scale
    if ($LASTEXITCODE -ne 0) { throw "Failed at $scale" }
}
powershell -NoProfile -File windows/scripts/Start-ShellPrototype.ps1 `
    -QtPrefix $qtPrefix -Smoke -MonitorCycle
```

Use `-Wait` without smoke for interactive checks, and the dedicated fixture
and desktop snapshot commands in the prototype README. Address the exact
printed PID/path for `prototype.state`, `capture`, and `quit`; do not operate
on another Quickshell session.

Copied JSON/logs retain original absolute local paths as provenance. Archive
filenames above provide portable links to those artifacts. Raw record bytes
are preserved by this directory's `.gitattributes`.
