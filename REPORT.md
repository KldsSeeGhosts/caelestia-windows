# Production Windows shell entry

Implemented on `t3/production-shell`, based on combined-modules
`6026f9475e99393be5d85c49b2367f1c36e3632e`.

The `shell-live` staging kind runs original Caelestia drawers on every monitor,
with Live service controls and no preview window. It adds persistent per-user
configuration, in-drawer session confirmation, path-selected quit/restart IPC,
and reversible per-user installation. AppBar, tiling, shortcuts, visualizer,
colours, shapes and background remain with their integration branches.
See [integration seams and profile details](windows/shell/README.md).

## Install and run

Run from this checkout in native PowerShell. No administrator rights are needed.
The installer reads the existing build and deploys Qt with `windeployqt`; it
does not modify or rebuild the supplied build tree.

```powershell
$build = 'D:\AiStack\caelestia-windows\windows\.local\build'
$qt = "$env:LOCALAPPDATA\caelestia-dev\Qt\6.11.2\msvc2022_64"
powershell -NoProfile -File windows/scripts/Install-Caelestia.ps1 `
    -BuildRoot $build -QtPrefix $qt

$app = "$env:LOCALAPPDATA\Programs\caelestia-windows"
& "$app\Start-Caelestia.ps1"
```

Alternatively open **Caelestia Windows** from Start. Before normal Live use,
quit ksg-shell through its own controls and disable its startup option when
switching shells. This installer leaves the existing shell/session intact.

Configuration is `%LOCALAPPDATA%\caelestia-windows\config\shell.json`.
The initial content matches the combined `-Live` configuration. Subsequent
launches and installations preserve it. State/cache/data/runtime directories
stay under the same profile. The launcher defaults to Live controls, including
tray interception; `-Smoke` is the read-only loading check.

`-QtPrefix` can be omitted when `BuildRoot/logs/build.json` records it.
Visual Studio's installed x64 CRT redistributable directory is discovered with
`vswhere`; supply `-VCRuntimeRoot <directory-containing-msvcp140.dll>` when
packaging with another toolchain layout. The CRT is deployed beside `qs.exe`,
so launching does not install a machine-wide redistributable.

## Quit, restart and inspect

```powershell
& "$app\Start-Caelestia.ps1" -Command State
& "$app\Start-Caelestia.ps1" -Command Restart
& "$app\Start-Caelestia.ps1" -Command Quit
```

Restart hard-reloads QML. Equivalent direct IPC, from the installation directory:

```powershell
& "$app\qs.exe" ipc --path "$app\shell\shell.qml" call shell quit
```

The session drawer's destructive actions require its Confirm button.
Closing the drawer cancels a pending confirmation.

## Opt-in startup and uninstall

Quit the installed shell before rerunning installation. To enable per-user
startup, rerun the installer with `-Autostart`:

```powershell
powershell -NoProfile -File windows/scripts/Install-Caelestia.ps1 `
    -BuildRoot $build -QtPrefix $qt -Autostart
```

This creates `HKCU\Software\Microsoft\Windows\CurrentVersion\Run\CaelestiaWindows`.
Omitting `-Autostart` never creates that entry; an existing opt-in survives an
update. Installation does not launch the shell.

```powershell
# Removes installation, Start-menu shortcut and its autostart entry; keeps profile.
& "$app\Uninstall-Caelestia.ps1"

# Instead, to also remove configuration/state/cache:
# & "$app\Uninstall-Caelestia.ps1" -Purge
```

Uninstall quits only this prefix's `qs.exe`. It leaves other shell/Quickshell
instances alone. `-Purge` must be selected during uninstall while the installation
record still exists. Repository `windows/scripts/Uninstall-Caelestia.ps1`
accepts the same `-Prefix` and `-Purge` parameters.

## Quick smoke

```powershell
$testRoot = Join-Path $env:TEMP 'caelestia-production-smoke'
powershell -NoProfile -File windows/scripts/Install-Caelestia.ps1 `
    -BuildRoot $build -QtPrefix $qt `
    -Prefix "$testRoot\app" -ProfileRoot "$testRoot\profile"
& "$testRoot\app\Start-Caelestia.ps1" -Smoke
powershell -NoProfile -File windows/scripts/Uninstall-Caelestia.ps1 `
    -Prefix "$testRoot\app" -Purge
```

Observed on Windows 11, 2026-10-26:

- Used the supplied existing Qt 6.11.2 / clang-cl 20.1.8 runtime, without a C++
  rebuild. Its build record identifies source
  `94611f87e7215f8113380f0d556d20814fbbff93`, `sourceDirty=true`, backend
  `525786fc81f13346cb196dca5ab356f89ad707a5`.
  `qs.exe` SHA-256:
  `9B518329FAC6B96973F4ECAA58A6CDFA5E413B6F9633A8F70345A706905F55AA`.
- Temporary deployed installation loaded two original drawer windows at
  2560x1440 and 2194x1234 logical pixels, matching their native 150% and 175%
  monitors. Both bars measured 60 logical pixels.
- Ten-second smoke printed `CAELESTIA_SHELL_LIVE_PASS`, with all ten reported
  control gates false and the tray hook off. No QML/runtime warnings or errors
  occurred in the passing run.
- Path-selected IPC state and hard restart worked during smoke. An edited
  `shell.json` survived restart, reinstallation and ordinary uninstall.
- Start-menu shortcut creation/removal and full prefix removal passed.
  Ordinary uninstall preserved the profile; `-Purge` removed it. Temporary
  startup integration was absent after cleanup. No `-Autostart` install was run.
  Uninstall also quit an active temporary smoke instance through `shell.quit`
  before removing its files.
- `windeployqt` reports the supplied Qt archive lacks translation catalogs;
  packaging explicitly excludes translations. Runtime loading succeeded using
  the deployed Qt/plugins and app-local CRT.
- `powershell -NoProfile -File windows/scripts/Test-Environment.ps1 -Json`
  confirms the backend pin matches. Its ordinary PowerShell environment reports
  missing CMake, Ninja, compiler and Qt tools on PATH, as expected without loading
  the developer environment. This prerequisite report is separate from the
  successful deployed-runtime smoke.

This is loading/installation smoke, not certification of live hardware writes,
monitor hotplug, sleep/wake, startup at sign-in, or daily-driver reliability.
No evidence archive was created, and the existing shell was left running.
