# Windows M3Shapes implementation

Implemented on `t3/m3shapes` from `origin/t3/combined-modules` (`6026f947`).
No push, PR, Linear update, or evidence archive was created. The live build at
`D:\AiStack\caelestia-windows\windows\.local\build` was not modified; all output
is in this worktree's ignored `windows/.local/build`.

## Where M3Shapes comes from upstream

M3Shapes is **not** an in-repo `plugin/` module and was not a Windows-only
omission. Upstream Caelestia used to build it with `FetchContent`, then split it
out in `caelestia-dots/shell` commit `24aa15ee` ("build: split out m3shapes
(#1909)"):

- `flake.nix` pins `github:soramanew/m3shapes/32ad9ce3`.
- `flake.lock` records the same revision and it is passed to Quickshell as a
  module (`quickshell.withModules [ ... m3shapes ]`).
- The component QML imports `M3Shapes` and uses `MaterialShape` for the
  dashboard logo/user/uptime/calendar shapes, performance usage shapes, media
  `BackgroundShapes`, cover-art masking, loading indicator morphing and more.

The Windows build only enables `ENABLE_MODULES=plugin` and
`CAELESTIA_PORTABLE_UI=ON`, so it compiled Caelestia's QML plugin alone and never
built or installed the external M3Shapes QML module. The combined prototype
compensated with `windows/combined-prototype/adapters/imports/M3Shapes/`, a QML
`MaterialShape` shim that drew a neutral round `Rectangle`, and it replaced the
original animated `LoadingIndicator` with `BusyIndicator`. Both are now gone.

## What changed

- Added `windows/deps/m3shapes` as a second pinned submodule
  (`https://github.com/soramanew/m3shapes.git`) at
  `32ad9ce328bb77ed349b40a3be10ee9ea610b8ab`, and recorded it in
  `windows/sources.lock.json`. The revision matches upstream `flake.lock`.
- `windows/scripts/Build-Prototype.ps1` now checks the M3Shapes revision and
  cleanliness, configures/builds/installs it with the same clang-cl, Qt 6.11.2,
  Ninja and install prefix as Caelestia, and records `m3shapesRevision` in
  `logs/build.json`. It installs `m3shapes.dll`, `m3shapesplugin.dll`, `qmldir`
  and `m3shapes.qmltypes` into `install/qml/M3Shapes`.
- `windows/scripts/Test-Environment.ps1` verifies the M3Shapes pin alongside the
  Quickshell pin and reports `expectedM3ShapesRevision`/`actualM3ShapesRevision`.
- `windows/scripts/Start-ShellPrototype.ps1` requires the module for `-Combined`
  and adds `install/qml/M3Shapes` to the child process PATH. Windows resolves
  `m3shapesplugin.dll`'s dependent `m3shapes.dll` from PATH, not from the plugin
  directory (the Linux build uses an `$ORIGIN` rpath instead).
- Removed the combined M3Shapes shim and the `BusyIndicator` LoadingIndicator
  override. `windows/combined-prototype/sources.json` now stages the original
  `components/controls/LoadingIndicator.qml`; every other shape user was already
  staging the original component.
- Updated `windows/README.md`, `windows/NATIVE-BUILD.md` and
  `windows/combined-prototype/README.md`.

## Build

```powershell
git submodule update --init --recursive
$devRoot = Join-Path $env:LOCALAPPDATA 'caelestia-dev'
powershell -NoProfile -File windows/scripts/Build-Prototype.ps1 `
    -QtPrefix "$devRoot\Qt\6.11.2\msvc2022_64" `
    -LlvmBin "$devRoot\clang+llvm-20.1.8-x86_64-pc-windows-msvc\bin" `
    -Cli11Include "$devRoot\deps\CLI11-2.5.0\include" `
    -ToolsBin "$devRoot\tools\Scripts" `
    -BuildRoot <worktree>\windows\.local\build
```

Verified steps: M3Shapes compiled to `m3shapes.dll` + `m3shapesplugin.dll`
(including the analytic-antialiasing QSB shaders), installed into
`install/qml/M3Shapes`; Quickshell and the portable Caelestia plugins built and
installed; exit code 0. A standalone `qml.exe` scene using
`MaterialShape.Cookie12Sided` loaded the module and exited cleanly.

## Launch

```powershell
powershell -NoProfile -File windows/scripts/Start-ShellPrototype.ps1 `
    -QtPrefix "$env:LOCALAPPDATA\caelestia-dev\Qt\6.11.2\msvc2022_64" `
    -BuildRoot <worktree>\windows\.local\build -Combined -Live
```

Omit `-Live` for read-only observation. Add `-Smoke` for the no-write smoke.

## Smoke result

`Start-ShellPrototype.ps1 -Combined -Smoke` passed with `passed: true`,
exit code 0, no timeout, and no QML warnings/errors in stdout/stderr, with all
captured phases (session, popouts, OSD, launcher, all dashboard tabs, utilities,
notifications, sidebar). Result:
`windows/.local/build/logs/combined-20261026-013021-939.json`.

Inspected screenshots show the real expressive shapes rather than round
surfaces:

- `combined-20261026-013021-939-dashboard-dash.png` — Gem logo, ClamShell
  uptime and no-media shapes, Cookie4Sided calendar day and profile mask.
- `combined-20261026-013021-939-dashboard-performance.png` — Cookie4Sided CPU
  and GPU usage shapes.

Remaining limits: dynamic schemes, lyrics/beat tracking and the other
previously documented combined-shell limitations are unchanged. This smoke
validates module loading, shape rendering and morph-capable component staging,
not interactive morph animation under pointer input.
