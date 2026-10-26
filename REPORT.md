# Windows integration round 5

Branch `t3/integration-5`, based on `origin/t3/integration-4` (`db33341e`).
Backend `windows/integration-5` is pushed to `caelestia` at
`457127d820ac1e48cd5c7c5454e8fef738e1a235`; gitlink and source lock agree.

## Integration

- Backend merge `457127d`: review-followups `8e4c2e2`, no conflicts. Retains
  leak-review, Explorer reconnection for workspace dispatch and MTA audio sessions.
- Shell merge `07265f63`: polish `00251c31`. Launcher conflict unions profile,
  tiling and desktop-supervision options with transparency and account-picture
  setup. Background conflict keeps all-monitor/Wallpaper Engine ownership and
  checks the configured clock state. REPORT retains the integration report.
  TransparentPalette now wraps the dynamic palette rather than replacing it.
- Shell merge `5f627b8b`: runtime-review `58cc7f24`. Unioned runtime profiling
  with existing background/launcher switches; wallpaper thumbnails retain WE
  preview selection plus bounded asynchronous decoding. Kept build-record
  backend provenance and the existing independent profile/run-root behavior.
- `ac2a7807`: paired backend pins; production font defaults, account picture,
  staged assets/session GIF and hidden-dashboard native sampler suspension.
- `a5934f10`: production smoke bypasses the session-wide supervisor and owns
  only its child process. Smoke disables AppBar reservation and taskbar takeover.
  Also removed a duplicate merged result-map key.
- `66902a2b`: Windows C++ font defaults resolve the registered Google Sans Flex
  family even for existing profiles without explicit font settings. Linux
  defaults remain unchanged. Retain launcher search through close animation so
  closing the wallpaper picker cannot incubate app delegates in a dying context.
- `1b582a5b`: absolute Windows PowerShell path for the foreground watcher under
  deployed smoke's minimal PATH; production smoke verifies hidden telemetry off.

`origin/t3/release-docs` did not exist when integration started and was skipped.
No new evidence archive, PR, Linear change or main-branch change was made.
Feature-branch archives arrived unchanged through the polish merge.

## Build and quick smoke

Native build and incremental font rebuild passed with Qt 6.11.2, clang-cl
20.1.8, MSVC 14.44.35207 and Windows SDK 10.0.26100.0. Backend, real M3Shapes
and portable plugins are built in this worktree only:

```text
C:\Users\Ermin\.t3\worktrees\caelestia-windows\t3-661ef84c\windows\.local\build
```

The final compiled-source build record is `66902a2b` (clean); subsequent
`1b582a5b` changes only staged QML. Strict build-environment report passes.

- Combined smoke with transparency: PASS, exit 0, 37.662 s, native primary 150%.
  `logs/combined-20261026-025441-021.json`.
- Combined Live smoke: PASS, exit 0, 35.933 s, native secondary 175%.
  `logs/combined-20261026-025613-932.json`.
- Dynamic WE-derived palette and catalog remained live (253 wallpapers, nine
  variants). Control/dispatch/tiling/tray hooks stayed off during smoke.
- Updated installed production: PASS on both monitors (2560x1440 and 2194x1234
  logical windows), minimal PATH, profile-local scheme runtime, zero runtime
  warnings/errors, hidden CPU/network samplers inactive, explicit installed IPC
  state and quit, launcher exit 0. Foreground-filter native fixture passes.
- Early rejected runs exposed one transient AppsFolder icon warning and the
  picker-close incubation race. The close race is fixed. First installed
  attempt exposed the missing PowerShell PATH entry; that is fixed. A local
  harness exit-code handle issue was corrected before the final passing run.

## Update and uninstall

Installed round-4 sources `db33341e` with the prior round-4 backend build
`4a3e9a1` into a unique TEMP prefix, seeded the round-4 profile, changed its
clock preference and added a state sentinel. Reinstalled this build over that
same prefix/profile. The executable hash changed; all three config JSON files
and the state sentinel retained their exact hashes before update, after the
new build ran, and after uninstall. Temp-prefix uninstall passed and retained
the profile. All test output remains ignored under `windows/.local`.

The user's installed process PID 33252 remained running. Before/after monitor
work areas and taskbar snapshots matched exactly. No Install/Uninstall command
used the default prefix, and no real-profile file was written.

To update the real installation when ready, quit it normally first, then run
from this worktree (no uninstall, no purge):

```powershell
powershell -NoProfile -File windows/scripts/Install-Caelestia.ps1 `
  -BuildRoot "C:\Users\Ermin\.t3\worktrees\caelestia-windows\t3-661ef84c\windows\.local\build" `
  -Prefix "$env:LOCALAPPDATA\Programs\caelestia-windows" `
  -ProfileRoot "$env:LOCALAPPDATA\caelestia-windows"
```

The installer refuses an update while that prefix's qs.exe is running and
preserves existing profile configuration. Start the installed shortcut again
when the update finishes.

---

# Windows integration round 4

Branch `t3/integration-4` starts at `origin/t3/integration-3` (`9b732a30`).
Backend branch `windows/integration-4` starts at `13b2d093` and is pushed at
`4a3e9a1426df6ca4c55e4dc1845940126b8f90b9`. The Quickshell gitlink and
`windows/sources.lock.json` agree. Reviewed upstream is now `4b1dae84`;
M3Shapes stays at `32ad9ce3`.

## Commits and conflict resolutions

- Backend merges: `7efb8e9` adds `windows/tiling-config` (`6a17ae6`);
  `4a3e9a1` adds `windows/leak-review` (`ffa7a77`). No source conflicts.
- `6d26f8ee`: tiling config merge. Kept the integrated launcher/takeover paths;
  added profile/config switches, watched `windows.tiling`, typed selectors,
  gaps and rules. Took the updated importer, importer checks and migration guide.
  Resolved the gitlink to the final backend, retaining the other dependency pins.
- `d60d2e03`: Nerd fonts merge. Kept integrated staging and loaded the shared
  WindowsFonts component in every host, including production. Preserved explicit
  workspace fallback and all pinned font checksums/licenses.
- `3074c664`: dynamic scheme merge. Kept background preview and Windows wallpaper
  observation alongside the real CLI bridge, scheme/variant rows and generation.
  Retained RunRoot for logs and the independent profile selection.
- `008095f1`: Wallpaper Engine merge. Retained all-monitor background instances
  and the hard-reload ownership fix while adding the fail-closed external-owner
  guard and its live reconcile. Preserved the local notification fixture and
  added the wallpaper-picker carousel smoke steps.
- `5d54875f`: audio visualiser merge. Unioned the native CavaProvider/BeatTracker
  loaders with existing volume shortcuts and retained both audio-analysis checks
  and the integrated notification/picker smoke sequence.
- `b7a0885c`: upstream/main merge, no conflicts. Includes locale-aware I18n,
  Time/Weather/calendar/IdleInhibit changes and the flake.lock update.
- `7a411513`: production integration, defaults, installer/runtime packaging and
  documentation. Both entry points use the same integrated staged service graph.
- `f5dbad02`: Windows Time adapter retains locale-aware samples through teardown.
  A repeat installed quit exposed native binding-context invalidation despite
  null guards. Imperative clock/locale sampling preserves formatting and avoids
  bindings through destroyed clock objects. Final installed smoke is clean.

REPORT conflicts are replaced by this report. Combined README conflicts preserve
integrated controller/utility documentation and incorporate the new services.
Feature-branch validation archives were carried by their merges unchanged; no
new evidence archive was created for this integration.

## Production behavior

The production profile defaults to `%LOCALAPPDATA%\caelestia-windows`.
Its first launch provisions the pinned Caelestia CLI/Python packages into
`scheme/venv` under that profile. The installer includes the provisioning script,
bridge, fcntl compatibility shim and source pins. IPC commands do not provision.
Python and a first-launch download are accepted dependencies; failed provisioning
retains the fixed palette, and `-SkipSchemeRuntime` skips it explicitly.

Production and Combined both use WE discovery, the engine/files/both picker and
preview-based Material You generation. WE auto detection remains the default.
The entire Caelestia desktop host yields while WE owns WorkerW; it does not cover
or change the user's WE wallpaper. Production desktopClock.enabled is false.
Tiling defaults disabled with 10/10 DIP gaps. Omitted launcher switches allow
watched profile configuration to apply; explicit switches override environment,
which overrides the profile. The real user's KSG settings summary reads 10/10
and maps to Observe, without enabling the tiler or writing either user's config.
The Windows IdleInhibit adapter uses Tr.formatDateTime.

## Build and smoke

Build output, exclusively in this worktree:

```text
C:\Users\Ermin\.t3\worktrees\caelestia-windows\t3-9957da37\windows\.local\build
```

Full Build-Prototype.ps1 passed: backend, M3Shapes, portable plugins (including
Caelestia.Windows.Audio), and local plugin installation. Qt 6.11.2, clang-cl
20.1.8, MSVC 14.44.35207, SDK 10.0.26100.0, CMake 4.4.4 and Ninja 1.13.2,
Windows build 26300. Build metadata records merge b7a0885c with integration edits;
no C++ source changed afterward. Final stages use f5dbad02.
The ordinary environment report confirms both pins; tools absent from ordinary
PATH are available in the build script's isolated VS environment, whose strict
prerequisite check passed.

- File-only KSG importer smoke passed, including default 10/10 mapping and rule
  preservation. Real KSG summary also confirms 10/10, Observe only.
- Tiling config smoke passed: 10/10 initial profile, 12/14 live reload, exit 0.
- Final `-Combined -Smoke`: PASS, exit 0, 35.710 seconds, primary 150%,
  combined-20261026-023509-219.json.
- Final `-Combined -Live -Smoke -ScreenIndex 1`: PASS, exit 0, 35.700 seconds,
  secondary 175%, combined-20261026-023640-127.json. Both use f5dbad02; the
  Live run has only this report edited. Both load the native 60-bar provider,
  scheme/variant rows, 253-item WE carousel and generated #f9b7a3 palette, with
  no runtime warnings/errors.
- Final installed production: PASS on native 150% and 175% monitors. Drawers are
  2560x1440 and 2194x1234 logical pixels with 60-DIP bars. WE is detected/running,
  253 catalog items, 26 scheme rows, 9 variants, primary #f9b7a3. All native-write
  gates are false and tiling is off. DesktopLayer is inactive with zero background
  hosts on both monitors because WE owns the desktop.
- Exact-path IPC State and Quit passed. Watchdog reports clean-exit, exit 0.
  Uninstall -Purge removed the temporary payload, profile and Start-menu shortcut;
  no autostart entry was created. Runtime has no WARN/ERROR/FATAL/CRITICAL records.
  Initial harness exit-code bookkeeping was fixed before this passing run.
- Work areas and taskbar flags equal the original baseline after quit and after
  uninstall. Per-HWND taskbar owner, visibility, bounds and flags equal the
  supervisor snapshot. Windows wallpaper path, both WE project selections and
  current virtual-desktop GUID are unchanged. No desktop switching was requested.

Logs/results remain ignored under windows/.local. No other worktree's build was
modified. Smoke establishes build/loading/install compatibility; it does not
certify live tiling, audio accuracy, hardware writes, hotplug or a shell release.
Round-5 polish, review-followups and runtime-review branches were not merged.

## Commands

From this checkout after the native build, without opting into autostart:

```powershell
powershell -NoProfile -File windows/scripts/Install-Caelestia.ps1
& "$env:LOCALAPPDATA\Programs\caelestia-windows\Start-Caelestia.ps1"
& "$env:LOCALAPPDATA\Programs\caelestia-windows\Start-Caelestia.ps1" -Command State
& "$env:LOCALAPPDATA\Programs\caelestia-windows\Start-Caelestia.ps1" -Command Quit
powershell -NoProfile -File windows/scripts/Uninstall-Caelestia.ps1
```

Installation defaults to `%LOCALAPPDATA%\Programs\caelestia-windows`.
Use -Prefix and -ProfileRoot for a separate temporary installation; -Purge removes
its profile. Production smoke uses the installed launcher with -Smoke in another
process, waits for CAELESTIA_SHELL_LIVE_PASS, then calls -Command Quit. Combined
smoke uses Start-ShellPrototype.ps1 -QtPrefix <Qt> -Combined -Smoke; add -Live
for the second mode. Final Live smoke selects -ScreenIndex 1.
