# Windows port handoff, 2026-10-25

## Current milestone

M0 is complete and M1 remains open. The main entry point is the
[bounded native bar/session prototype](shell-prototype/README.md), loading
original ContentWindow/StyledWindow, Regions/Interactions, Bar/Clock/Power,
and Session.Wrapper/Content. Original blob surfaces, motion and icons render
with fixed palette and nonvisual unavailable adapters.

The pinned backend, eight portable modules and Windows-only
`Caelestia.Windows` module build with Qt 6.11.2 and clang-cl 20.1.8.
WindowsFocusGuard adds one activation request, one guarded 75 ms focus
restoration, and external-foreground reconciliation after 550 ms active.
It does not bypass Windows foreground permissions or retry denied requests.

Native 150% primary-display tests have demonstrated continuous-pointer bar
hover, Power opening, Escape dismissal and focus return. Direct foreground
observation confirmed prototype PID 20428 -> fixture PID 2880 with
`restore-succeeded`. Outside-click pass-through incremented the fixture's
clickCount 1 -> 2, closed the session and skipped focus restoration.
Cua returned a foreground mismatch on that outside click; independent fixture
and state evidence verified the intended result, not driver success.

Synthetic 100%/150%/175% checks pass on clean `b9f07e34`.
The final startup patch and native cycle pass on clean `b534ae26`.
Single-jump hover did not open the bar until further movement; investigate
that case before closing the input gate.
Native same-window transfer passed without QML diagnostics: screen 0
MAG321UX OLED at 150%, screen 1 DELL S2725QS at 175% and x=-3840, back to 0,
all 900x620. Actual DPI metadata and captures were recorded.
The [bar/session validation record](validation/2026-10-25-bar-session/README.md)
owns exact final evidence and limitations. M2-M4 have not started.

## Sources and completed work

- `a80afac7`, `15633d6d`, `fffea341`: native portable build, component probe,
  bounded startup checks and archived evidence.
- `f1d3a020`, pushed: ERM-491 dependency and backend API audits.
- `b9f07e34`, `b534ae26`: original loading, focus policy, isolated staging and
  startup handling. ERM-492 and its archive are complete.
  ERM-493/494 remain in progress. See [ROADMAP.md](ROADMAP.md).

The [component probe archive](validation/2026-10-25-component-probe/README.md)
still describes revision `15633d6d1f6bcfb5d3634e7750784dac3d150d70` and its
synthetic 100%/150%/175% results. Those results do not validate later native
input/focus changes.

Backend pin remains `e8ae0ef124b1c14b547c80d00422d2ffbd423d81`, matching the
gitlink and sources.lock.json. No backend source changes are required by this
slice. Do not advance the pin routinely. Read the
[dependency](audits/M1-DEPENDENCIES.md) and
[backend API](audits/M1-BACKEND-API.md) audits before widening the staged graph.

Localized original QML changes use direct exclusionMode, finite/null-monitor
drag padding, an interactionEnabled property defaulting to true, and
Config.enabled gates for keyboard focus and original panel gestures.
No-input smoke explicitly disables interaction; normal enabled Linux defaults
retain the original behavior. The Windows host is top/left anchored with an
explicit bounded size to avoid right/bottom margin binding loops on transfer.

## Resume on this workstation

Read repository AGENTS.md, [README.md](README.md),
[NATIVE-BUILD.md](NATIVE-BUILD.md), and the prototype README. Inspect Git status
and preserve newer work before selecting a topic branch. `origin` is
`KldsSeeGhosts/caelestia-windows`; `upstream` is Caelestia. Use
`gh -R KldsSeeGhosts/caelestia-windows` explicitly.

Toolchain lives under `$env:LOCALAPPDATA\caelestia-dev`: Qt 6.11.2
`msvc2022_64`, clang-cl 20.1.8, CMake/Ninja in `tools\Scripts`, CLI11 2.5.0
in `deps\CLI11-2.5.0\include`, Visual Studio Build Tools 2022 and SDK
10.0.26100.0. Rebuild when native/plugin source changes:

```powershell
$devRoot = Join-Path $env:LOCALAPPDATA 'caelestia-dev'
powershell -NoProfile -File windows/scripts/Build-Prototype.ps1 `
    -QtPrefix "$devRoot\Qt\6.11.2\msvc2022_64" `
    -LlvmBin "$devRoot\clang+llvm-20.1.8-x86_64-pc-windows-msvc\bin" `
    -Cli11Include "$devRoot\deps\CLI11-2.5.0\include" `
    -ToolsBin "$devRoot\tools\Scripts"
```

Manual native run with logs captured until exit:

```powershell
powershell -NoProfile -File windows/scripts/Start-ShellPrototype.ps1 `
    -QtPrefix "$devRoot\Qt\6.11.2\msvc2022_64" -Wait -ScaleFactor native -ScreenIndex 0
```

Use `-Smoke` for no-input rendering checks; scale accepts native/1/1.5/1.75.
`-MonitorCycle` requires native smoke and two monitors, transfers the same
ContentWindow out/back and records actualScreens/captures. The first cycle
rendered all three placements but failed on binding-loop warnings; the host
was fixed and the final native cycle passed without QML diagnostics.
An absent ScreenIndex fails explicitly.
The prototype's exact-instance IPC exposes prototype.state/capture/quit;
state includes sessionFocusedIcon. Stop only the dedicated prototype.

`Start-InputTarget.ps1` is a dedicated WinForms input fixture and must run
in its own `powershell -NoProfile -STA -File` process.
`Get-DesktopState.ps1` reads physical work areas, scales, taskbar flags,
foreground HWND/PID and relevant processes. Both are documented in the
prototype README. Outputs default to ignored `windows/.local/build`.
The old `Start-Prototype.ps1` component probe remains available.

## Next work and boundaries

Start with the single-jump hover case in the validation record. Finish native
175% pointer/focus, keyboard traversal, early app-switch reconciliation,
configured drag/pin, rapid boundaries, actual system-transparency-off and
remaining lifecycle tests. Keep ERM-493/494 open until their own acceptance
evidence passes. Do not begin broad M2 services before M1 passes.
Second independent source review found no actionable findings in the fixes;
that does not replace the remaining runtime gates.

The entry point skips Drawers/Exclusions and Taskbar/Tiling controllers,
leaves the existing `ksg-shell` active, and does not enable taskbar changes,
autostart, packaging or session actions. Backend native support for its own
window, shared stale-AppBar startup cleanup, native input-mask routing and
Quickshell instance bookkeeping still occur. Do not claim zero global
bookkeeping. Keep desktop takeover and tiling opt-in.

Rubik and Material Symbols are bundled with pinned provenance/licenses under
`windows/assets` and loaded only in the child process; no system font install.
The palette is fixed. Upstream Linux services, dynamic wallpaper themes,
real power/session actions and broad Windows service integration stay disabled.
Windows EnableTransparency remains 1; the tested opaque fixed palette and
QS_WINDOWS_BLUR=0 do not establish system-transparency-off behavior.
Denied/unavailable hardware handling remains future service work.
Inherited Linux/release workflows remain disabled.
