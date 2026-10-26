# Dia fullscreen follow-up

Tracks [GitHub #9](https://github.com/KldsSeeGhosts/caelestia-windows/issues/9)
and [ERM-543](https://linear.app/ermin-zeherovic/issue/ERM-543). Backend:
[PR #4](https://github.com/KldsSeeGhosts/caelestia-quickshell-windows/pull/4).
This extends the earlier [fallback-display evidence](../2026-10-26-dia-fullscreen/README.md).

## Findings and changes

With the real displays online, the previous candidate released and recreated
four AppBars on each fullscreen transition. The secondary work area changed
in stages and the secondary taskbar was sampled visible in the pre-fix trace.
The frame now hides without removing its AppBar reservations.

Dia had also remained automatically floated after placement failed on the
1024x768 fallback display. The backend retries automatic floats when the
physical monitor becomes larger, subject to explicit float, fullscreen,
minimize and maximize safeguards. This recovery was tested with a fake
desktop, not with a physical monitor power cycle.

After keeping AppBars stable, an intermediate candidate still lost the tile:
Dia briefly exposed `WS_EX_NOACTIVATE` while exiting fullscreen. The backend
now defers classification of floating styles for a bounded 300 ms after
fullscreen suspension, with rechecks. Explicit exclusions and float
overrides still win, and a persistent floating style still floats.

## Build and test

- Built and installed clean source `0439f8068c46c95e67a1a8be4945bb721d7571dd`,
  backend `207dcd511008e7c7942ea66c175a9489cb626d72`.
- Qt 6.11.2, clang-cl 20.1.8, SDK 10.0.26100.0, CMake 4.4.4, Windows
  build 26300. See `build.json` and `build-final.log`.
- The native `tiling_manager_test` suite passed 41 cases, including bounded
  float retry, transient and persistent fullscreen-exit styles, explicit
  float, and work-area changes. See `test-result.log`. The new transient-style
  regression failed against the preceding candidate before the fix.
- Built with `windows/scripts/Build-Prototype.ps1` using the per-user Qt,
  LLVM, CLI11 and tools paths recorded in the earlier evidence. Tests were
  configured and built as documented there, then run with
  `tiling_manager_test.exe -o "<result path>,txt"`.
- `powershell -NoProfile -File windows/scripts/Test-Environment.ps1 -Json`
  ran after both pin changes. Pins matched; ordinary PowerShell lacked the
  developer tools on PATH. This is a prerequisite report, not a build test.
- Installed using the normal quit/install/start workflow. Installed `qs.exe`
  SHA-256: `00C68AC603FC80A9D504F5D30634F2DD27A9D7A98E60FE0EA74D4565F082436C`.
  The three profile configuration hashes matched their pre-test values.
  The previous installation is backed up at
  `%LOCALAPPDATA%/caelestia-windows-update-backups/fullscreen-followup-20261026/install`.
  The supervisor reported running with zero quick crashes.

## Live result and limits

The GitHub README video's player fullscreen button was exercised twice in
Dia on the Dell S2725QS, 3840x2160, 175% scale, physical origin (-3840, 0).
The primary MAG321UX OLED was 3840x2160 at 150%. The physical secondary work
area stayed `[-3735,18,-18,2142]` in the approximately 25 ms samples through
both cycles; both sampled taskbar HWNDs remained hidden. The primary and
secondary work areas in `fullscreen-both.json` match `pre-install-desktop.json`.

The fullscreen window occupied `[-3840,0,0,2160]`. Both exits returned the
visible DWM frame to `QRect(-3700,53 3647x2054)`, the exact pre-fullscreen
tile, with zero placement corrections. `physical-final.jsonl` records raw
GetWindowRect coordinates, which include invisible window borders and are
therefore not the same as the visible DWM frame in `placement-excerpt.log`.
The fullscreen screenshot is a window capture, not a full-desktop composite;
its image is the video content itself.

The trace reports changes rather than every sample. Sampling cannot rule out
brief flashes between samples. UI automation's exit sequence included roughly
1.5 seconds before Dia changed its normal style and restored geometry, so
these results do not establish that perceived transition latency is fixed.
The earlier component smoke timed out and was not repeated because it would
add temporary AppBars to the live desktop; it is not a passing test. Physical
monitor-off/on recovery and broader application compatibility remain untested.
Keep the issue open for user observation and these remaining checks.
