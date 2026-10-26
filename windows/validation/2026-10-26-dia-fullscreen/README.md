# Dia video fullscreen correction

Tracks [GitHub #9](https://github.com/KldsSeeGhosts/caelestia-windows/issues/9)
and [ERM-543](https://linear.app/ermin-zeherovic/issue/ERM-543).
Backend change: [PR #4](https://github.com/KldsSeeGhosts/caelestia-quickshell-windows/pull/4).

## Finding and change

Dia removes `WS_THICKFRAME` on entering video fullscreen. Native observations
show normal style `349110272` becoming `335544320`, with the window covering
the monitor. The old tiling manager evaluated floating style rules before
fullscreen suspension, removed the browser from its layout, and restored its
pre-tiling rectangle. That resize can cancel browser fullscreen.

The corrected backend checks fullscreen suspension first. It preserves the
browser's rectangle and layout membership during fullscreen, including
AppBar work-area changes, and resumes tiling on exit. Explicit scope exclusions
and float overrides still precede fullscreen suspension. The existing
monitor-sized-tile exception is retained.

This establishes a tiling defect matching the report. It does not establish
that the original taskbar flicker was a shell crash or prove every cause of
that flicker has been eliminated.

## Sources and commands

- Built and installed source: `d95cbcfd9d53130687709dd4ec677a431c757083`, clean.
- Backend: `046c82fa398ee3ebeef276218001dd189f595e43`, clean and pushed.
- Qt 6.11.2, clang-cl 20.1.8, SDK 10.0.26100.0, CMake 4.4.4.
- Windows 11 Pro build 26300; Dia executable version `156.0.8078.48`.
- Installed executable SHA-256:
  `C24D175B1354B19E689D6AEFD9C4D47B624C558775936FC5059987AEC5BB01EF`.

Test configuration, inside the native VS developer environment, with the
per-user Qt, LLVM and CMake/Ninja tools on this process's PATH:

```powershell
cmake -S windows/deps/quickshell/src/windows/test -B windows/.local/fullscreen-fix/tests -G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_CXX_COMPILER=clang-cl -DCMAKE_LINKER_TYPE=MSVC "-DCMAKE_MT:FILEPATH=<Windows SDK x64 mt.exe>" "-DCMAKE_PREFIX_PATH=<Qt prefix>"
cmake --build windows/.local/fullscreen-fix/tests --target tiling_manager_test --parallel 4
windows/.local/fullscreen-fix/tests/tiling_manager_test.exe -o "<result path>,txt"
powershell -NoProfile -File windows/scripts/Test-Environment.ps1 -Json
powershell -NoProfile -File windows/scripts/Build-Prototype.ps1 -QtPrefix "$env:LOCALAPPDATA/caelestia-dev/Qt/6.11.2/msvc2022_64" -LlvmBin "$env:LOCALAPPDATA/caelestia-dev/clang+llvm-20.1.8-x86_64-pc-windows-msvc/bin" -Cli11Include "$env:LOCALAPPDATA/caelestia-dev/deps/CLI11-2.5.0/include" -ToolsBin "$env:LOCALAPPDATA/caelestia-dev/tools/Scripts"
```

`environment.json` is the report from inside the build environment. The
ordinary PowerShell prerequisite check also ran: pins matched, but developer
tools were absent from that process's PATH. Neither report substitutes for
the build or tests.

## Results and limits

- The new borderless and borderless/topmost cases fail against the old
  `stateOf()` implementation: the browser becomes 600x400 rather than staying
  1920x1080. See `regression-before.log`.
- All 37 manager test cases pass with the correction. Cases cover fullscreen
  entry/exit, work-area change during fullscreen, startup with an already
  fullscreen browser, monitor-sized zero-gap tiles, and existing lifecycle,
  placement, scope, DPI and border behavior.
- Native backend and portable plugins built successfully. The install was
  updated through `Install-Caelestia.ps1` after normal shell quit, then started
  under its supervisor. The three user configuration file hashes stayed equal.
  Existing browser/editor processes and tabs were retained. A runtime backup
  is outside the repository at
  `%LOCALAPPDATA%/caelestia-windows-update-backups/fullscreen-20261026-103428/install`.
- The GitHub README video in Dia entered fullscreen on the available
  `\\.\DISPLAY1`, 1024x768 at DPR 1. Native geometry stayed 1024x768 throughout
  the approximately 19.5 seconds after entry in `native-after.jsonl`. Primary
  and secondary taskbar HWNDs were sampled as not visible. No shell restart
  was recorded. A screenshot confirms the fullscreen video; Escape exited it.
  Sampling is not frame-by-frame video proof.
- This live window had already floated because two application minimum widths
  did not fit the small display. Consequently, this native check proves basic
  player fullscreen and shell lifecycle only. The production tiler's resize
  correction is established by the failing/passing manager tests.
- A bounded component smoke loaded QML and presented its first frame but
  timed out after 60 seconds without a completion marker. Its reason is not
  established. It is archived as a failure, not counted as passing acceptance.
- The user's original DP-2 non-OLED, negative-origin, mixed-DPI scenario cannot
  be checked while the physical displays are off and the user is away. Keep
  the bug open for that verification, including the taskbar flicker and the
  other monitor's reservations. No full shell release or mixed-DPI acceptance
  is claimed by this archive.

Only relevant logs and a fullscreen screenshot are retained. No staged QML
or per-run source manifests are archived.
