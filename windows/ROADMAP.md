# Caelestia Windows roadmap

These milestones record the acceptance gates for the Windows port. They are
criteria, not claims of a complete release. Current work and open gaps are
tracked in [GitHub issues](https://github.com/KldsSeeGhosts/caelestia-windows/issues).

The native backend build, original component rendering, Windows services and
packaging are implemented and integrated into the installed shell. Release
acceptance is the remaining gate: live input and device control, mixed-DPI and
monitor movement, sleep/wake and device recovery, update/rollback/uninstall, and
the public-release checks in [RELEASE-CHECKLIST.md](docs/RELEASE-CHECKLIST.md).

## M0: source and reproducibility

Preserve upstream attribution, pin Windows Quickshell, and report the local
toolchain.
Keep configuration and state isolated. Record the source revisions and exact
commands for every build. Do not distribute a binary before its sources and
dependencies are accounted for.

The pinned backend and portable plugins build with the native toolchain in
[NATIVE-BUILD.md](NATIVE-BUILD.md). Build scripts record source revisions, tool
versions, prerequisite results and commands under `windows/.local/build/logs`.

## M1: Caelestia compatibility

Load Caelestia's own bar and drawers in an explicit entry point with unsupported
services disabled through platform boundaries. Preserve upstream components
rather than replacing them with lookalike rectangles.

Gate:

- No missing required QML imports, types, properties or signals.
- Bar and drawers render with the intended shader and animation behavior.
- Original configurable hover interactions, pointer regions, keyboard focus,
  dismissal and focus return work.
- 150% and 175% DPI, negative monitor origins, and transparency off are tested.
- Startup and shutdown leave the existing shell, taskbar, tiler, autostart and
  user configuration untouched.
- Build commands, runtime and source versions, screenshots, logs, and disabled
  or unsupported features are recorded.

## M2: Windows services

Adapt public service interfaces to the backend's Windows implementations:
audio, media, notifications, network, Bluetooth, power, brightness, application
catalog, tray and session actions. Audit Linux process calls and filesystem
assumptions. Use Windows' secure lock screen and UAC. Validate missing hardware
and denied access without retry loops or privilege changes.

Gate: services can be enabled individually, report explicit unavailable states,
and produce no unexpected startup side effects. Read-only observation and
mutating controls are separate opt-ins.

## M3: windows, workspaces and tiling

Validate the backend's Hyprland-compatible operations against the Caelestia UI.
Keep one tiler active. Test real applications with minimum-size constraints,
modal move/resize, rapid launch/close, focus changes, maximize/restore, and
mixed-DPI monitor transfer. Treat DWM behavior as a Windows boundary rather than
assuming compositor-level control over other applications.

Gate: no overlapping tiled windows, accidental floating, lost focus or unbounded
correction loop during the recorded scenarios. When fitting is impossible, the
UI explains the outcome.

## M4: complete shell and packaging

Package pinned Qt, backend and plugin dependencies, fonts and license notices.
Provide reversible per-user installation, startup options, updates, rollback and
uninstall.

Gate: a clean Windows 11 profile passes installation, startup, multi-monitor,
sleep/wake, device recovery, update, rollback and uninstall checks, and the
release checklist completes without changing repository visibility outside the
maintainer's approval.
