# M1 compatibility acceptance, 2026-10-25

ERM-493 and ERM-494 pass for the isolated original bar/session prototype.
This completes the bounded M1 compatibility gate, not a complete shell release.
M2-M4 remain unstarted. The earlier
[bar/session archive](../2026-10-25-bar-session/README.md) retains its original
revisions and incomplete results.

## Sources and runtime

- Clean runtime/test source: `24229c9af63cf92235b387c2997c3c50248540dc`.
- Clean native build: `9bb447aa2171c50cc5fdf6a5077d1048f8cc0e4d`.
  Subsequent commits change only the input test, its test-only C# helper and
  documentation. Compiled shell/plugin source is unchanged.
- Backend: `84604c258da92a004b46d62a89718ae615840b98` in the private
  [Caelestia backend fork](https://github.com/KldsSeeGhosts/caelestia-quickshell-windows/tree/84604c258da92a004b46d62a89718ae615840b98).
  Its full history retains `nunreasonable/quickshell` baseline `e8ae0ef1`;
  the cumulative patch changes only `src/windows/input_mask.cpp`.
  The gitlink, `.gitmodules` and `sources.lock.json` agree.
- Windows `10.0.26300.0`, Qt 6.11.2, clang-cl 20.1.8, SDK 10.0.26100.0,
  MSVC tools 14.44.35207, CMake 4.4.4 and Ninja 1.13.2. Rendering uses
  Direct3D 11 (`GraphicsInfo.api=4`).

[Build record](build/build.json), exact command argument files, configure/build/
install logs and the strict developer-environment report are in [build](build).
The ordinary-process [environment report](build/environment-default.json)
reports tools absent from that process's PATH; the build script enters the
development environment locally. Neither report is itself runtime evidence.
Result JSON retains original absolute paths as provenance. Copied runtime logs,
source manifests and captures are alongside each result. Raw JSON/log bytes
are preserved by `.gitattributes`; [artifact hashes](artifacts.sha256.json)
identify the archived files.

## Hover defect and fix

The native input test reproduced a stationary edge failure after rapid
crossings on the old backend. Its hook posts mask evaluation to the GUI thread,
so Windows can already have delivered the triggering move to the underlying
window. Qt then has no new movement to reveal the bar. Unchanged-position
re-entry also matters because Qt filters repeated mouse positions.

The backend now defers one local Qt enter notification on transparent-to-input
handoff, checking the exact pointer, native surface, hit window, style and
mouse-button state again. It delivers leave on input-to-transparent handoff.
It injects no system input or focus request. Original `Interactions.qml` also
opens the configured hover bar on enter at unchanged coordinates. Original
motion, masks and drag logic remain in use. The
[API audit addendum](../../audits/M1-BACKEND-API.md#focus-dismissal-and-return)
records the source review.

[Preliminary evidence](preliminary-hover) retains the old-pin reproduction.
That trial also exposed fixture host cleanup problems; its failed result is
not certification. The fixture now explicitly exits its message loop on close.

## Passing native input matrix

[Native result](native/result.json) and
[transparency-off result](transparency-off/result.json) each contain 36 passing
scenarios from clean source. Each uses the same native window through:

1. MAG321UX OLED, native DPR 1.5.
2. DELL S2725QS, native DPR 1.75, physical monitor origin x=-3840.
3. Original MAG321UX OLED, native DPR 1.5.

At every placement, the window remains 900x620 logical pixels, with physical
width matching DPR. The 12 scenarios check:

- One pointer move into the edge followed by stationary hover, without a click
  or further movement. The bar opens to width 60 and does not take focus.
- Twelve rapid enter/leave pairs with 40 ms dwell, followed by settled opening
  and closing assertions.
- Original configured bar drag threshold: pin, retain on leave, reverse-drag
  unpin, then close on leave.
- Original Power control opening the session and acquiring foreground focus.
- Four original session buttons, Down/Up traversal and configured Tab traversal.
  The [isolated configuration](isolated-shell.json) enables `vimKeybinds`.
  Return is consumed by the unavailable session adapter.
- Escape dismissal and independently observed foreground return to the fixture.
  `restore-requested` is accepted only when the actual foreground reaches the
  fixture; Windows can complete the one native request asynchronously.
- Outside click reaching the fixture exactly once, dismissing the drawer and
  retaining fixture focus.
- Foreground switch 26-30 ms after opening, inside the backend's 500 ms grace,
  followed by dismissal without focus theft.
- Original session edge drag to open and reverse drag to close.
- Four additional open/Escape cycles, followed by a click-through assertion
  proving the closed panel does not block the fixture.

See [native scenarios](native/scenarios.jsonl),
[off scenarios](transparency-off/scenarios.jsonl), fixture event streams,
runtime input-mask traces and staged source manifests in those directories.
These are automated Windows `SendInput` events through native routing, not
background posted clicks or physical-hardware observations.

The final transparency-off run records `EnableTransparency` 1 -> 0 -> 1 and
Windows `UISettings.AdvancedEffectsEnabled` true -> false -> true.
It launches the prototype under that actual preference and restores it after
shutdown. It sends no desktop-wide live settings notification. Backend blur
remains disabled and the fixed palette remains opaque.

## Rendering and lifecycle

- Clean synthetic [100%](synthetic-1/result.json),
  [150%](synthetic-1.5/result.json) and [175%](synthetic-1.75/result.json)
  rendering pass, including fonts, original bar/session opening and closing,
  geometry and captures.
- The clean [secondary-origin native cycle](native-cycle/result.json) passes
  175% negative-origin -> 150% -> original 175%, complementing the native input
  matrix's primary-origin cycle.
- Final input and rendering runs produce no QML warning/error diagnostics.
  The smoke checks validate required body, clock and icon fonts.
- Both final input runs preserve identical monitor/work-area rectangles,
  taskbar flags and relevant process identities. Explorer PID 9872 and
  KSG Shell PID 32044 remain active. Test fixtures and prototype processes exit.
  [Final desktop state](desktop-final.json) and
  [restored transparency state](transparency-final.json) confirm cleanup.
- The original taskbar/tiler/autostart and ordinary Caelestia settings are not
  written by these tests. Configuration, state, runtime, data and cache stay
  in the dedicated ignored prototype profile. User application sessions remain
  open. No taskbar/tiling controller, desktop hosting or autostart is enabled.

### Rejected desktop-wide notification test

A preliminary harness broadcast `WM_SETTINGCHANGE` to unrelated applications
when restoring transparency. All its input scenarios passed, but its lifecycle
gate correctly failed: KSG Shell PID 16436 panicked with `RefCell already borrowed`
in `shell\ksg-compose\src\app_bar.rs:101`, then removed its AppBars and exited.
This is a separate KSG Shell defect, not a passing Caelestia result.

[Rejected result, snapshots and panic excerpt](rejected-settings-broadcast)
are retained. The unchanged installed KSG Shell was restarted from its existing
per-user launch configuration as PID 32044, restoring the original work areas.
No KSG source, installation or configuration was changed. The final harness
tests prototype startup under the real transparency preference without that
desktop-wide broadcast. Both final matrices preserve PID 32044 and its work
areas. Live global setting reconfiguration across other shells remains outside
this bounded gate and is not certified.

## Disabled boundaries and reproduction

Only the original bar Clock/Power and selected session drawer are enabled.
Other panels, popouts, Linux services, dynamic themes and hardware services are
unavailable adapters. Real session commands are empty and always consumed.
Drawers/Exclusions and Taskbar/Tiling controllers are not instantiated.
The backend still performs its normal native-window support, stale-AppBar
startup cleanup, input-mask bookkeeping and Quickshell instance bookkeeping.
This is not zero global bookkeeping.

Build using [NATIVE-BUILD.md](../../NATIVE-BUILD.md), then leave the pointer and
keyboard idle for the opt-in input tests:

```powershell
$qtPrefix = "$env:LOCALAPPDATA\caelestia-dev\Qt\6.11.2\msvc2022_64"
powershell -NoProfile -File windows/scripts/Test-ShellPrototypeInput.ps1 `
    -QtPrefix $qtPrefix -AllowDesktopInput
powershell -NoProfile -File windows/scripts/Test-ShellPrototypeInput.ps1 `
    -QtPrefix $qtPrefix -AllowDesktopInput -TestTransparencyOff
foreach ($scale in @('1', '1.5', '1.75')) {
    powershell -NoProfile -File windows/scripts/Start-ShellPrototype.ps1 `
        -QtPrefix $qtPrefix -Smoke -ScaleFactor $scale
    if ($LASTEXITCODE -ne 0) { throw "Failed at $scale" }
}
powershell -NoProfile -File windows/scripts/Start-ShellPrototype.ps1 `
    -QtPrefix $qtPrefix -Smoke -MonitorCycle -ScreenIndex 1
```

M1 certifies this bounded slice on the recorded workstation. It does not
certify physical input devices, live global theme changes, hardware-denial
handling, a full Windows shell, tiling, installation or packaging. Linux was
not rebuilt in this session.
