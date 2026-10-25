# Windows port

The goal is Caelestia's original shell experience on Windows, retaining its QML
components and motion while adapting platform services. The dependency is the
Windows Quickshell fork used by ii-windows. Hyprland itself remains a Linux
Wayland compositor; Windows continues to own application composition through DWM.

## Current state

- The full Caelestia source history is retained, based on the revision in
  [sources.lock.json](sources.lock.json).
- The Windows Quickshell source is pinned as `windows/deps/quickshell`.
- Windows setup guidance, compatibility gates, and a read-only prerequisite
  report are present.
- There is no validated Windows Caelestia build or runnable bar/drawer prototype
  yet. The upstream `shell.qml` still starts Linux-specific services.
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

## Compatibility work to do first

These are source findings, not completed porting work:

1. `plugin/CMakeLists.txt` requires Qt DBus, PipeWire, Aubio, Cava, libqalculate,
   and a sensors library. Split portable UI modules from platform services
   before attempting a complete Windows plugin build.
2. The Blobs and Components shader declarations currently specify `NOHLSL`.
   Verify shader generation and rendering on the Windows Qt Quick backend.
3. `services/Brightness.qml` invokes `ddcutil`, `brightnessctl`, and `sh`.
   Audit all startup daemons and services for Linux commands and filesystem
   assumptions. Adapt their interfaces to Windows services.
4. `components/containers/StyledWindow.qml` and the drawer module use
   `Quickshell.Wayland`; the drawer also uses `Quickshell.Hyprland`. Check the
   exact types, properties, and signals Caelestia needs against the pinned
   backend. Matching import names do not prove API parity.
5. The upstream entry point starts background, drawers, area picker, lock, and
   daemons together. The first Windows entry point must load a small audited
   subset with isolated state and no desktop takeover.

No Qt runtime, Qt development tools, CMake, Ninja, or C++ compiler was available
on PATH during bootstrap. The environment report is the current source of truth
for subsequent machines.

## Toolchain direction

ii-windows documents a Linux cross-build using clang-cl/xwin and Windows Qt.
That is a reference route, not a build verified by this project. If used here,
run its Linux steps inside Ubuntu-24.04 under WSL2. A native Windows build needs
its own verified CMake preset and compiler/Qt package selection. Do not copy
Linux setup commands into a native PowerShell session.

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
