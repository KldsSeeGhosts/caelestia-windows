# Windows port handoff, 2026-10-25

## Current milestone

M0's local developer bootstrap is complete. M1 is in progress. The pinned
Windows Quickshell backend and eight portable Caelestia plugin modules build
natively, and the component probe renders original Caelestia clocks, blob
surfaces, rounded clipping, and animation through Direct3D 11.

This is an ordinary application window. Clicking the bar clock opens/closes
the motion specimen; Escape closes it. The actual `Bar.qml`,
`ContentWindow.qml`, and drawer service graph are not loaded. Configurable
hover interaction, pointer regions, keyboard focus, outside-click dismissal,
and focus return remain unvalidated. The user expects the real port to retain
Caelestia's hover behavior.

M2 services, M3 window/workspace/tiling validation, and M4 packaging have not
started. Keep the detailed acceptance criteria in [ROADMAP.md](ROADMAP.md).

## Sources and completed work

The implementation commits are:

- `a80afac7`: native Windows portable plugin build and component probe.
- `15633d6d`: bounded startup allowance and timestamped rendering checks.
- `fffea341`: archived validation evidence and remaining M1 boundaries.

The validated implementation revision is
`15633d6d1f6bcfb5d3634e7750784dac3d150d70`. Documentation commits follow it.
The [validation record](validation/2026-10-25-component-probe/README.md) includes
source hashes, commands, tool versions, stdout/stderr, and screenshots for
100%, 150%, and 175% synthetic DPI. All three final runs passed without runtime
warnings/errors and took about four seconds each.

The backend remains `e8ae0ef124b1c14b547c80d00422d2ffbd423d81`, as pinned by
both the gitlink and `sources.lock.json`. No backend changes were required.
Do not advance its pin as part of routine continuation.

The portable plugin build excludes the calculator, Models, Services, Images,
and Multimedia. Windows DLL metadata exports/imports, generated forwarding
headers, and HLSL shader generation are implemented. Linux dependency defaults
remain in source; a Linux build was not rerun.

## Resume on this workstation

Read repository `AGENTS.md`, [README.md](README.md),
[ROADMAP.md](ROADMAP.md), and [NATIVE-BUILD.md](NATIVE-BUILD.md).
Check Git status and fetch `origin` before starting a new topic branch from
`main`. Preserve any newer work.

`origin` is `KldsSeeGhosts/caelestia-windows`; `upstream` is
`caelestia-dots/shell`. Use an explicit
`-R KldsSeeGhosts/caelestia-windows` with `gh`: automatic repository selection
can choose the upstream project.

The existing per-user toolchain is under
`$env:LOCALAPPDATA\caelestia-dev`: Qt 6.11.2 `msvc2022_64`,
clang-cl 20.1.8, CMake/Ninja in `tools\Scripts`, and CLI11 2.5.0 in
`deps\CLI11-2.5.0\include`. Visual Studio Build Tools 2022 and Windows SDK
10.0.26100.0 are installed. Build outputs are ignored under
`windows\.local\build`.

Rebuild only when source changes require it:

```powershell
$devRoot = Join-Path $env:LOCALAPPDATA 'caelestia-dev'
powershell -NoProfile -File windows/scripts/Build-Prototype.ps1 `
    -QtPrefix "$devRoot\Qt\6.11.2\msvc2022_64" `
    -LlvmBin "$devRoot\clang+llvm-20.1.8-x86_64-pc-windows-msvc\bin" `
    -Cli11Include "$devRoot\deps\CLI11-2.5.0\include" `
    -ToolsBin "$devRoot\tools\Scripts"
```

For manual inspection:

```powershell
powershell -NoProfile -File windows/scripts/Start-Prototype.ps1 `
    -QtPrefix "$env:LOCALAPPDATA\caelestia-dev\Qt\6.11.2\msvc2022_64"
```

Add `-Smoke -ScaleFactor 1.5` for a bounded rendering check. Use scales `1`,
`1.5`, and `1.75` after relevant rendering changes. The result JSON and logs
are in `windows\.local\build\logs`.

An ordinary PowerShell environment check can report missing tools because the
build script activates the developer environment only inside its own process.
That is not evidence that the installed toolchain is absent.

## Next implementation task

Linear is connected under the Ermin Zeherovic (ERM) team:
[Caelestia Windows project](https://linear.app/ermin-zeherovic/project/caelestia-windows-c69c05fa35b7).
M0 bootstrap and the component probe are recorded as completed in ERM-489 and
ERM-490. Start with
[ERM-491](https://linear.app/ermin-zeherovic/issue/ERM-491), then ERM-492 (actual
bar/drawer), ERM-493 (hover/input/focus), and ERM-494 (M1 validation). Dependencies
are linked in that order. Update Linear as work progresses and keep the
repository's acceptance criteria and validation evidence current.

Continue M1 by loading the real bar and one drawer with their original
interactions:

1. Trace imports and instantiated services from `modules/bar/Bar.qml`,
   `modules/bar/BarWrapper.qml`, `modules/drawers/ContentWindow.qml`, and
   `modules/drawers/Panels.qml`. Check `modules/drawers/Interactions.qml` for
   the existing hover and drag behavior.
2. Identify the minimum service contracts and plugin modules needed for that
   slice. Adapt those interfaces to the pinned backend. Unsupported services
   need explicit unavailable states and must not spawn Linux commands.
3. Check the precise Wayland/Hyprland compatibility types, attached
   properties, and signals against the pinned backend. Do not infer API
   parity merely from import names.
4. Keep an isolated entry point and state paths. Preserve original components
   and motion, then verify hover, pointer masks, focus, dismissal, and focus
   return. Complete native/mixed-monitor DPI, negative-origin, and
   transparency-off checks before marking M1 complete.

Do not start broad M2 feature work until the M1 compatibility route is proven.

## Constraints and known limitations

- The existing KSG Shell remained active and resized the first probe window.
  The probe specimen now has a fixed logical size within its ordinary window.
  Do not stop or reconfigure the current tiler to make a test pass.
- No desktop takeover, taskbar configuration change, autostart, or packaging
  is enabled. Keep those opt-in and preserve existing application sessions.
- Only the body font is bundled. The clock icon is disabled; Rubik and
  Material Symbols coverage remains open. The palette adapter is fixed;
  wallpaper analysis and dynamic themes are not loaded.
- Synthetic DPI tests do not establish native DPI transitions or monitor
  behavior. Crossfade HLSL was inspected/imported, not exercised.
- One earlier post-build run reached capture near the old 20-second limit.
  Its cause remains unknown. The outer limit is now 45 seconds, with a separate
  10-second in-app watchdog; the failed result is archived.
- Inherited GitHub Actions remain disabled at repository level. Do not enable
  the upstream Linux/release workflows. Local validation is the available
  build/runtime evidence.
- The user reauthorized Linear on 2026-10-25 and the project, five milestones,
  and six issues were created. The optional `get_agent_context` tool returned
  `Tool get_agent_context not found` despite appearing in tool discovery;
  ordinary project, milestone, and issue operations work.
