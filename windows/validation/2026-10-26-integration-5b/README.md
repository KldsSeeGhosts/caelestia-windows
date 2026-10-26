# Windows integration round 5b

Validated clean shell source `a009706a379cb49c9becb67ba4b7bdf857b1394b`
and backend `c1177c2771ecc3e9fd282449bdb08314576ca271`.
The subsequent archive/report commit changes documentation and evidence only.
This is build, bounded smoke and isolated packaging evidence, not a live shell
release or live AppBar/tiling acceptance.

## Integration and conflicts

Shell branch `t3/integration-5b` starts at round 5
`74bdad573d46cbc8110d3eb39904414b2fe180e6`.
Release docs `ca303fbe` merged cleanly as `dfc27c92`; installer license copying,
credits, notices, font licenses, contribution/templates and release checklist
are retained. Live fixes `31916c22` merged as `a009706a`.

Resolved live-fixes conflicts:

- `windows/combined-prototype/shell.qml`: unioned runtime probe and suspended
  sampler state with border reservation and application-fullscreen state.
- `windows/shell/shell.qml`: retained round 5's `active: !root.smoke` reservation
  gate and added the live fullscreen-release binding. Normal starts use all four
  exclusions. Smoke never reserves work areas.
- `windows/scripts/Start-Caelestia.ps1`: kept one direct smoke child and one normal
  supervisor path, removing the duplicate merge block. Retained isolated
  timeout handling, minimal deployed PATH, selected-screen support and cleanup
  limited to the exited child's stale AppBars.
- Quickshell gitlink and `windows/sources.lock.json`: moved together to the
  merged backend and retained both sets of provenance notes.

Backend `windows/integration-5b` starts at `457127d820ac1e48cd5c7c5454e8fef738e1a235`
and merges live fixes `b5d60be7b600cb22045db8b72b62ed34d44079c2` without conflicts.
It is pushed to the `caelestia` remote. Round 5's Explorer reconnection and
MTA-worker audio sessions remain alongside native keyboard layout/lock polling.
Existing feature validation archives arrived unchanged. Their trailing blank
log lines were left intact; source-file whitespace checks pass.

## Build and one combined smoke

Fresh output, including the backend, real M3Shapes and portable plugins:

```text
C:\Users\Ermin\.t3\worktrees\caelestia-windows\t3-88fb895a\windows\.local\build
```

From this worktree:

```powershell
$devRoot = Join-Path $env:LOCALAPPDATA 'caelestia-dev'
powershell -NoProfile -File windows/scripts/Test-Environment.ps1 -Json
powershell -NoProfile -File windows/scripts/Build-Prototype.ps1 `
    -QtPrefix "$devRoot\Qt\6.11.2\msvc2022_64" `
    -LlvmBin "$devRoot\clang+llvm-20.1.8-x86_64-pc-windows-msvc\bin" `
    -Cli11Include "$devRoot\deps\CLI11-2.5.0\include" `
    -ToolsBin "$devRoot\tools\Scripts"
powershell -NoProfile -File windows/scripts/Start-ShellPrototype.ps1 `
    -QtPrefix "$devRoot\Qt\6.11.2\msvc2022_64" -Combined -Smoke -Transparency
```

The ordinary prerequisite report lacks tools on PATH; the build script's isolated
VS environment passes its strict check. Qt 6.11.2, clang-cl 20.1.8, MSVC
14.44.35207, SDK 10.0.26100.0, CMake 4.4.4 and Ninja 1.13.2 are recorded in
`build/build.json`. Configure/build logs retain upstream policy, path-length and
compiler warnings. All native build commands exit successfully.

Exactly one combined smoke passes: exit 0, no timeout, 56.019 seconds, native
primary 150%, no runtime warning/error records. It resolves the Google Sans Flex
fonts, shows native `en` with Caps/Num false, loads the dynamic `#f9b7a3` palette
and 253-item Wallpaper Engine carousel, and passes the existing panel/service
boundary checks. Smoke does not enable tiling, tray interception, native writes,
desktop takeover or AppBar reservation. Screenshots and logs are in `combined/`.
No staged QML or per-run `sources.json` manifest is archived.

## Isolated packaging and actual prior-version update

```powershell
powershell -NoProfile -File windows/scripts/Test-InstallLicenses.ps1 `
    -BuildRoot "$PWD\windows\.local\build" `
    -QtPrefix "$env:LOCALAPPDATA\caelestia-dev\Qt\6.11.2\msvc2022_64"
```

The existing license test passes install, update and uninstall. It compares
source/installed notice hashes, all font notices and Qt license/SBOM files,
checks its unique shortcut and retained profile, and removes its temporary root.
Qt deployment reports the existing missing translation catalog; packaging passes.

Separately installed actual round 5 source `74bdad57`, using its existing build
read-only from `t3-661ef84c`, into
`%TEMP%\caelestia-integration-5b-88fb895a\app`, with sibling `profile`.
Seeded its three default config JSON files, changed
`bar.clock.showSeconds` to false and created a state sentinel. Installed round
5b over that same prefix/profile with explicit `-Prefix`, `-ProfileRoot`,
`-BuildRoot` and `-QtPrefix`. The executable SHA-256 changed and all four
profile file hashes remained identical. The updated payload has 47 license files.
Uninstall removed the payload and its unique shortcut while preserving those
profile hashes. Then removed the four verified test files and empty directories.
Both temporary install/profile roots are gone. No temporary installed shell
was launched. See `installer/prior-update.json` and the adjacent logs/hashes.

Before/after measurements preserve both monitor/work rectangles, taskbar flags,
Explorer PID 9252 and live qs PID 33252. Seven hashes covering live qs/install
metadata and live config files also match. Neither install test used the real
prefix or profile. See `preservation/`.

The live AppBar/frame tests were deliberately not run because they reserve work
areas. Live fullscreen release and desktop replacement remain for the user's
manual installation and validation. No new test harness, authentication change,
PR, main-branch update, autostart or package publication was performed.
