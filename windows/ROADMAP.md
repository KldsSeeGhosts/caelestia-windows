# Caelestia Windows milestones

The native backend build and portable component rendering are now demonstrated.
Gates below are acceptance criteria, not claims of a complete shell.
[Caelestia Windows in Linear](https://linear.app/ermin-zeherovic/project/caelestia-windows-c69c05fa35b7)
tracks the milestones and implementation issues.

## Status snapshot, 2026-10-25

- M0: local developer bootstrap complete. Backend pin, native build commands,
  isolated probe configuration, and validation evidence are recorded.
- M1: in progress. The original bounded native bar and session drawer load and
  render. Native 150% hover, opening, Escape/focus return, and outside-click
  pass-through have evidence. Same-window native 150% -> 175% -> 150%
  transfer passes; 175% pointer/focus, rapid boundaries, system transparency
  off, drag/lifecycle scenarios, final matrix and archival remain.
- M2, M3, M4: not started. No Windows service integration, tiling validation,
  or installable shell release is claimed.

Continue from [HANDOFF.md](HANDOFF.md). Linear was connected and synchronized
on 2026-10-25 under the Ermin Zeherovic (ERM) team. This roadmap owns detailed
acceptance criteria; Linear tracks issue status and dependencies.

Completed issues are ERM-489 (M0 bootstrap), ERM-490 (component probe), and
ERM-491 (dependency/backend audit, pushed in `f1d3a020`). M1 work is sequenced as:

1. [ERM-491: dependency and backend API audit](https://linear.app/ermin-zeherovic/issue/ERM-491), done.
2. [ERM-492: load the original bar and one drawer](https://linear.app/ermin-zeherovic/issue/ERM-492), implemented; validation and archival underway.
3. [ERM-493: hover, input, focus, and dismissal](https://linear.app/ermin-zeherovic/issue/ERM-493), in progress.
4. [ERM-494: native DPI, monitor, transparency, and lifecycle gate](https://linear.app/ermin-zeherovic/issue/ERM-494), open.

## M0: source and reproducibility

Retain upstream history, pin Windows Quickshell, and report the local toolchain.
Keep configuration and state isolated. Record the source revisions and exact
commands for every build. Do not distribute a binary before its sources and
dependencies are accounted for.

Status: repository bootstrap complete; the pinned backend and portable plugins
build with the native toolchain documented in [NATIVE-BUILD.md](NATIVE-BUILD.md).
Build scripts record source revisions, tool versions, prerequisite results, and
commands under `windows/.local/build/logs`.

## M1: actual Caelestia compatibility prototype

Build the portable plugin subset and load Caelestia's own bar plus one drawer.
Use an explicit isolated entry point with unsupported services disabled through
platform boundaries. Preserve upstream components rather than replacing them
with lookalike rectangles.

Status: the [native bar/session prototype](shell-prototype/README.md) loads
original ContentWindow/StyledWindow, Regions/Interactions, Bar/Clock/Power and
Session.Wrapper/Content. Fixed palette and explicit unavailable adapters keep
unsupported services out; process-local fonts preserve original icons.
WindowsFocusGuard provides bounded native activation/restoration policy.
Drawers/Exclusions and Taskbar/Tiling controllers are not instantiated.

Real pointer tests on the native 150% primary display demonstrated hover,
Power opening, Escape dismissal with direct foreground verification, and
outside-click dismissal passing through to a dedicated fixture. Rapid
boundary tests have not passed yet. The same ContentWindow passed native
MAG321UX OLED 150% -> DELL S2725QS 175% at x=-3840 -> primary transfer,
remaining 900x620 at each placement without QML diagnostics. That rendering
test does not validate pointer masks/focus at 175%. Earlier synthetic
100%/150% baselines preceded the focus helper; the final synthetic matrix and
archival are underway. Windows EnableTransparency=1 with backend blur disabled
and an opaque fixed palette is not a system-transparency-off result.
Final evidence and limitations belong in the
[bar/session validation record](validation/2026-10-25-bar-session/README.md);
archival is underway. M1 remains open. The older
[component validation record](validation/2026-10-25-component-probe/README.md)
continues to describe only its own source revision.

Gate:

- No missing required QML imports, types, properties, or signals.
- Bar and drawer render with the intended shader and animation behavior.
- Original configurable hover interactions work; the click-only component
  probe is not acceptance evidence for hover behavior.
- Pointer regions, keyboard focus, dismissal, and focus return work.
- Test 150% and 175% DPI, negative monitor origins, and transparency off.
- Startup and shutdown leave the existing shell, taskbar, tiler, autostart, and
  user configuration untouched.
- Capture the build commands, runtime and source versions, screenshots, logs,
  and a list of disabled or unsupported features.

Stop broad feature implementation if this gate fails. Resolve the compatibility
gap before treating the Windows backend as a proven foundation.

## M2: Windows services

Adapt public service interfaces to the backend's Windows implementations:
audio/media, notifications, network, Bluetooth, power, brightness, app catalog,
tray, and session actions. Audit Linux process calls and filesystem assumptions.
Use Windows' secure lock screen and UAC. Validate missing hardware and denied
access without retry loops or privilege changes.

Gate: enable services individually, with explicit unavailable states and no
unexpected startup side effects.

## M3: windows, workspaces, and tiling

Validate the backend's Hyprland-compatible operations against the Caelestia UI.
Keep one tiler active. Test real applications with minimum-size constraints,
modal move/resize, rapid launch/close, focus changes, maximize/restore, and
mixed-DPI monitor transfer. Treat DWM behavior as a Windows boundary rather
than assuming compositor-level control over other applications.

Gate: no overlapping tiled windows, accidental size floating, lost focus, or
unbounded correction loop during the recorded scenarios. When fitting is
impossible, the UI must explain the outcome.

## M4: complete shell and packaging

Expand to dashboard, launcher, sidebar, notifications, OSD, and the remaining
supported modules. Package pinned Qt/backend/plugin dependencies, fonts, and
license notices. Provide reversible per-user installation, startup options,
updates, and uninstall.

Gate: a clean Windows 11 profile passes installation, startup, multi-monitor,
sleep/wake, device recovery, update, rollback, and uninstall checks.
