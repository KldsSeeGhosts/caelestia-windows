# Windows integration round 2

Branch: `t3/integration-2`, based on `origin/t3/integration` (`4697ffa8`).
Backend: `windows/integration-2`, merge commit
`57163953a2efe8ee05288daabda5295e94c93404` (pushed to `caelestia`).
The Quickshell gitlink and source manifest move together; M3Shapes remains
pinned to `32ad9ce328bb77ed349b40a3be10ee9ea610b8ab`.

# Windows keyboard shortcuts

Implemented on `t3/global-shortcuts`, based on `origin/t3/combined-modules`
(`6026f947`). Backend changes are committed on the local
`windows/global-shortcuts` branch in
`D:\AiStack\caelestia-windows\windows\.local\qs-shortcuts`. Nothing was pushed,
no PR or Linear item was created, and no evidence archive was written.

Merged, in order: M3Shapes, native utilities, desktop background, KSG migration.
Ported only the workspace-dispatch service/test/docs changes from `cadcd7c2`;
the old tiling branch was not merged. Original workspace click and wheel
handlers use the facade. Combined Live enables dispatch and workspace scrolling;
smoke always disables dispatch. The native wrapper sets `workspaceLimit` from
the focused monitor's configured workspace count before each dispatch.

Conflict resolutions retain the M3 bar, AppBar, separate tiling opt-in, shared
toasts and in-process notification fixture. The real M3Shapes plugin replaces
the round shape shim and original LoadingIndicator is staged. Documentation
retains each feature's notes. Launcher selection accepts both Background and
the independent Combined+Tiling add-on.

Build output is isolated to this worktree's `windows/.local/build`; no other
worktree's build is used or changed.

Validation on Windows build 26300, Qt 6.11.2, clang-cl 20.1.8, MSVC 14.44.35207,
SDK 10.0.26100.0, CMake 4.4.4 and Ninja 1.13.2:

- Full native `Build-Prototype.ps1` passed, including backend, real M3Shapes,
  portable plugins and install. The strict build-environment check passed with
  matching pins. Ordinary PowerShell still requires the documented tool paths.
- One `-Combined -Smoke` run passed in 43.131 seconds, exit 0, no timeout or
  QML warnings/errors: `combined-20261026-014947-493.json`.
- One `-Combined -Live -Smoke` run passed in 32.152 seconds, exit 0, no timeout
  or QML warnings/errors: `combined-20261026-015051-486.json`.
- Both runs observed the primary monitor at native 150% DPI. Desktop IDs,
  current desktop and the Windows wallpaper path matched the baseline after
  each run. Dispatch, recorder, idle helper and other native writes stayed off.
- Hypr service fixture passed 646 assertions; file-only KSG importer tests and
  `git diff --check` passed. Live workspace switching and the opt-in desktop
  background were not exercised by these two panel smoke runs.

Logs and run artifacts remain ignored under this worktree's build directory.
No new evidence archive is created. Imported migration evidence retains its
original branch records.

Launch from this worktree:

```powershell
powershell -NoProfile -File windows/scripts/Start-ShellPrototype.ps1 `
    -QtPrefix "$env:LOCALAPPDATA\caelestia-dev\Qt\6.11.2\msvc2022_64" `
    -BuildRoot "$PWD\windows\.local\build" -Combined -Live
```

Add `-Background` for the desktop surface/clock. Tiling remains an independent
opt-in with its existing application allowlist. Round 3 branches are excluded.

---

# Earlier feature reports

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

- `Quickshell.Hyprland`'s `GlobalShortcut` is backed by the Windows hotkey
  manager. Modifier combinations use `RegisterHotKey`; Super combinations and
  the lone-Super tap use a `WH_KEYBOARD_LL` hook. The hook is installed only
  while at least one hook-backed bind exists.
- A lone Super tap opens/closes the Caelestia launcher, matching upstream's
  `SUPER + SUPER_L` release bind. The hook consumes the Super release while the
  shell owns the tap, so Explorer's Start menu does not open for that tap. When
  no launcher bind exists, the hook is not installed and Super passes through.
- The original daemon shortcut names are preserved (`launcher`, `showall`,
  `dashboard`, `session`, `sidebar`, `utilities`, `launcherInterrupt`,
  `clearNotifs`, `toggleDnd`, `mediaToggle`, `mediaPrev`, `mediaNext`,
  `mediaStop`, `brightnessUp`, `brightnessDown`) plus Windows `volumeUp`,
  `volumeDown`, and `volumeMute`.
- The combined prototype now instantiates the original shortcut daemon surface.
  Its Windows adapter targets the prototype's selected `ScreenState`; it does
  not depend on the unavailable `Hypr.focusedMonitor`.
- Registered hotkeys and the low-level hook are released when the shell exits.
  A synthetic `Ctrl+Alt+C` probe owned by the shell became registerable again
  immediately after the process exited.

## Default binds

Shipped in `defaults/windows/keybinds.json`:

| Keys | Action |
| --- | --- |
| Super (tap) | Launcher |
| Super+K | Show launcher, dashboard, OSD and utilities together |
| Super+Shift+D | Dashboard |
| Super+N | Notification sidebar |
| Super+Shift+U | Utilities |
| Ctrl+Alt+End | Session menu (Ctrl+Alt+Delete is reserved by Windows) |
| Ctrl+Alt+C | Clear notifications |
| Super+Shift+N | Do not disturb |
| Ctrl+Super+Space, XF86AudioPlay | Play/pause |
| Ctrl+Super+Equal, XF86AudioNext | Next track |
| Ctrl+Super+Minus, XF86AudioPrev | Previous track |
| Ctrl+Super+Backspace, XF86AudioStop | Stop (no-op: the facade reports stop unsupported) |
| XF86AudioRaiseVolume / XF86AudioLowerVolume | Output volume (repeating) |
| XF86AudioMute, Super+Shift+M | Mute output |
| Ctrl+Alt+Page Up / Page Down | Brightness (repeating) |
| Super+L | Lock Windows (`rundll32 user32.dll,LockWorkStation`) |

The map is configurable without rebuilding:

- Put `keybinds.json` in the shell configuration directory (`CAELESTIA_CONFIG_DIR`,
  next to `shell.json`). This is the preferred per-shell override.
- Or use `%LOCALAPPDATA%\caelestia\windows\keybinds.json`.
- Or set `CAELESTIA_WINDOWS_KEYBINDS` to an explicit file for an isolated run.
- Start a user file with `{"extends": "defaults", "binds": [...]}` and override
  an entry with `"base": "global:caelestia:launcher"`. The file is watched and
  reloads the binds without restarting.

The backend change that makes the config-directory location work:

- `configFile` in the default map is resolved against `CAELESTIA_CONFIG_DIR`
  before the per-user data location.
- The configuration directory is watched, so creating the override applies it.
- `CAELESTIA_WINDOWS_KEYBINDS` overrides both paths.
- `Hotkeys.trigger(name)` exposes programmatic delivery for shells and tests.

## Build and smoke

Build (in this worktree only, Qt 6.11.2 / clang-cl 20.1.8 / Ninja):

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

---

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

---

# Taskbar takeover implementation

Branch: `t3/takeover`, based on `origin/t3/combined-modules` at `6026f947`.
No pushes, PRs, Linear changes, backend edits, dependency pin changes, or evidence
archives. Shared `D:\AiStack\caelestia-windows\windows\.local\build` was reused
read-only. All staging/logs/profiles stayed in this worktree's ignored
`windows/.local/`.

Implemented:

- Standalone Windows PowerShell/WinForms supervisor, independent of qs.exe.
  Launches the shell only after acquiring session ownership and persisting its
  desktop snapshot. Handles TaskbarCreated and re-hides delayed/new secondary
  taskbars on a 250 ms timer using SW_HIDE. Restores without activating taskbars.
- JSON `windows.hideTaskbar=false`, `windows.restartOnCrash=true` defaults.
  Combined prototype uses separate `config/windows.json`, preserving compatibility
  with the existing compiled upstream configuration schema. Production passes
  its platform settings path to `Start-DesktopShell.ps1`.
- Clean exit restores saved taskbar visibility/flags. Nonzero exit restores
  before restarting; 2/4 second backoff stops after three consecutive crashes
  with lifetimes under 30 seconds. Long lifetimes reset that counter.
  The backend crash handler is disabled only in the supervised child.
- Recovery removes only the dead child's stale backend AppBar registrations.
  Saved work areas are restored when stale owned AppBars were removed or the
  production caller explicitly passed `-RestoreWorkAreas`. The bounded
  prototype does not own work-area changes, so it leaves other agents' work
  areas alone. Hide-off supervision makes no taskbar visibility/flag calls.
- Background windows and WinEvent hooks owned by a dead process are destroyed
  by Windows. Recovery redraws the desktop, preserving shared WorkerW/Progman
  and windows owned by other applications.
- `Restore-Desktop.ps1` cooperatively stops an active supervisor, shows real
  taskbars, disables auto-hide and resets physical per-monitor work areas minus
  the real taskbar. Optional exact snapshot restoration; Explorer restart only
  with `-RestartExplorer`.
- Launcher switches `-Takeover`, `-HideTaskbar`, `-NoRestartOnCrash`, and writable
  `-RunRoot`. Production integration contracts are in the combined README's
  Takeover heading. No production-entry, AppBar, tiling, shortcut, workspace or
  background component implementation changes.

Checks on 2026-10-26, native Windows build 26300, Qt 6.11.2, supplied qs.exe
SHA-256 `9B518329FAC6B96973F4ECAA58A6CDFA5E413B6F9633A8F70345A706905F55AA`:

```powershell
powershell -NoProfile -File windows/scripts/Test-DesktopTakeover.ps1 `
  -QtPrefix "$env:LOCALAPPDATA\caelestia-dev\Qt\6.11.2\msvc2022_64" `
  -BuildRoot D:\AiStack\caelestia-windows\windows\.local\build
```

Passed: clean Qt.quit after ten seconds, four hide calls and two restore calls;
hard-killed only the next owned qs.exe, exit -1, two hide/two restore calls.
Every hide was matched to a restore request for the same HWND and owner PID,
using saved visibility. Immediate native observations matched every request.
Both child processes and watchdogs exited. Later changes isolated work-area
ownership and changed showing to SW_SHOWNA, without changing hide/watch logic.

Passed: deterministic default restart-policy test with `cmd /c exit 7`: three
quick crashes, backoff, give-up, exit 7, no taskbar visibility calls with hiding
off. C# helper compilation, PowerShell syntax parsing and `git diff --check`
passed.

Combined UI smoke: an initial run rendered all components and emitted
`CAELESTIA_COMBINED_PASS`, but exposed a null PowerShell process exit-code
reporting issue that was fixed. The final run correctly reported exit 1 for
`CAELESTIA_COMBINED_FAIL: notification popup did not render`. This unrelated
combined notification smoke failure remains; no notification changes were made.
The helper exited cleanly in both runs.

Environment prerequisite report: backend pin matches
`525786fc81f13346cb196dca5ab356f89ad707a5`; Qt/runtime found. CMake, Ninja and
C++ compiler are absent from ordinary PATH. No native shell/backend rebuild was
required; the helper compiles with Windows PowerShell's Add-Type.

Desktop interference: other agents repeatedly changed auto-hide, taskbar
visibility and work areas during this work. Per user direction, acceptance
assertions target our recorded calls, not exclusive global ownership.
Final recovery returned both taskbars visible and flags 0, with work areas
`(0,0)-(3840,2088)` and `(-3840,0)-(0,2076)`. A read one second later observed
another controller had already re-enabled auto-hide and hidden the primary
taskbar. Final recovery is run again immediately before handoff; no task-owned
shell/watchdog remains. Other agents' processes and Explorer were not stopped.

Remaining integration acceptance: exclusive production takeover, real Explorer
restart, live AppBar/background crash cleanup, monitor hotplug and stable visible
taskbars after recovery. TaskbarCreated reception and cleanup code are implemented;
these integrated scenarios were not exercised on the contested desktop.

$devRoot = Join-Path $env:LOCALAPPDATA 'caelestia-dev'
powershell -NoProfile -File windows/scripts/Build-Prototype.ps1 `
    -QtPrefix "$devRoot\Qt\6.11.2\msvc2022_64" `
    -LlvmBin "$devRoot\clang+llvm-20.1.8-x86_64-pc-windows-msvc\bin" `
    -Cli11Include "$devRoot\deps\CLI11-2.5.0\include" `
    -ToolsBin "$devRoot\tools\Scripts" `
    -BuildRoot (Join-Path (Get-Location) 'windows\.local\build')
```

Backend and portable plugins built cleanly. The shortcut smoke launched the
combined prototype without `-Smoke`, waited for it to settle, sent a synthetic
lone Super tap, and then stopped it. Observed:

- `Loaded 23 binds from .../defaults/windows/keybinds.json`
- `Keyboard hook installed.`
- `Bind "Super" "global" phase 3`
- `CAELESTIA_SHORTCUT name=launcher launcher=true`
- no QML/runtime `ERROR` or `FATAL` line
- `Ctrl+Alt+C` was registered while running (`RegisterHotKey` refused a second
  owner) and registerable again after exit.

The stock `-Combined -Smoke` run currently fails its pre-existing
`notification popup did not render` assertion in this environment. The same
failure reproduces after stashing every change in this task, so it is not caused
by the shortcut work.

Windows ignores synthetic Win-key input for the Start menu itself, so the
visual Start menu could not be exercised with `SendInput`. After the shell
exited, a synthetic Ctrl+Esc did open SearchHost (and closed on Escape),
confirming desktop input was healthy. The hotkey registrations were released and
the low-level hook is process-scoped, so a real Super press reaches Start again.

## Backend branch and commit

- Repository: `D:\AiStack\caelestia-windows\windows\deps\quickshell`
- Worktree: `D:\AiStack\caelestia-windows\windows\.local\qs-shortcuts`
- Branch: `windows/global-shortcuts`
- Commit: `d44760b27945d945387cb8ba165d8739afb2d1ff`
  (`windows: resolve keybinds overrides from the shell config`)
- Base: `caelestia/windows/m3-dpi-unaware-placement` (`b92e9fa`)
- Shell pin: `windows/sources.lock.json` and the `windows/deps/quickshell`
  gitlink are updated to that commit.

The backend commit is local to the worktree; it was not pushed to the
`caelestia` remote.

## Shell commit

`d931193d` (`windows: ship default global shortcuts and the combined shortcut
daemon`), on `t3/global-shortcuts`.

## Known limits

- `Ctrl+Alt+Delete` is a Windows secure-attention sequence and cannot be bound;
  `Ctrl+Alt+End` is the substitute.
- Windows laptop brightness keys do not arrive as stable virtual keys, so the
  default uses `Ctrl+Alt+Page Up/Down`; both entries can be changed in the map.
- `mediaStop` is wired, but the pinned media facade reports stop unsupported, so
  it does not claim a successful native stop.
- The root production `shell.qml` already instantiates the original shortcut
  daemon. This task validates the Windows combined prototype path; the full
  production shell host remains a separate milestone.
