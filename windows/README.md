# Windows port

The goal is Caelestia's original shell experience on Windows, retaining its QML
components and motion while adapting platform services. The dependency is the
Windows Quickshell fork used by ii-windows. Hyprland itself remains a Linux
Wayland compositor; Windows continues to own application composition through DWM.

## Current state

For the next development session, start with [HANDOFF.md](HANDOFF.md).

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
- Native 150% pointer tests have demonstrated bar hover, Power opening,
  Escape dismissal with focus return, and outside-click pass-through with
  dismissal. The same native window also passed 150% primary -> 175%
  negative-origin secondary -> primary transfer at 900x620 without QML
  diagnostics. Synthetic 100%, 150%, and 175% rendering also passes;
  [bar/session validation](validation/2026-10-25-bar-session/README.md) owns exact
  results and limitations. M1 remains open.
- The earlier ordinary-window [component probe](prototype/README.md) remains
  available, with [archived synthetic 100%, 150%, and 175% results](validation/2026-10-25-component-probe/README.md).
- Inherited GitHub Actions are disabled at repository level during bootstrap.
  They are upstream Linux workflows, not validation of this port.

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
`State`, `Blobs`, `I18n`, and `Shaders`, plus `Caelestia.Windows` on Windows.
It excludes the calculator, Models, upstream Services, Images, and Multimedia.
The isolated session service is an unavailable QML adapter that consumes
actions without executing them. Linux retains its default module set.
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
ERM-493/494 remain in progress. Investigate the recorded single-jump hover
case, then complete native 175% input, rapid boundaries, keyboard/drag,
system-transparency-off and remaining lifecycle tests. The remaining
[M1 gates](ROADMAP.md#m1-actual-caelestia-compatibility-prototype) remain open.
The tested fixed palette is opaque and backend blur is disabled, while Windows
EnableTransparency remains 1; this is not a system-transparency-off test.
M2-M4 have not started; dynamic themes, hardware-denial handling and Windows
services are not validated.

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

Keep the source manifest and submodule revision in agreement. Review backend
updates before moving the gitlink; keep backend patches in a dedicated fork
when needed. Preserve the dependency's license and notices. The original
Caelestia license remains in the root `LICENSE`.

References inspected for this setup:

- [Caelestia source baseline](https://github.com/caelestia-dots/shell/tree/2e1c51fa76d94457624b642c678218970aa2517a)
- [Windows Quickshell backend](https://github.com/nunreasonable/quickshell/tree/e8ae0ef124b1c14b547c80d00422d2ffbd423d81/src/windows)
- [ii-windows source pins](https://github.com/nunreasonable/ii-windows/blob/b59ac3b1389c1d562bec8a81aa3f6fb6480ca6b1/sources.lock)
- [ii-windows porting notes](https://github.com/nunreasonable/ii-windows/blob/b59ac3b1389c1d562bec8a81aa3f6fb6480ca6b1/docs/PORTING.md)
