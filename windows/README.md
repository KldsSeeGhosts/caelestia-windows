# Windows port

The goal is Caelestia's original shell experience on Windows, retaining its QML
components and motion while adapting platform services. The dependency derives
from the Windows Quickshell fork used by ii-windows. Hyprland remains a Linux
Wayland compositor; Windows continues to own application composition through DWM.

Caelestia exports its resolved appearance to the profile's
`state\caelestia\theme-tokens.json`. To use it in Glazier, set `theme_file`
in `%APPDATA%\Glazier\config.toml` to the absolute path of that file and
choose Glazier's Reload settings. The default profile is
`%LOCALAPPDATA%\caelestia-windows`; use the actual profile path if customized.
The file is updated when the scheme or appearance changes, and Glazier reads
it at the next capture. It contains versioned semantic colours, the UI font
and optional private font path, and rounding tokens.

## Credits and attribution

This port has three layers:

1. **The interface is Caelestia.** [Caelestia Shell](https://github.com/caelestia-dots/shell)
   by soramanew and contributors is GPL-3.0. About 69,000 lines of upstream UI
   are used nearly unchanged. At the maintainer's attribution snapshot, 75
   upstream files were touched, with about 1,500 lines added and 195 removed.
   The expressive shapes come from soramanew's
   [m3shapes](https://github.com/soramanew/m3shapes), Apache-2.0.
   Colour generation uses [Caelestia CLI](https://github.com/caelestia-dots/cli),
   GPL-3.0, with [materialyoucolor](https://github.com/T-Dynamos/materialyoucolor-python),
   MIT, and [Pillow](https://github.com/python-pillow/Pillow), HPND.
   Python is a required dependency for colour generation; its
   packages are installed at runtime into a profile-local virtual environment.
2. **The Windows platform support comes from Windows Quickshell.**
   [nunreasonable/quickshell](https://github.com/nunreasonable/quickshell),
   LGPL-3.0, was built for [ii-windows](https://github.com/nunreasonable/ii-windows),
   GPL-3.0, on top of outfoxxed's
   [Quickshell](https://git.outfoxxed.me/quickshell/quickshell), LGPL-3.0.
   It already supplied about 66,000 lines of Windows code: native layer
   windows, AppBar integration, hotkeys, tiling, virtual desktops, Core Audio,
   Bluetooth, notifications and toast mirroring, tray hooks, brightness and
   gamma, GSMTC media, and UPower. Its vendored
   [Material Color Utilities](https://github.com/material-foundation/material-color-utilities)
   are Apache-2.0. The
   [Caelestia backend fork](https://github.com/KldsSeeGhosts/caelestia-quickshell-windows)
   adds about 9,200 lines and removes 800, including about 5,800 lines of tests.
   These figures describe the attribution snapshot, not a release guarantee.
3. **This repository connects those projects.** The Windows port adds service
   adapters, combined and production shell entries, build/stage/install and
   desktop takeover tools, documentation, plugin additions for focus guarding
   and a WASAPI visualizer, a scheme bridge, and Wallpaper Engine integration.
   The port retains Caelestia's GPL-3.0 license; backend changes retain the
   backend's LGPL-3.0 license. ii-windows was a packaging reference only;
   no ii-windows code was copied. Feature availability and validation depend
   on the checked-out revision; this attribution is not an acceptance report.

The runtime uses dynamically linked [Qt 6](https://www.qt.io/development/qt-framework),
LGPL-3.0, deployed with `windeployqt`. Fonts are
[Google Sans Flex](https://github.com/googlefonts/googlesans-flex),
[Rubik](https://github.com/googlefonts/rubik), and
[Cascadia Code](https://github.com/microsoft/cascadia-code) as
[CaskaydiaCove Nerd Font](https://github.com/ryanoasis/nerd-fonts),
all SIL OFL 1.1; [Material Symbols](https://github.com/google/material-design-icons)
are Apache-2.0 and [Nerd Fonts Symbols](https://github.com/ryanoasis/nerd-fonts)
are MIT. Adapted desktop COM interface definitions come from
[MScholtes/VirtualDesktop](https://github.com/MScholtes/VirtualDesktop), MIT.
Copyright holders, license files, and installation locations are listed in
[THIRD-PARTY-NOTICES.md](../THIRD-PARTY-NOTICES.md).

The Windows port was built with substantial AI assistance: Claude
orchestrated the work, and GPT, GLM, DeepSeek, and Gemini agents implemented
parts of it. The maintainer directed and reviewed the work. This describes
the port, not the authorship of the upstream projects.

## Current state

For working rules and the live-install procedure, see [AGENTS.md](../AGENTS.md).
Open work is tracked in GitHub issues and the Linear project.

The combined graph now also has an [all-monitor Windows shell entry](shell/README.md)
with persistent profiles and per-user installation. See [REPORT.md](../REPORT.md)
for commands and the limits of its quick installation smoke.

- The full Caelestia source history is retained, based on the revision in
  [sources.lock.json](sources.lock.json).
- The Windows Quickshell source is pinned as `windows/deps/quickshell`.
- Material 3 Expressive shapes come from the pinned external
  `windows/deps/m3shapes` QML plugin at the same revision as Caelestia's
  `flake.lock`. It is not an in-repo `plugin/` module: upstream split it out in
  `caelestia-dots/shell` 24aa15ee. The portable build compiles it with the same
  Qt/clang-cl toolchain and installs the `M3Shapes` module for the combined shell.
- The pinned backend, eight portable Caelestia modules, the M3Shapes module, and
  Windows-only `Caelestia.Windows` focus helper build with Qt 6.11.2 and
  clang-cl 20.1.8. See [native build instructions](NATIVE-BUILD.md).
- The [bar/session prototype](shell-prototype/README.md) loads the original
  `ContentWindow`, `StyledWindow`, `Regions`, `Interactions`, bar Clock/Power,
  and session content/wrapper in a bounded native window. Original blob
  surfaces, motion, and icons render through isolated adapters.
- M1 is complete for the bounded prototype. The native hover handoff is fixed,
  and 72 clean native input scenarios pass at 150%/175% with transparency on
  and off. Rendering, both monitor-cycle origins and lifecycle checks pass.
  [Final acceptance](validation/2026-10-25-m1-acceptance/README.md) records the
  evidence, limits and rejected preliminary KSG Shell notification failure.
- The earlier ordinary-window [component probe](prototype/README.md) remains
  available, with [archived synthetic 100%, 150%, and 175% results](validation/2026-10-25-component-probe/README.md).
- M2 has started with an [opt-in audio prototype](audio-prototype/README.md).
  It preserves the original audio controls and core public service API.
  Disabled/read-only modes, hardware/failure fixtures and native observation
  are separate from live write/recovery validation. Other services remain off.
  The [first M2 acceptance archive](validation/2026-10-25-m2-audio/README.md)
  records clean-source two-monitor results and unchanged audio/desktop state.
- A second M2 slice adds a strictly read-only
  [battery status prototype](battery-prototype/README.md). It preserves the
  original battery status icon and popout content, projects the native UPower
  display device through a QtObject adapter with no mutating methods, and
  keeps PowerProfiles and IdlePower writes out of the process. A system
  without a battery renders the truthful absent state. The
  [corrected M2 battery archive](validation/2026-10-25-m2-battery-review/README.md)
  records 128 adapter assertions, 9 native fake-status cases, batteryless
  native 150%/175% results and unchanged scheme/overlay/desktop state.
  Native read, presence, charge and AC-source validity distinguish unknown
  observations from a measured zero or proven absence. Real battery
  hardware and the remaining profile/write gates keep ERM-499 open.
- The inherited upstream Linux GitHub workflows were removed; they did not
  validate this port. Windows CI is planned before publication.
- An opt-in [media prototype](media-prototype/README.md) loads the original
  dashboard player details. Native lifecycle status distinguishes unavailable
  observations from a healthy empty session list, and artwork caching honors
  the isolated profile. Clean native 150%/175% runs observed no open sessions;
  [media evidence](validation/2026-10-25-m2-media/README.md) separates those
  results from fixture-only real-player behavior. ERM-498 remains open.
- A default-off [app catalog prototype](apps-prototype/README.md) loads the
  original launcher app list and search bar over the Windows AppsFolder
  enumeration. Explicit disabled/scanning/empty/failed/ready states, the
  original fzf/smart-case search prefixes and profile-local JSON launch
  frequencies replace the excluded AppDb/SQLite store. Enumeration and search
  never launch; `CAELESTIA_WINDOWS_APP_LAUNCH` is a separate opt-in and terminal
  entries stay unsupported. Native smoke records a 153-application catalog and
  a search sample without launching anything;
  [apps evidence](validation/2026-10-25-m2-apps/README.md) records the fixture
  and read-only limits, the backend scan/command gaps and the untested
  interactive path. ERM-505 remains open.
- A default-off [Windows session service](services/session/README.md) maps only
  an explicit allowlist of lock/logout/shutdown/reboot/suspend/hibernate/
  firmware commands, consumes unknown commands without a detached fallback, and
  exposes requested-not-succeeded results. Observation and dispatch are
  separate opt-ins; smoke forces dispatch off and destructive actions require
  an explicit confirmation the original UI does not yet supply. Native
  Disabled/Observe runs never invoke a session action.
  [Session evidence](validation/2026-10-25-m2-session/README.md) records the
  fixtures, both native modes and shared regressions.
- A bounded, default-off [tray prototype](tray-prototype/README.md) stages the
  original bar tray icons, `ColouredIcon` tinting and menu component. Read-only
  observation keeps `QS_WINDOWS_TRAY_HOOK=0`, so the backend cannot enumerate
  items and native smoke reports the tray as not observable; semantic menus are native-only and activation is a separate
  opt-in. [Tray evidence](validation/2026-10-25-m2-tray/README.md) records 115
  adapter assertions, Disabled/ReadOnly runs at 150%/175%, a three-icon fixture
  preview, and unchanged Explorer/taskbar state. Live items, activation and
  interception ownership remain unvalidated.
- A default-off [Hyprland adapter prototype](hypr-prototype/README.md) covers
  M3-2 stages 0-3 for the bar workspace and active-window components.
  `CAELESTIA_WINDOWS_HYPR=1` observes the pinned backend's Hyprland data;
  `CAELESTIA_WINDOWS_HYPR_DISPATCH=1` separately permits an allowlist of
  workspace/move/graceful-close dispatches. Special-workspace UI stays inactive,
  the backend's global focused workspace is documented per monitor, and the
  `killwindow` translation is a graceful `WM_CLOSE`. No `Tiling`, `WindowManager`
  or `Taskbar` object is constructed. The fixture covers default-off
  construction, mapping, the global-focus limitation, every allowlisted and
  refused dispatch form and injection attempts. Only the native Disabled mode
  is recorded; native Observe/Dispatch and the original components against a
  live desktop remain untested.
- A default-off [tiling slice](tiling-prototype/README.md) grounds M3-2 stages
  4/5 and the M3-3 fitting-failure explanation.
  `CAELESTIA_WINDOWS_TILING=off|observe|interactive` gates everything: `off`
  never imports the backend `Tiling` singleton, `observe` constructs and
  applies `included`/`excluded` options with `enabled` false, and `interactive`
  may enable only with a non-empty allowlist (`CAELESTIA_WINDOWS_TILING_INCLUDED`)
  on a backend that supports one — smoke forces it down to observe. Fitting
  failures are explained through the original toast surface with per-reason
  copy and both rate limits. The shared build pins a backend without the
  allowlist/telemetry members, so every new member is feature-detected and
  interactive truthfully refuses. The fixture covers both backend shapes
  (139 assertions); [tiling evidence](validation/2026-10-25-m3-tiling-slice/README.md)
  records the Disabled-only native runs and leaves all Observe/Interactive
  native behavior to the orchestrator's live plan.

## Checkout and inspect

```powershell
git clone --recurse-submodules https://github.com/KldsSeeGhosts/caelestia-windows.git
cd caelestia-windows
powershell -NoProfile -File windows/scripts/Test-Environment.ps1 -Json
```

For an existing checkout:

```powershell
git submodule update --init --recursive
```

The report checks the source pin, Windows version, and tools available in the
current process. Optional `-QtPrefix` and `-QuickshellExecutable` paths let it
inspect an existing installation without changing PATH or installing software.
Use `-Strict` to return a failing exit code when required prerequisites are
missing. Tool availability does not mean Caelestia's Windows adapters are ready.

No runtime, SDK, compiler, installer, or authentication change is performed by
these commands. The submodule command downloads source only.

## Portable build and isolated prototype

`CAELESTIA_PORTABLE_UI=ON` builds `Caelestia`, `Settings`, `Components`, `Config`,
`State`, `Blobs`, `Images`, `I18n`, and `Shaders`, plus `Caelestia.Windows` on
Windows. It excludes the calculator, Models, upstream Services, and Multimedia.
`Images` is Qt-only (Quick/Concurrent) and is retained because the original
`ColouredIcon` tray icon tinting imports `Caelestia.Images`. The isolated
session service defaults to unavailable; opt-in observation loads
`Quickshell.Windows.Session` for capability reporting only, and a separate
opt-in permits allowlisted non-destructive dispatch. Unknown commands are
consumed without detached execution. Linux retains its default module set.
Windows rejects installation of the unadapted upstream shell.

Windows adaptations include DLL export/import declarations for shared Qt
metadata, generated forwarding headers that need no symlink privileges, and
HLSL shader generation. Optional SPIR-V optimization is omitted on Windows
because it requires a separate `spirv-opt` executable.

The native prototype stages an explicit original QML subset with a fixed
palette and nonvisual unavailable adapters. Material 3 shape components now use
the real `M3Shapes.MaterialShape` item, including path queries and morphing,
instead of the former neutral round-surface shim. Localized upstream changes use
the window's direct `exclusionMode`, keep drag padding finite with no monitor,
and gate input/gestures and keyboard focus. `interactionEnabled` defaults to
true; the profile enables no-input smoke tests without changing normal Linux
defaults. Bundled [Rubik and Material Symbols fonts](assets/README.md) include
pinned provenance and licenses and are loaded only into the prototype process.

Build and run through the scripts in [NATIVE-BUILD.md](NATIVE-BUILD.md). Output,
configuration, state, and screenshots default to ignored `windows/.local/build`.
The child process receives `CAELESTIA_CONFIG_DIR`, `CAELESTIA_STATE_DIR`, and
`CAELESTIA_RUNTIME_DIR`; ordinary Linux runs retain their standard paths.
The native entry point skips Drawers/Exclusions and does not instantiate
Taskbar or Tiling controllers. The active `ksg-shell` is left running.
The backend still provides native support for its own window, maintains
Quickshell instance bookkeeping, and runs shared stale-AppBar startup cleanup.
Isolation does not mean zero global backend bookkeeping.

## Next compatibility work

ERM-491's [dependency](audits/M1-DEPENDENCIES.md) and
[backend API](audits/M1-BACKEND-API.md) audits are complete in `f1d3a020`.
ERM-492's original bar/session loading and evidence archive are complete.
ERM-493/494 are complete with clean native input and final acceptance evidence.
The backend fork fixes mask handoff without replacing the original interaction
paths. M2's [service audit](audits/M2-SERVICES.md) sequences ERM-495 through
ERM-508. Audio integration and truthful backend control errors are the first
slice; remaining services, actual hardware-denial/recovery, dynamic themes,
M3 and M4 remain unvalidated.

## Toolchain direction

The verified initial route uses native Windows clang-cl, Visual Studio's C++
tools and Windows SDK, Ninja, and Windows Qt. Tool discovery in an ordinary
PowerShell session can still report missing tools because the development
environment is loaded only inside the build script's process.

ii-windows also documents a Linux cross-build using clang-cl/xwin and Windows
Qt. That remains a reference route, not a build verified by this project. Run
its Linux steps inside Ubuntu-24.04 under WSL2 if investigating it.

Do not run the root Linux installation instructions or an upstream installer
as a Windows bootstrap step. The first packaging milestone comes after the
isolated prototype passes.

## Dependency maintenance

The current backend pin is in the private
[Caelestia backend fork](https://github.com/KldsSeeGhosts/caelestia-quickshell-windows/tree/c0e748c815e516ad8e8157eb1132a0bc14a15368).
It retains the audited `nunreasonable/quickshell` baseline `e8ae0ef1` and adds
a native mask handoff change: reconcile Qt hover when `WS_EX_TRANSPARENT`
changes, because the move that triggered the hook can already have reached the
underlying window. The patch queues only local Qt enter/leave notifications, avoids
enter reconciliation while mouse buttons are held or another window covers
the point, and injects no system input or focus changes.

The M2 patch additionally reports Core Audio control/state capability and
HRESULT failures. It retains snapshots on failed reads and reads back actual
default routing after partial role failures. See
[backend PR #1](https://github.com/KldsSeeGhosts/caelestia-quickshell-windows/pull/1).

[Backend PR #2](https://github.com/KldsSeeGhosts/caelestia-quickshell-windows/pull/2)
adds UPower read/presence/charge/source validity and stale-value clearing.
Unknown AC source supplies neither a discharging state nor a time estimate.
The root gitlink and source manifest use the pushed implementation revision;
the backend PR remains open.

[Backend PR #3](https://github.com/KldsSeeGhosts/caelestia-quickshell-windows/pull/3)
adds GSMTC initialization/session-scan status and isolates artwork writes and
pruning to the shell profile cache. It is stacked on backend PR #2; the root
media integration is [PR #7](https://github.com/KldsSeeGhosts/caelestia-windows/pull/7).

[Backend PR #8](https://github.com/KldsSeeGhosts/caelestia-quickshell-windows/pull/8)
adds one system-surface classification for the Windows task switcher, Task
View, Start/Search flyouts, foreground staging and cloaked windows. Shell
surfaces cannot become tracked toplevels, foreground applications or AppBar
fullscreen seeds; `Windows.UI.Core.CoreWindow` is a system surface only under
explorer or a shell host. A shell cloak keeps its mapped tile, while an app or
inherited cloak publishes hidden and releases the tiled space like a minimize
without ending the fullscreen episode. Every deferred AppBar opening carries a
generation, so a rapid close/reopen keeps its retries. The Alt+Tab Task
Switching overlay classes, including MultitaskingViewFrame and
TaskSwitcherOverlayWnd, are rejected before they can become toplevels, so
Windows placing the switcher on the primary display no longer hides only that
monitor's frame. The root gitlink and source manifest use the pushed revision;
the PR remains a draft.

Keep the source manifest and submodule revision in agreement. Review backend
updates before moving the gitlink; keep backend patches in a dedicated fork
when needed. Preserve the dependency's license and notices. The original
Caelestia license remains in the root `LICENSE`.

References inspected for this setup:

- [Caelestia source baseline](https://github.com/caelestia-dots/shell/tree/2e1c51fa76d94457624b642c678218970aa2517a)
- [Windows Quickshell backend](https://github.com/nunreasonable/quickshell/tree/e8ae0ef124b1c14b547c80d00422d2ffbd423d81/src/windows)
- [ii-windows source pins](https://github.com/nunreasonable/ii-windows/blob/b59ac3b1389c1d562bec8a81aa3f6fb6480ca6b1/sources.lock)
- [ii-windows porting notes](https://github.com/nunreasonable/ii-windows/blob/b59ac3b1389c1d562bec8a81aa3f6fb6480ca6b1/docs/PORTING.md)
