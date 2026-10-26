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

## Utilities slice: idle inhibitor, recorder, lock

Implemented on `t3/utilities-native`, branched from `origin/t3/combined-modules`
(`6026f947`). No backend C++ change, dependency pin change, push or PR. The
supplied build was reused unchanged (backend gitlink `525786fc`).

- **Idle inhibitor.** The original `IdleInhibit` card keeps
  `RuntimeState.inhibitIdle` and the "Active since" chip. Windows has no Wayland
  `IdleInhibitor`, so `daemons/IdleInhibit.qml` runs
  `helpers/KeepAwake.ps1` as a child while the toggle is on. The helper holds
  `SetThreadExecutionState(ES_CONTINUOUS | ES_DISPLAY_REQUIRED |
  ES_SYSTEM_REQUIRED)` on its own thread, exits when the toggle stops (Quickshell
  kills its children) or when the shell PID is gone, and an unexpected exit
  clears the toggle instead of leaving a false "active" state.
- **Screen recorder.** `services/Recorder.qml` keeps the upstream
  `start/stop/togglePause/running/paused/elapsed` contract and drives ffmpeg:
  `where ffmpeg` availability, `%USERPROFILE%\Videos\Caelestia`, gdigrab
  `desktop` at 30 fps into H.264 MP4, and `q` on ffmpeg's stdin to finalise the
  file (6 s bounded kill fallback). The original card layout is kept; region and
  audio capture, pause, and the Linux recordings list/delete modal are not
  offered, and a missing ffmpeg shows `Unavailable: ffmpeg was not found on
  PATH.` in the card's one-line status.
- **Lock.** No gap: the pinned backend's `Session::lock()` already calls
  `LockWorkStation()` (`windows/deps/quickshell/src/windows/system/session.cpp`),
  and the combined launcher's `Lock` action resolves `["lock"]` through the
  original session adapter, only with Live session actions. No lock screen,
  credential UI or extra process was added.

Both cards are enabled in the combined profile and visible in read-only runs,
but act only with `CAELESTIA_COMBINED_LIVE=1` outside smoke; smoke asserts that
neither process exists. `-Combined -Smoke` and `-Combined -Live -Smoke` both
passed (exit 0, 32.6 s / 32.2 s, no QML warnings). Direct checks outside smoke:
the helper stayed alive with the execution state set; the exact ffmpeg command
with `-t 2` produced a valid MP4; a throwaway harness drove the real Recorder
singleton through probe → mkdir → start → stop, and `ffprobe` confirmed a
finalised clip (test file deleted). Limitations: fullscreen-only capture, no
recordings list, keep-awake verified by process lifetime rather than an elevated
`powercfg /requests` read, and no real lock was performed.

---

# Windows desktop background implementation

Branch: `t3/background`, based on `origin/t3/combined-modules`
(`6026f9475e99393be5d85c49b2367f1c36e3632e`). Work performed alone.
No push, PR, Linear update, backend rebuild, dependency change or evidence
archive. The shared build was read-only; all run artifacts are ignored under
`windows/.local/background-smoke`.

## Implementation

- Stages the original `modules/background` wallpaper, desktop clock, and
  visualiser component. The original wallpaper capture/shader transition
  implementation is preserved. Static images use a Windows-only portable
  `Visual` adapter because the supplied build excludes native Multimedia.
- `WindowsBackground` opts into the existing backend `DesktopLayer` API.
  `-Background` enables it; `-DesktopIcons Behind|Replace` chooses placement
  below or above desktop icons. Replace covers the icons without hiding them
  through Explorer or changing persistent settings.
- The backend mapping was already implemented at pinned revision
  `525786fc81f13346cb196dca5ab356f89ad707a5`: `WlrLayer` maps directly to
  `PanelLayer`, desktop embedding reparents nonexclusive background panels,
  and `desktop_host.cpp` supports legacy WorkerW and the 24H2+ child WorkerW
  layout after Progman `0x052C`. No C++ patch or backend worktree was needed.
- The original screen `Variants` follows `Screens.screens` and per-monitor
  enablement; the Windows wrapper filters to one selected screen during smoke.
  If no desktop host exists, the wrapper creates no background windows.
- The same `Wallpapers` service used by the picker now exposes `current`,
  preview/stopPreview and desktop wallpaper change observation. Starting the
  background never changes the configured Windows wallpaper.
- The visualiser hook loads the original component only when an `Audio.cava`
  provider exists. This task does not add audio analysis or fake values.
- Small upstream changes expose a configurable background screen set, use the
  direct `exclusionMode` property supported by Windows, and name the wallpaper
  and clock objects for the bounded smoke check.
- `-RunRoot` separates writable staging/profile/logs from `-BuildRoot`.
  `-Combined -Background -Smoke` runs the new short desktop check; the existing
  panel smoke stays unchanged when background is omitted.

## Quick validation

Reused Qt 6.11.2 and the existing backend/portable plugin build at
`D:\AiStack\caelestia-windows\windows\.local\build` on Windows build 26300.
The worktree's implementation changes were exercised over the base revision
above. No source copies or run manifests were archived.

```powershell
powershell -NoProfile -File windows/scripts/Start-ShellPrototype.ps1 `
    -QtPrefix C:\Users\Ermin\AppData\Local\caelestia-dev\Qt\6.11.2\msvc2022_64 `
    -BuildRoot D:\AiStack\caelestia-windows\windows\.local\build `
    -RunRoot "$PWD\windows\.local\background-smoke" `
    -Combined -Background -Smoke
```

Repeated once with `-DesktopIcons Replace`. Both passed with exit code 0 and
no warning/error diagnostics. Runtime was 12.3s / 11.8s including startup;
the check ran after 10s. Each observed exactly one `MAG321UX OLED` background,
2560x1440 logical pixels at native 150% scaling, with wallpaper and clock ready.
Backend logs confirm actual parenting behind icons to HWND `0x10216` and
above icons to HWND `0x1016a`, respectively.

Desktop screenshots were captured with Cua:
`windows/.local/background-smoke/during.png`, `replace-during.png`, and
`after.png`. They show the clock occluded by the ordinary editor window and the
existing wallpaper reappearing after exit. The editor covers most of the
desktop, so only the exposed part of the clock is visible in desktop captures.
A requested temporary editor frame change was immediately managed by the
existing tiler; its original frame was restored and verified. No tiling
settings were changed.

Before/after desktop snapshots match monitor work areas, taskbar state and
Explorer presence. Explorer PID 9252 and the installed `ksg-shell` PID 24108
were preserved; no test-owned Quickshell process remained after exit.

`Test-Environment.ps1 -Json` with explicit Qt/runtime paths reports matching
dependency pins and the existing runtime. The ordinary PowerShell PATH lacks
CMake/Ninja/compiler, so `nativeToolchainReady` is false. This is a prerequisite
report, not a new build claim. `git diff --check` passed.

## Limits and integration

Hotplug, Explorer restart, mixed-DPI monitor transfer, live picker writes,
actual visualiser output and interactive desktop icon behavior were not tested.
The backend and original screen model implement their lifecycle paths, but
these smoke runs are not a validated shell release. Video wallpaper support
remains unavailable in the portable image adapter.

The colour-scheme, visualiser and production-entry agents may also touch the
combined manifest, entrypoint and Wallpapers service. Preserve these background
entries and the `Wallpapers.current` contract during integration. Production
can instantiate `WindowsBackground` using its opt-in environment contract;
ordinary runs cover every enabled monitor.

---

## KSG settings migration implementation, 2026-10-26

Implemented on `t3/ksg-migration` from `origin/t3/combined-modules`
(`6026f947`). No push, PR, Linear operation, native shell launch, desktop
takeover or change to KSG Shell was performed.

- Added `windows/scripts/Import-KsgShellSettings.ps1`. Default operation
  prints a merged JSON overlay without writing; `-Summary` prints a safe
  mapping report. `-BaseFile`, `-OutFile` and `-DryRun` support review and
  explicit output. Existing output requires `-Force` and is backed up
  byte-for-byte before atomic replacement. KSG profile output is refused.
- Added `windows/docs/MIGRATING-FROM-KSG-SHELL.md`, covering schema sources,
  exact mappings, unsupported preferences, one-tiler switch-over and rollback.
- Audited KSG source revision `85bd3d85` read-only and M3 reference
  `5777a246`. Native KSG has no saved wallpaper, theme/accent, editable
  keybinds or user app-rule lists. Its rules and tiler chords are compiled
  in. M3 uses environment opt-ins, not `shell.json`, and exposes no
  configurable gap/padding. Those preferences are reported for manual
  switch-over, not misrepresented as working JSON settings.

Real-settings dry run under Windows PowerShell 5.1.26100.9711:

| Source | Result |
| --- | --- |
| Bar enabled | `bar.persistent=true` |
| Show date | `bar.clock.showDate=true` |
| Tray icon | `bar.entries[id=tray].enabled=true` |
| Keyboard/Bluetooth/network/volume/power icons | `kbLayout`/`bluetooth`/`network`/`audio`/`battery` status entries enabled |
| OSD | `osd.enabled=true` |
| Tiling enabled; gap/padding | Saved `true`, 10/10 DIPs; summary only, not enabled or written |
| Warnings/existing Caelestia base | None / absent |

Nine source preferences mapped. The current profile also contains dock pins
and historical backups, which have no supported destination and are not
copied. All four KSG profile files retained their hashes and the one existing
KSG process retained its PID through the smoke. No source values resembling
tokens, pin launch commands, wallpaper paths or personal paths are archived.

Quick file-only smoke passed: false values, id-based list merge, preservation
of unrelated fields/nested arrays/nulls, filtering of unknown source values,
tiling defaults/clamping, dry-run, overwrite refusal, byte-identical backup,
idempotence and source overwrite protection. Commands:

```powershell
powershell -NoProfile -File windows/scripts/Test-KsgSettingsImport.ps1
powershell -NoProfile -File windows/scripts/Import-KsgShellSettings.ps1 -Summary
powershell -NoProfile -File windows/scripts/Import-KsgShellSettings.ps1
powershell -NoProfile -File windows/scripts/Test-Environment.ps1 -Json
```

Evidence: `windows/validation/2026-10-26-ksg-settings-import/`. The prerequisite
report confirms matching backend pins but missing native build tools on the
ordinary PATH. This PowerShell-only change needs no C++/QML rebuild.
Production-profile loading, interactive tiling and full replacement remain
integration/runtime gates, not claims established by this smoke.
