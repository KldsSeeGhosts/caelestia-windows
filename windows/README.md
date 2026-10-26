# Windows port

The goal is Caelestia's original shell experience on Windows, retaining its QML
components and motion while adapting platform services. The dependency derives
from the Windows Quickshell fork used by ii-windows. Hyprland remains a Linux
Wayland compositor; Windows continues to own application composition through DWM.

## Current state

For the next development session, start with [HANDOFF.md](HANDOFF.md).

The combined graph now also has an [all-monitor Windows shell entry](shell/README.md)
with persistent profiles and per-user installation. See [REPORT.md](../REPORT.md)
for commands and the limits of its quick installation smoke.

- The full Caelestia source history is retained, based on the revision in
  [sources.lock.json](sources.lock.json).
- The Windows Quickshell source is pinned as `windows/deps/quickshell`.
- The pinned backend, eight portable Caelestia modules, and Windows-only
  `Caelestia.Windows` focus helper build with Qt 6.11.2 and clang-cl 20.1.8.
  See [native build instructions](NATIVE-BUILD.md).
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
- Inherited GitHub Actions are disabled at repository level during bootstrap.
  They are upstream Linux workflows, not validation of this port.
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
palette and nonvisual unavailable adapters. Localized upstream changes use
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
[Caelestia backend fork](https://github.com/KldsSeeGhosts/caelestia-quickshell-windows/tree/1401042969e4b7ab3cfb314fc76945ab081db3de).
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

Keep the source manifest and submodule revision in agreement. Review backend
updates before moving the gitlink; keep backend patches in a dedicated fork
when needed. Preserve the dependency's license and notices. The original
Caelestia license remains in the root `LICENSE`.

References inspected for this setup:

- [Caelestia source baseline](https://github.com/caelestia-dots/shell/tree/2e1c51fa76d94457624b642c678218970aa2517a)
- [Windows Quickshell backend](https://github.com/nunreasonable/quickshell/tree/e8ae0ef124b1c14b547c80d00422d2ffbd423d81/src/windows)
- [ii-windows source pins](https://github.com/nunreasonable/ii-windows/blob/b59ac3b1389c1d562bec8a81aa3f6fb6480ca6b1/sources.lock)
- [ii-windows porting notes](https://github.com/nunreasonable/ii-windows/blob/b59ac3b1389c1d562bec8a81aa3f6fb6480ca6b1/docs/PORTING.md)
