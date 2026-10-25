# Caelestia Windows milestones

The native backend build and portable component rendering are now demonstrated.
Gates below are acceptance criteria, not claims of a complete shell.
[Caelestia Windows in Linear](https://linear.app/ermin-zeherovic/project/caelestia-windows-c69c05fa35b7)
tracks the milestones and implementation issues.

## Status snapshot, 2026-10-25

- M0: local developer bootstrap complete. Backend pin, native build commands,
  isolated probe configuration, and validation evidence are recorded.
- M1: complete for the bounded original bar/session prototype. The native
  hover handoff is fixed. Two clean 36-scenario input matrices pass at native
  150%/175%, with transparency on and off, plus rendering and lifecycle checks.
  [Final evidence and limits](validation/2026-10-25-m1-acceptance/README.md)
  include the rejected preliminary desktop-wide notification test.
- M2: in progress. ERM-495 audits all service contracts; ERM-496/497 implement
  isolated opt-in audio and truthful native control errors; ERM-499 adds the
  read-only battery status slice with truthful absence on a batteryless
  desktop. Remaining service integrations are ERM-498 and ERM-500 through
  ERM-507; ERM-508 owns real audio control/denial/recovery. M3/M4 have not
  started.

Continue from [HANDOFF.md](HANDOFF.md). Linear was connected and synchronized
on 2026-10-25 under the Ermin Zeherovic (ERM) team. This roadmap owns detailed
acceptance criteria; Linear tracks issue status and dependencies.

Completed issues are ERM-489 (M0 bootstrap), ERM-490 (component probe),
ERM-491 (dependency/backend audit), ERM-492 (original bar/session loading),
ERM-493 (input/focus) and ERM-494 (final compatibility gate).
M1 work was sequenced as:

1. [ERM-491: dependency and backend API audit](https://linear.app/ermin-zeherovic/issue/ERM-491), done.
2. [ERM-492: load the original bar and one drawer](https://linear.app/ermin-zeherovic/issue/ERM-492), done with archived evidence.
3. [ERM-493: hover, input, focus, and dismissal](https://linear.app/ermin-zeherovic/issue/ERM-493), done.
4. [ERM-494: native DPI, monitor, transparency, and lifecycle gate](https://linear.app/ermin-zeherovic/issue/ERM-494), done.

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

The [native bar/session prototype](shell-prototype/README.md) loads
original ContentWindow/StyledWindow, Regions/Interactions, Bar/Clock/Power and
Session.Wrapper/Content. Fixed palette and explicit unavailable adapters keep
unsupported services out; process-local fonts preserve original icons.
WindowsFocusGuard provides bounded native activation/restoration policy.
Drawers/Exclusions and Taskbar/Tiling controllers are not instantiated.

Status: complete. Clean `24229c9a` passes 72 recorded native input scenarios
across the 150% primary and 175% negative-origin secondary, including stationary
hover, rapid crossings, original bar pin/unpin and session drag, keyboard,
Escape/focus return, outside-click pass-through, early app switching and
repeated open/close. The same window preserves 900x620 geometry through
150% -> 175% -> 150%. Clean synthetic 100%/150%/175% rendering and a separate
175% -> 150% -> 175% native cycle also pass without QML diagnostics.

Actual transparency-off startup is verified by both the Windows preference
and `UISettings.AdvancedEffectsEnabled`, then restored. Both final input runs
preserve the existing shell PID, work areas and taskbar flags. A preliminary
desktop-wide settings broadcast exposed a separate KSG Shell panic; that run
was rejected and the installed shell restored. Live global reconfiguration of
other shells is not certified. The
[final acceptance record](validation/2026-10-25-m1-acceptance/README.md) owns
exact versions, sources, commands, failures, passing evidence and limits.
The earlier bar/session archive and older
[component validation record](validation/2026-10-25-component-probe/README.md)
continue to describe only their own source revisions.

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

Current slice: [original audio controls and Core Audio adapter](audio-prototype/README.md),
followed by the [read-only battery status slice](battery-prototype/README.md).
Native observation, injected failure handling and real writes/recovery are
distinct validation claims. The [source audit](audits/M2-SERVICES.md) records
all service gaps, Linux process/path boundaries and staged acceptance work.
Audio and battery default disabled; observation requires separate
child-process opt-ins and the battery slice performs no writes. Other services
remain unavailable.

ERM-495/496/497 are complete for the bounded audio slice. Clean `fb6665ab`
passes 238 adapter assertions, 16 native fake-COM cases, native 150%/175%
disabled/read-only UI and M1 smoke regression with unchanged endpoint/default
and shell/work-area/taskbar state.
[Evidence and limits](validation/2026-10-25-m2-audio/README.md) distinguish
those checks from ERM-508's remaining live controls/denial/recovery.

ERM-499 is bounded-complete for read-only battery status. Clean `41cf6aae`
passes 94 adapter assertions, native 150%/175% disabled/read-only UI on a
batteryless desktop with truthful absence rendering, unchanged base scheme,
overlay scheme and desktop state, the M1 smoke regression and a full audio
harness re-run. Battery-present hardware, overlay/profile writes and
IdlePower remain unvalidated by design;
[evidence and limits](validation/2026-10-25-m2-battery/README.md) record the
fixture-only coverage for battery-present behavior. M2 remains incomplete:
ERM-498 (media) and the remaining service tickets are next.

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
