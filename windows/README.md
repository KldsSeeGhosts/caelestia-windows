# Windows port

Caelestia for Windows brings the original [Caelestia Shell](https://github.com/caelestia-dots/shell) desktop experience to Windows 11. It keeps Caelestia's QML components, `M3Shapes` geometry, shaders, and spring curves, while swapping the Linux/Hyprland platform hooks for native Windows APIs through the Windows Quickshell backend originally built for [ii-windows](https://github.com/nunreasonable/ii-windows). Hyprland stays on Linux; on Windows, DWM still owns window compositing.

The production entry point is [`windows/shell/shell.qml`](shell/shell.qml), staged
through [`windows/shell/sources.json`](shell/sources.json). The install and
build scripts package that tree per user; no developer build directory or test
fixture is part of the installed shell.

Caelestia exports its resolved appearance to the profile's
`state\caelestia\theme-tokens.json`. The shell starts its bundled Glazier with
`--theme-file` pointing at that file, so screenshots and recordings follow the
current scheme without editing `%APPDATA%\Glazier\config.toml`. The default
profile is `%LOCALAPPDATA%\caelestia-windows`; use the actual profile path if
customized. The file is updated when the scheme or appearance changes, and
Glazier reads it at the next capture. It contains versioned semantic colours,
the UI font and optional private font path, and rounding tokens. A standalone
Glazier can still opt in with `theme_file` in its own `config.toml`.

## Current state

The integrated shell provides:

- The original vertical bar, drawers, dashboard, launcher, notifications, OSDs
  and session surface, with native AppBar reservation and multi-monitor support.
- Windows services for audio, media, network, Bluetooth, power and battery,
  brightness, tray, notifications, application catalog, session actions and
  virtual desktops. Unavailable hardware and denied access report an explicit
  state instead of pretending to work.
- Opt-in DWM window tiling and workspace dispatch. Desktop takeover, autostart
  and tiling are never enabled by a fresh install.
- A versioned per-user installer, updater, rollback and uninstall that preserve
  the profile by default.

Build and smoke passes do not establish live desktop acceptance. Hardware
controls, device loss and recovery, sleep/wake, mixed-DPI movement and daily use
need the checks in [`docs/LIVE-CHECKLIST.md`](docs/LIVE-CHECKLIST.md). Historical
evidence stays under [`validation/`](validation/), but describes the revisions it
was recorded against, not a release guarantee.

## Documentation

- [User guide](docs/USER-GUIDE.md)
- [Configuration reference](docs/CONFIGURATION.md)
- [Keybinds reference](docs/KEYBINDS.md)
- [Native build](NATIVE-BUILD.md)
- [Release checklist](docs/RELEASE-CHECKLIST.md)
- [Roadmap and acceptance gates](ROADMAP.md)
- [Third-party notices](../THIRD-PARTY-NOTICES.md)

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
missing. Tool availability does not mean the Windows adapters are ready.

No runtime, SDK, compiler, installer, or authentication change is performed by
these commands. The submodule command downloads source only.

## Portable build and isolated prototype

`CAELESTIA_PORTABLE_UI=ON` builds `Caelestia`, `Settings`, `Components`, `Config`,
`State`, `Blobs`, `Images`, `I18n`, and `Shaders`, plus `Caelestia.Windows` on
Windows. It excludes the calculator, Models, upstream Services, and Multimedia.
`Images` is Qt-only (Quick/Concurrent) and is retained because the original
`ColouredIcon` tray icon tinting imports `Caelestia.Images`. Windows rejects
installation of the unadapted upstream shell.

Windows adaptations include DLL export/import declarations for shared Qt
metadata, generated forwarding headers that need no symlink privileges, and
HLSL shader generation. Optional SPIR-V optimization is omitted on Windows
because it requires a separate `spirv-opt` executable.

The portable prototype stages an explicit original QML subset with a fixed
palette and nonvisual unavailable adapters. Material 3 shape components use the
real `M3Shapes.MaterialShape` item, including path queries and morphing, instead
of a neutral round-surface shim. Localized upstream changes use the window's
direct `exclusionMode`, keep drag padding finite with no monitor, and gate
input/gestures and keyboard focus. Bundled [Rubik and Material Symbols fonts](assets/README.md)
include pinned provenance and licenses and are loaded only into the prototype
process.

Build and run through the scripts in [NATIVE-BUILD.md](NATIVE-BUILD.md). Output,
configuration, state, and screenshots default to ignored `windows/.local/build`.
The child process receives `CAELESTIA_CONFIG_DIR`, `CAELESTIA_STATE_DIR`, and
`CAELESTIA_RUNTIME_DIR`; ordinary Linux runs retain their standard paths. The
prototype entry point skips Drawers/Exclusions and does not instantiate Taskbar
or Tiling controllers.

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
   Python is a required dependency for colour generation; its packages are
   installed at runtime into a profile-local virtual environment.
2. **The Windows platform support comes from Windows Quickshell.**
   [nunreasonable/quickshell](https://github.com/nunreasonable/quickshell),
   LGPL-3.0, was built for [ii-windows](https://github.com/nunreasonable/ii-windows),
   GPL-3.0, on top of outfoxxed's
   [Quickshell](https://git.outfoxxed.me/quickshell/quickshell), LGPL-3.0.
   It already supplied about 66,000 lines of Windows code: native layer windows,
   AppBar integration, hotkeys, tiling, virtual desktops, Core Audio, Bluetooth,
   notifications and toast mirroring, tray hooks, brightness and gamma, GSMTC
   media, and UPower. Its vendored
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
   backend's LGPL-3.0 license. ii-windows was a packaging reference only; no
   ii-windows code was copied. Feature availability and validation depend on the
   checked-out revision; this attribution is not an acceptance report.

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

Parts of the Windows port were written with AI assistance under the
maintainer's direction and review. This describes the port, not the authorship
of the upstream projects.

## Toolchain direction

The supported native route uses Windows clang-cl, Visual Studio's C++ tools and
Windows SDK, Ninja, and Windows Qt. Tool discovery in an ordinary PowerShell
session can still report missing tools because the development environment is
loaded only inside the build script's process.

ii-windows also documents a Linux cross-build using clang-cl/xwin and Windows
Qt. That remains a reference route, not a build verified by this project. Run
its Linux steps inside Ubuntu 24.04 under WSL2 if investigating it.

Do not run the root Linux installation instructions or an upstream installer as
a Windows bootstrap step. The versioned per-user installer handles packaging;
see [the shell entry](shell/README.md).

## Dependency maintenance

The current backend pin is recorded in [`sources.lock.json`](sources.lock.json) in
the [Caelestia backend fork](https://github.com/KldsSeeGhosts/caelestia-quickshell-windows).
Blank weather location uses HTTPS IP geolocation (`ipapi.co`); set
`services.weatherLocation` in `shell.json` to use a fixed city or coordinates
instead.

The backend retains the audited `nunreasonable/quickshell` baseline and adds the
Windows fixes the shell depends on: hover reconciliation when
`WS_EX_TRANSPARENT` changes, truthful Core Audio control/state and failure
reporting, UPower read/presence/charge/source validity, GSMTC session status and
profile-isolated artwork caching, and system-surface classification for the
task switcher, Start/Search flyouts and cloaked windows.

Keep the source manifest and submodule revision in agreement. Review backend
updates before moving the gitlink; keep backend patches in the dedicated fork.
Preserve the dependency's license and notices. The original Caelestia license
remains in the root `LICENSE`.

References inspected for this setup:

- [Caelestia source baseline](https://github.com/caelestia-dots/shell)
- [Windows Quickshell backend](https://github.com/nunreasonable/quickshell/tree/e8ae0ef124b1c14b547c80d00422d2ffbd423d81/src/windows)
- [ii-windows source pins](https://github.com/nunreasonable/ii-windows/blob/b59ac3b1389c1d562bec8a81aa3f6fb6480ca6b1/sources.lock)
- [ii-windows porting notes](https://github.com/nunreasonable/ii-windows/blob/b59ac3b1389c1d562bec8a81aa3f6fb6480ca6b1/docs/PORTING.md)
