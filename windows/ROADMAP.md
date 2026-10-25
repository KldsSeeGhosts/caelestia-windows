# Caelestia Windows milestones

The native backend build and portable component rendering are now demonstrated.
Gates below are acceptance criteria, not claims of a complete shell. Track these as
separate issues when the Linear connection is available.

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

Status: portable plugin compilation and a component probe pass. The probe uses
the original clock widgets, graphics plugins, and animations with a fixed
palette adapter in an ordinary window. It does not load `Bar.qml` or
`ContentWindow.qml`, and M1 remains open.
See the [component validation record](validation/2026-10-25-component-probe/README.md).

Gate:

- No missing required QML imports, types, properties, or signals.
- Bar and drawer render with the intended shader and animation behavior.
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
