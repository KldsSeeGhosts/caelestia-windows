# Windows port

The goal is Caelestia's original shell experience on Windows, retaining its QML
components and motion while adapting platform services. The dependency is the
Windows Quickshell fork used by ii-windows. Hyprland itself remains a Linux
Wayland compositor; Windows continues to own application composition through DWM.

## Current state

- The full Caelestia source history is retained, based on the revision in
  [sources.lock.json](sources.lock.json).
- The Windows Quickshell source is pinned as `windows/deps/quickshell`.
- The pinned backend and eight portable Caelestia plugin modules build natively
  with clang-cl and Qt 6.11.2. See [native build instructions](NATIVE-BUILD.md).
- An isolated component probe renders the original bar clock, dashboard clock,
  blob surfaces, rounded mask, and motion in an ordinary application window.
  Automated rendering checks pass at device pixel ratios 1, 1.5, and 1.75.
  [Recorded results and screenshots](validation/2026-10-25-component-probe/README.md)
  document the tested sources and limits.
- This is a component compatibility result. The full bar and drawer are not
  ported, and the upstream `shell.qml` still starts Linux-specific services.
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

## Portable build and component probe

`CAELESTIA_PORTABLE_UI=ON` builds `Caelestia`, `Settings`, `Components`, `Config`,
`State`, `Blobs`, `I18n`, and `Shaders`. It excludes the calculator, Models,
Services, Images, and Multimedia. The full Linux build remains the default on
Linux. Windows defaults to plugins only and rejects installation of the
unadapted upstream shell.

Windows adaptations include DLL export/import declarations for shared Qt
metadata, generated forwarding headers that need no symlink privileges, and
HLSL shader generation. Optional SPIR-V optimization is omitted on Windows
because it requires a separate `spirv-opt` executable.

The probe stages an explicit subset of original QML files without modifying
them. Its fixed palette adapter bypasses wallpaper analysis and Hyprland rules.
Only the body font is bundled; the clock icon is disabled. This does not validate
the full font set, dynamic theme service, or any Windows system service.

Build and run through the scripts in [NATIVE-BUILD.md](NATIVE-BUILD.md). Output,
configuration, state, and screenshots default to ignored `windows/.local/build`.
The child process receives `CAELESTIA_CONFIG_DIR`, `CAELESTIA_STATE_DIR`, and
`CAELESTIA_RUNTIME_DIR`; ordinary Linux runs retain their standard paths.
Quickshell's own instance bookkeeping remains in its Windows application
directory, with the probe identified by its separate configuration path.

## Next compatibility work

1. Audit the dependencies of `modules/bar/Bar.qml`, `modules/drawers/ContentWindow.qml`,
   and `modules/drawers/Panels.qml`. Add platform boundaries for the services
   they actually instantiate, preserving their existing QML interfaces.
2. `components/containers/StyledWindow.qml` and the drawer module use
   `Quickshell.Wayland`; the drawer also uses `Quickshell.Hyprland`. Check the
   exact types, properties, and signals Caelestia needs against the pinned
   backend. Matching import names do not prove API parity.
3. Load the real bar and one drawer through an isolated entry point. Validate
   pointer regions, keyboard focus, dismissal, and focus return, then the
   remaining [M1 gates](ROADMAP.md#m1-actual-caelestia-compatibility-prototype).
4. Audit Linux process calls and filesystem assumptions before enabling each
   service. For example, `services/Brightness.qml` still invokes `ddcutil`,
   `brightnessctl`, and `sh`.

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
