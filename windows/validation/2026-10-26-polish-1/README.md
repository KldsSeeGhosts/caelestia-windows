# Windows polish 1 validation

Implementation branch `t3/polish-1`, based on `41ddcefc`.
See the current section of [REPORT.md](../../../REPORT.md) for all eight
implementation commits and their selected captures.
[result.json](result.json) and [matrix.csv](matrix.csv) index the passing runs.

## Runtime and reproduction

No C++ changed and no rebuild was performed. All runs used this read-only build:

```powershell
$qt = 'C:\Users\Ermin\AppData\Local\caelestia-dev\Qt\6.11.2\msvc2022_64'
$build = 'C:\Users\Ermin\.t3\worktrees\caelestia-windows\t3-8fb0d51b\windows\.local\build'
& windows/scripts/Start-ShellPrototype.ps1 -QtPrefix $qt -BuildRoot $build `
    -RunRoot "$PWD\windows\.local\polish\reproduce" -Combined -Smoke
```

Qt 6.11.2, native Windows platform, primary DPR 1.5 and secondary DPR 1.75.
The supplied build's backend is `57163953a2efe8ee05288daabda5295e94c93404`.
[borrowed-build.json](borrowed-build.json) preserves its toolchain/source record.
The local dependency checkout was already at `525786fc` after switching the
root branch. It was left untouched. Original per-run `backendRevision` fields
describe that checkout, not the runtime binary. The archive's
`runtimeBackendRevision` identifies the binary actually used.

The first validation of each fix occurred before its commit, so those original
records are dirty and name the preceding commit. The matrix supplies the
resulting `implementationCommit`. The final 175% run used all eight committed
implementations (`1c3a2e98`), with transparency enabled and Python absent.
Subsequent palette edits only normalize whitespace.

Add `-ScreenIndex 1` for the secondary monitor, `-Transparency` to exercise
translucent materials, or `-Background` for the separate desktop smoke.
Omit `-Combined` for the M1 regression.

## Observed results

- Baseline and every per-item combined smoke passed, exit 0, without runtime
  warnings/errors in the archived passing runs.
- Font probes inspect actual `Text.fontInfo.family` for all four token
  categories. They report Google Sans Flex at both native DPIs.
- Transparency-enabled item capture has alpha 217/255 on the base surface and
  232/255 where surfaces overlap. Defaults remain transparency disabled,
  base 0.85, layers 0.4. Desktop blur was not modified or certified.
- Utilities capture shows Wi-Fi, Bluetooth, mic, DND and settings at equal
  base widths with the original ButtonRow spacing/morph behavior. Smoke
  refuses audio writes and does not open an editor.
- This account has no readable account picture in the requested locations.
  Its native capture therefore shows the upstream placeholder. A packed
  accountpicture-ms fixture extracts successfully into the profile cache;
  [avatar-fixture.json](avatar-fixture.json) records its reproducible input.
- Mascot captures show bongocat and the session animation. Dino is staged and
  resolves through the same namespace; a matched empty-sidebar visual was
  not captured because the smoke sidebar contains its notification fixture.
- Desktop smoke reports `clockEnabled:false`, `clockPresent:false`,
  `ready:true`; its capture is of the actual wallpaper content item.
- The active chip reports real foreground titles, including T3 Code (Nightly)
  and Home / X. [active-filter.json](active-filter.json) records native
  application/tool/hidden/cloaked/null/qs checks using offscreen NOACTIVATE
  fixture windows. [hypr-fixture.json](hypr-fixture.json) passes 649 assertions.
- The Python-missing final smoke passes at 175% with `fallback:true`.
  [missing-python-warning.txt](missing-python-warning.txt) contains the
  user-facing diagnostic. The normal Python-present run also passes.
- M1 regression smoke passes after the shared transparency adapter change.

The Python-missing run removes Python directories from only its parent
process's PATH, retaining System32, Windows PowerShell and the actual portable
Git cmd directory. It does not uninstall software or modify persistent PATH.

## Limits and rejected attempts

These are bounded rendering/observation tests. Audio mute writes and default
editor launch were capability-checked in source, not invoked. A real account
photo was unavailable. No live tiling, autostart or taskbar changes were made.
The desktop run used the existing opt-in Behind mode and exited normally.

One preliminary active-window run printed an unrelated app-catalog icon
warning for appverif.exe; that strict smoke result was rejected. Its recheck
passed. An initial Python-missing attempt passed QML smoke but its parent
could not write the run record because the test PATH used the wrong Git
directory. The corrected final attempt passed and produced the archived
record. Neither failure was suppressed by changing the smoke criteria.

Only records, logs and selected screenshots are archived. Staged QML and
per-run sources.json manifests are deliberately excluded. Existing archives
remain unchanged. No push, PR, Linear update or backend commit was made.
