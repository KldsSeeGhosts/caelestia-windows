# Native bar and session prototype

This isolated M1 entry point loads Caelestia's original ContentWindow,
StyledWindow, Regions, Interactions, Bar/BarWrapper, Clock/Power, and
Session.Wrapper/Content. The native window is bounded to at most 900x620
logical pixels, inset 80 from the selected monitor's top/left. Its original
blob surfaces, deformation, icons and motion are retained.

The prototype uses a fixed palette and nonvisual unavailable adapters for
disabled bar entries and panels. Session actions are explicitly unavailable:
their adapter consumes every command without executing it, and all four
configured command lists are empty. Drawers/Exclusions and Taskbar/Tiling
controllers are not instantiated. The entry point does not configure or launch
the existing `ksg-shell`. This is a bounded compatibility prototype; a complete
shell and packaging belong to later milestones.

## Build and launch

Build with [NATIVE-BUILD.md](../NATIVE-BUILD.md). Qt 6.11.2 and clang-cl 20.1.8
build the portable plugins plus the Windows-only `Caelestia.Windows` module.
The prototype loads that module's WindowsFocusGuard.

From the repository root:

```powershell
$qtPrefix = "$env:LOCALAPPDATA\caelestia-dev\Qt\6.11.2\msvc2022_64"
powershell -NoProfile -File windows/scripts/Start-ShellPrototype.ps1 `
    -QtPrefix $qtPrefix -Wait -ScaleFactor native -ScreenIndex 0
```

Move the pointer continuously into the left edge to reveal the bar. Power
opens the original session drawer. Escape closes it; an outside click should
dismiss it while allowing the underlying application to receive the click.
Stop only this prototype process, or use its isolated `prototype.quit` IPC
method. Do not stop another shell or change its configuration.

`-Wait` captures logs until exit, then writes its result and source manifest.
Without `-Wait`/`-Smoke`, the script returns immediately with the child PID.
`-BuildRoot` selects an output root. `-ScreenIndex` accepts 0-15 and fails
explicitly when the requested screen is absent. `-ScaleFactor` accepts
`native`, `1`, `1.5`, or `1.75`; numeric values override only the child
process's DPI and are synthetic tests.

`Stage-ShellPrototype.ps1 -Destination <path> -ProfileRoot <path>` stages the
explicit [source mappings](sources.json), entry point, fonts and licenses,
recording source/staged hashes. Each launch uses a fresh
`windows/.local/build/shell-runs/shell-<timestamp>/` stage. The dedicated
`shell-prototype-profile` holds config/state/runtime/data/cache; the launcher
rewrites only this profile's audited `shell.json`. It never stages upstream
root `shell.qml`.

## Rendering and input evidence

```powershell
powershell -NoProfile -File windows/scripts/Start-ShellPrototype.ps1 `
    -QtPrefix $qtPrefix -Smoke -ScaleFactor native -ScreenIndex 0
```

Smoke sets `interactionEnabled=false`: empty native input mask, no keyboard
grab or focus activation, and programmatic motion only. It checks original
content geometry, fonts, scale and unavailable actions, captures a PNG and
exits. The 45-second outer limit and 15-second QML watchdog bound the run;
runtime warnings/errors fail it. Interactive mode keeps the original input
behavior enabled by default.

Add `-MonitorCycle` with `-Smoke -ScaleFactor native` and two or more monitors.
It opens/captures/closes on the selected monitor, transfers the same
ContentWindow to the next monitor, repeats, then returns. Result JSON records
`actualScreens` and `captures`. The initial transfer rendered all placements
but failed on binding warnings. After the host correction, the final native
cycle passed without QML diagnostics: MAG321UX OLED 150% -> DELL S2725QS 175%
at x=-3840 -> primary, all at 900x620. Actual DPI metadata and captures were
recorded. Do not treat the initial warned run as passed.

Interactive input uses a dedicated WinForms fixture:

```powershell
powershell -NoProfile -STA -File windows/scripts/Start-InputTarget.ps1
powershell -NoProfile -File windows/scripts/Get-DesktopState.ps1
```

Run the fixture command in its own PowerShell process. Optional `-LogPath`,
`-ClientWidth`, and `-ClientHeight` configure its JSONL evidence and size.
It records mouse counts/coordinates, activation and keyboard events.
Get-DesktopState is read-only: physical monitor/work areas, scales, taskbar
flags, foreground HWND/PID, and relevant process names/PIDs. Its optional
`-OutputPath` saves a snapshot. Neither script changes desktop settings.

The entry point exposes `prototype.state`, `prototype.capture`, and
`prototype.quit` through Quickshell IPC. Address the exact instance using its
printed staged `shell.qml` path; do not broadcast to other Quickshell sessions.
State includes screen/DPR, bar visibility, session state, focused session icon,
and focus-guard status.

For repeatable native input tests, leave the pointer and keyboard idle and run:

```powershell
powershell -NoProfile -File windows/scripts/Test-ShellPrototypeInput.ps1 `
    -QtPrefix $qtPrefix -AllowDesktopInput
```

This opt-in test uses Windows `SendInput`, a dedicated fixture and exact-instance
IPC. It moves the pointer and focus across the primary, secondary and primary
displays. It checks stationary hover, rapid boundaries, configured bar pin/unpin
and session drag, keyboard traversal, Escape/focus return, outside-click
pass-through, early foreground switching and repeated open/close. It requires
two monitors and never starts a tiler. Add `-TestTransparencyOff` to temporarily
set the current user's `EnableTransparency` to 0; `finally` restores the
original value, pointer and foreground window and closes only test-owned
processes. Windows `UISettings.AdvancedEffectsEnabled` independently confirms
the preference during the test and after restoration. This tests startup with
transparency off; it sends no desktop-wide settings notification and does not
test live reconfiguration of other shells. Run without another controller or user input. Automated injected
Windows input is distinct from physical hardware input.
The isolated profile enables the original session `vimKeybinds` option for Tab
navigation; Up/Down use the original button navigation links.

The runner saves assertions, actual DPR/geometry, screenshots, fixture events,
input-mask traces, source hashes and before/after desktop state under the ignored
build directory. `-OutputDirectory` chooses another evidence directory.
`Start-ShellPrototype.ps1 -TraceInput` enables backend mask diagnostics for
manual investigation. `prototype.state` also exposes mouse coordinates,
containsMouse, pressed/pinned state and control centers; `moveToScreen(index)`
transfers the exact prototype instance without changing display settings.

M1 is complete for this bounded prototype. Clean `24229c9a` passes 72 native
input scenarios at 150%/175%, including negative origin, rapid boundaries,
stationary hover, original drag/pin behavior, keyboard navigation, focus,
dismissal and lifecycle. Actual transparency-off startup is verified by
Windows UISettings and restored afterward. Synthetic 100%/150%/175% rendering
and the secondary-origin native monitor cycle also pass.
The [final acceptance record](../validation/2026-10-25-m1-acceptance/README.md)
owns exact commands, revisions, screenshots, results and limitations.
It also retains a rejected desktop-wide settings-broadcast test that exposed
a separate KSG Shell panic; the existing installed shell was restored.
Live global reconfiguration across other shells is not certified.

## Focus and platform boundaries

WindowsFocusGuard samples external foreground identity, requests activation
once per opening, and queues one guarded restoration 75 ms after close.
It skips restoration when another application has become foreground or the
saved window identity is invalid. While active, it reconciles an external
foreground change after 550 ms to cover the backend's startup grace.
It uses ordinary Windows foreground permissions, with no input-queue attach,
hooks of its own, synthetic input or denial retry loop. Its status is logged
as `CAELESTIA_SHELL_FOCUS`.

Small upstream edits use direct `exclusionMode`, finite/null-monitor drag
padding, and `interactionEnabled` defaulting to true for no-input smoke.
Keyboard focus and original gestures honor panel Config.enabled flags;
enabled Linux defaults retain the original behavior. The Windows host uses
top/left anchoring and explicit implicit size to avoid transfer-time
right/bottom margin binding loops.

The backend still initializes native desktop support for its own window,
routes native input masks, performs shared stale-AppBar startup cleanup,
and maintains Quickshell's Windows instance bookkeeping. The isolated profile
does not imply zero global bookkeeping or authorize desktop takeover,
taskbar changes, tiling or autostart.

Body font, [pinned Rubik/Material Symbols fonts and licenses](../assets/README.md)
are loaded into this process only. Dynamic wallpaper themes and Windows
services remain outside this slice. See the [dependency](../audits/M1-DEPENDENCIES.md)
and [backend](../audits/M1-BACKEND-API.md) audits. ERM-491/492 are done with
archived evidence; ERM-493/494 and the bounded M1 gate are complete. Denied/unavailable
hardware handling belongs to future service integration.
