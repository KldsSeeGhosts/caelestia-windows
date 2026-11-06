# First-party capture build and regression interface

Capture is maintained in `windows/capture`. The source-only import commit
preserves every tracked file at public Glazier
`37f795041cbbb32ed46cba103f3f000a3a99ac13`; later changes are shell-owned.
The old repository and existing local clones are not deleted or archived.
The gitlink and `.gitmodules` entry are removed. Qt/backend/M3 pins are unchanged.

## Product and compatibility

The production payload contains `caelestia-capture.exe`. Its default identities
are `CaelestiaCaptureHost`, `Local\Caelestia.Capture.Instance` and
`\\.\pipe\Caelestia.Capture.Control.v1.<SID>.<session>`. There is no launch-only
managed mode. The lifecycle registry's `image --status` probe and forwarded
commands therefore reach the same identity without a native registry change.
The helper has no independent autostart implementation or menu entry.

`Glazier.qml`, the `glazier.json` executable override file, recorder journal,
keybind identities, screenshot/picker/record IPC aliases, v1 JSON control schema
and existing command names remain. Bundled-first resolution and explicit legacy
external executable fallback remain. A legacy `glazier.exe` override uses
`GlazierHost` and its own legacy v1 transport. Recorder retains
`CAELESTIA_GLAZIER_EXE`, adding `CAELESTIA_CAPTURE_EXE` as the first-party alias.

Only missing first-party config/audio preference files are copied from
`%APPDATA%\Glazier` into `%APPDATA%\Caelestia\capture`. Create-new semantics refuse
overwrite races. Existing/invalid new files and original legacy files remain.
Configured recording/save directories, default Screen Recordings output,
`.glazier-*` temporary names and thumbnail cache paths are unchanged.
There is no deletion-identity hardening claim.

## Build/source receipt

The legacy `glazier` lock key and `glazierRevision` build field remain one-release
origin aliases for existing pair consumers. They do not identify maintained
source. The lock's `representation: in-tree`, `sourceRevision: shell`,
`path`, `originRevision`, `originTree`, `cargoLockPath`, `cargoLockSha256` and
`executable` describe the source contract without a self-referential shell SHA.

`windows/capture/Source.ps1` exposes:

- `Get-CaelestiaCaptureSource -RepoRoot <shell>`: validates representation/lock
  bytes and returns actual shell HEAD plus origin/lock/executable information.
- `Assert-CaelestiaCaptureBuild <receipt> <source> <exe>`: rejects incomplete or
  mismatched capture source/binary receipts.
- `Test-CaelestiaCaptureNativeInput <relative-path>`: shared install/release
  reuse classifier. Every `windows/capture/**` input, Rust source, dependency
  path, lock, toolchain or build script change requires rebuilding.
- `Assert-CaelestiaCaptureRelease <descriptor> <native-source-SHA> <exe-SHA>`:
  pure-data release validation. The standalone installer contains the exact
  function body, tested for parity, so bootstrap imports no bundle code.

Build receipt authoritative fields are `captureSourcePath`,
`captureSourceRevision` (actual shell build SHA), `captureOriginRevision`,
`captureCargoLockSha256`, `captureExecutable`, `captureSha256`, `captureBundled`.
`sourceDirty` remains authoritative for uncommitted inputs. Public receipts
also include the exact reviewed toolchain, with no private command paths.
Release dependencies use `capture` with this provenance rather than inventing
a separate repository revision. The exact-pair candidate release refusal remains.

MIT `LICENSE`, Noctalia/Tabler `THIRD_PARTY_NOTICES.md`, and `ORIGIN.md` ship with
capture. Stable legacy `Glazier-LICENSE` and `Glazier-THIRD_PARTY_NOTICES.md`
payload names preserve existing notice consumers, with new
`Caelestia-Capture-ORIGIN.md` for the source boundary.

## Test entry points

From a native Windows PowerShell prompt at the repository root:

```powershell
powershell -NoProfile -NonInteractive -File windows/scripts/Test-CaptureIntegration.ps1
powershell -NoProfile -NonInteractive -File windows/scripts/Test-CaptureRust.ps1 `
  -ToolRoot D:/tools -OutputRoot D:/validation/capture-rust -Jobs 2
powershell -NoProfile -NonInteractive -File windows/scripts/Test-CaptureRelease.ps1 `
  -OutputRoot D:/validation/capture-release
```

Use a new output directory. `ToolRoot` is read-only canonical reviewed tooling,
not an installation request. The Rust entry point compiles with `--locked
--no-run --message-format=json`, identifies exactly one Cargo test executable,
checks the nonignored inventory against `windows/capture/tests/unattended.json`,
then runs it with one test thread in fresh owned TEMP and synthetic profile
directories. It never starts the production helper.

`capture-rust.json` is a compact public-safe receipt retained on success/failure.
It has actual pass/fail/ignored/filtered counts, per-test outcomes, native
acceptance reasons, source/lock/toolchain identities and test-binary SHA-256.
Raw compiler output, paths and logs are private. `-Filter` is diagnostic only;
zero executed passes still fails. The full CI command uses no filter.

The original 61 source annotations/four ignores were not executed counts.
Four original desktop tests plus 14 newly classified native-window/GPU/OLE/
encoder cases remain ignored acceptance. Two new config/identity regressions
bring the compiled inventory to 63. The reviewed baseline executed 45 and
ignored 18. The message-only private pipe fixture is process-unique and cannot
connect to an installed helper.

For a real negative control, change the production placement result's x
coordinate by one pixel using a temporary source patch, run the ordinary gate,
retain its failing receipt, then restore the patch before the final passing run.
This exercises actual regressions, not a fabricated nonzero wrapper.
`-Filter no_such_test` separately proves empty-execution refusal.

Root owns aggregate fixture registration. Register `Test-CaptureIntegration.ps1`
in Unit, and keep `Test-CaptureRust.ps1` in the native workflow after pinned
toolchain preparation. Both workflow copies contain that Rust step and its
always-upload receipt. `Get-NativeBuildRequired.ps1` already fails closed for all
capture paths because only a narrow top-level documentation allowlist skips
native work.

## Retained integration/acceptance gates

The environment preflight validates the in-tree source/lock through the shared
helper. Smoke validates the capture build and executable, refuses changed capture
inputs, and stages the first-party executable without launching it. The release
installer verifies first-party capture descriptor, binary digest, bundled source
lock and origin notice before any supplied code or activation. Existing legacy
release packages remain supported on their legacy path. Its new fixture uses
`-VerifyOnly` with synthetic bundles, never an installation.

Root retains license fixtures, lifecycle receipt source fields, aggregate test
registration and final pair pins/review. The source-notice assembler recipe
must take this in-tree source from the shell archive, preserve origin, and
inventory the current Cargo.lock. Do not create an upstream capture source
checkout/archive requirement. Root owns these adjacent file leases and the final
producer pin; `pair-contract.json` is not authored by this component.

Full source/build, component fixtures, public CI and exact-package acceptance
are separate evidence classes. Managed host live capture/recording, reload
while recording, HDR/GPU/native tests, package install/rollback and final
desktop acceptance remain explicitly unrun until separately authorized against
the exact final candidate. Existing lifecycle ownership code is not redesigned.
