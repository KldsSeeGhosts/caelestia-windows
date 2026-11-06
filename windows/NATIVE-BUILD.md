# Native Windows build and validation

The supported x64 build is defined by [toolchain.json](toolchain.json):
Qt 6.11.2 `msvc2022_64`, clang-cl 20.1.8, selected VC tools 14.44.35207,
Windows SDK 10.0.26100.0, Rust/Cargo 1.99.1 with target
`x86_64-pc-windows-msvc`, CMake 4.4.4, Ninja package 1.13.2
(actual banner `1.13.2.git.kitware.jobserver-pipe-1`), and CLI11 2.5.0.
Windows 11 is the desktop target; hosted builds use `windows-2022`.
The production entry point is
`windows/shell/shell.qml`. A build or smoke pass does not establish live
desktop acceptance; use [LIVE-CHECKLIST.md](docs/LIVE-CHECKLIST.md) for that.

## Developer dependencies

Visual Studio Installer must already provide MSVC v143 VS 2022 C++ x64/x86
tools 14.44 (`Microsoft.VisualStudio.Component.VC.Tools.x86.x64`) with the exact
`VC/Tools/MSVC/14.44.35207` directory, plus Windows 11 SDK 10.0.26100.0
(`Microsoft.VisualStudio.Component.Windows11SDK.26100`). The build enumerates
installations with `vswhere`, selects one containing that toolset, explicitly
requests both versions, and asserts the selected x64 environment. A later VS
installation/banner alone is not sufficient. Missing components fail before
compilation with the required version and manual installation step.
No machine PATH, VS installation, Rust default or override is changed by a build.
The reviewed serviced `cl.exe` and `link.exe` file versions are respectively
19.44.35229.0 and 14.44.35229.0. A folder with different serviced binaries is
not interchangeable. The same VS instance must provide
`VC/Auxiliary/Build/Microsoft.VCRedistVersion.default.txt`, currently selecting
`VC/Redist/MSVC/14.44.35112/x64/Microsoft.VC143.CRT`. The selected `msvcp140.dll`,
`vcruntime140.dll` and `vcruntime140_1.dll` must each be version 14.44.35211.0.

The following setup commands download development tools into a separate
per-user directory. Run them in native Windows PowerShell. Python 3.12, Git,
`curl.exe`, and `tar.exe` must be available. Production builds also bundle the
Glazier recorder from the pinned `windows/deps/glazier` submodule, so the Rust
toolchain (`cargo` on PATH, installed with [rustup](https://rustup.rs/)) is
required. Install the exact Rust toolchain once:

```powershell
rustup toolchain install 1.99.1-x86_64-pc-windows-msvc --profile minimal `
    --target x86_64-pc-windows-msvc
```

Builds resolve an already installed compiler by its actual Rust/Cargo versions,
not a `stable` selector, then use its absolute tool directory and explicit Cargo
target. A preinstalled alias with exactly those versions is acceptable; a later
`stable` is rejected, not silently downloaded. Offscreen fixture builds can pass
`-SkipGlazier`, but their payload is not installable. The same supported toolchain
is still required.

Prefer the shared local/hosted preparation entry point:

```powershell
$devRoot = Join-Path $env:LOCALAPPDATA 'caelestia-dev'
powershell -NoProfile -File windows/scripts/Prepare-Toolchain.ps1 -ToolRoot $devRoot
```

The script uses Python 3.12 x64, committed hash-locked Python wheels and aqt
source, LLVM/CLI11 hashes and all six Qt archive SHA-256 values. Cached archives
are rehashed. Rust provisioning is opt-in with `-InstallRust`; its exact official
manifest is hash-checked and rustup verifies component checksums. No credentials
are required. Use a fresh external ToolRoot to repair an incomplete extracted
cache; do not bypass a hash failure. Supplier URLs and expected hashes live in
the specification and Python locks, not a second manual installation policy.

The aqtinstall revision is intentional: released 3.3.0 does not support this
Qt repository layout. The selected archives deliberately omit the separate
`qttranslations` component, because the installer ships no Qt translation
catalogs and the shell installs no `QTranslator`. As a result `windeployqt`
prints `Translations will not be available ... translations/catalogs.json`
even with `--no-translations`. That message is informational and does not
prevent deployment. Preparation keeps aqt logs outside the source checkout.

## Build

From the repository root:

```powershell
$devRoot = Join-Path $env:LOCALAPPDATA 'caelestia-dev'
powershell -NoProfile -File windows/scripts/Build-Prototype.ps1 `
    -QtPrefix "$devRoot\Qt\6.11.2\msvc2022_64" `
    -LlvmBin "$devRoot\clang+llvm-20.1.8-x86_64-pc-windows-msvc\bin" `
    -Cli11Include "$devRoot\deps\CLI11-2.5.0\include" `
    -ToolsBin "$devRoot\tools\Scripts" `
    -BuildRoot C:\b-caelestia
```

Use a short `-BuildRoot` path to avoid Windows path-length limits; `-Jobs`
changes parallelism (default 4). The legacy default is `windows/.local/build`.
Add `-PublicRelease` when building distributable binaries. It remaps native
profile, SDK, Cargo, source and build paths so Rust and C/C++ file-location strings
do not retain the builder's personal directory names. Existing `RUSTFLAGS` or
`CARGO_ENCODED_RUSTFLAGS` environment flags are retained, and the temporary
encoded environment is restored after Cargo exits. This mode selects explicit
compiler flags for the public build; final package privacy checks are still
required, including inspection of binary strings. Never distribute private
build logs, profiles or debug-symbol files as release assets.
Production builds use the default test-disabled configuration, and no test
binary is installed or staged. `-PluginTests` builds this repository's
native plugin fixtures. `-Tests` also builds the backend's standalone native
fixtures into `<BuildRoot>\quickshell-tests`; run them with
`ctest --test-dir <BuildRoot>\quickshell-tests -L '^portable$'` (tiers are
described in `windows/deps/quickshell/src/windows/test/README.md`). The
combined developer preview is not shipped.

The build also produces `quickshell/brightness-probe.exe`. It uses the native
brightness controller without starting the shell. Set Qt's bin directory in
the current PowerShell process before using it:

```powershell
$env:PATH = "$devRoot\Qt\6.11.2\msvc2022_64\bin;$env:PATH"
$probe = 'C:\b-caelestia\quickshell\brightness-probe.exe'
& $probe
& $probe -Display '<display name from the read-only output>' -Set 40
& $probe -Display '<display name from the read-only output>' -Restore
```

The first command is read-only. Set and Restore change the selected HDR
display's SDR white level. The probe records the exact original raw value in
`%TEMP%\caelestia-brightness-sdr-white-journal.json` before its first set,
keyed by monitor device path, and removes that entry only after an exact
read-back on restore. Restore requires the same active display path and HDR
mode. Back up the journal if needed; do not delete it before restoration.
The Windows set request is undocumented and may fail or change on future
Windows versions. Read-back confirms the reported setting, not physical
display luminance. No physical write or HDR-toggle acceptance is implied by
the build or fixtures.

The script:

1. Runs `Test-Environment.ps1 -Json -Strict` in the development environment and
   checks that the backend and M3Shapes worktrees are clean and match the source
   manifest.
2. Builds the pinned backend's `qs.exe` with crash handling and backend tests
   disabled. This does not execute the shell or enable autostart.
3. Builds the pinned external `windows/deps/m3shapes` plugin and installs the
   `M3Shapes` QML module (its `m3shapes.dll`, plugin DLL, `qmldir` and type
   information) into the build directory's `install/qml`.
4. Builds Caelestia with `CAELESTIA_PORTABLE_UI=ON` and `ENABLE_MODULES=plugin`.
5. Installs the eight portable modules and Windows-only `Caelestia.Windows`
   module into the build directory's `install/qml`. The latter supplies
   WindowsFocusGuard for the native prototype.
6. Records command arguments, logs, source revisions (including M3Shapes), and
   actual VC tools, SDK, Rust/target, compiler, Qt and build-tool versions under
   `logs/`. No packages are published. `logs/toolchain.json` is a path-free
   version/hash receipt; `logs/build.json` additionally contains private local
   deployment paths and must not be uploaded.

## Toolchain and runtime receipts

Before compilation, `Build-Prototype.ps1` and `Test-Environment.ps1` use the
same exact-version predicate as the release assembler. To check an existing
build without assembling or installing anything:

```powershell
powershell -NoProfile -File windows/scripts/New-CaelestiaRelease.ps1 `
    -BuildRoot C:\b-caelestia -ValidateToolchainOnly
powershell -NoProfile -File windows/scripts/Test-Toolchain.ps1
```

Legacy, incomplete, wrong-specification or incompatible receipts require a
rebuild. The selected VC directory, VS installation banner, serviced compiler/
linker versions, redist marker and actual CRT DLL versions are separate fields.
All qualified receipt fields are asserted, including the Rust commit from the
hash-pinned official release manifest.

The x64 system-runtime minimum remains **14.44.35211.0** because that is the
actual version of all three required DLLs in the reviewed marker-selected CRT,
not because `14.44.35207` sorts below it. Compiler/linker servicing numbers
are pinned independently; they are not substituted for the CRT's file version.
Missing, differently serviced or newer CRT inputs, including 14.44.35213.0,
require new qualification rather than silently changing the runtime floor.
The assembler re-resolves that same marker and checks the actual DLL versions
against the receipt. It never selects the newest redist directory. An explicit
`-VCRuntimeRoot` must retain the matching VS marker layout.

For Qt, all six hash-pinned package SBOMs (`sbom/*-6.11.2.cdx.json`) record
compiler 19.44.35227.0 and linker 14.44.35227.0; these actual supplier metadata
values are checked before compilation and deployment. The SBOMs and
`config_qtbase.summary` do **not** declare a minimum CRT version. Qt's generic
online `tools_vcredist` package is not an exact Qt 6.11.2 minimum-runtime
declaration either. Build metadata, import/export inspection and local smoke
are bounded evidence, not a clean-machine compatibility guarantee. A clean
Windows environment with the exact floor runtime must still qualify every
shipped component before claiming minimum-runtime/package acceptance.
See [Microsoft's compatibility guidance](https://learn.microsoft.com/en-us/cpp/porting/binary-compat-2015-2017).

Upgrades require a reviewed change to the specification, download hashes and
Python locks, a clean native build, receipt mismatch tests, and hosted evidence.
Any deliberate runtime-floor increase additionally requires missing/outdated/
current runtime tests on a clean Windows environment. Do not remove the guard
to accommodate a drifting hosted image.

## Smoke

The public smoke command is:

```powershell
$devRoot = Join-Path $env:LOCALAPPDATA 'caelestia-dev'
powershell -NoProfile -File windows/scripts/Test-Smoke.ps1 `
    -BuildRoot C:\b-smoke `
    -QtPrefix "$devRoot\Qt\6.11.2\msvc2022_64"
```

It stages the production map in `windows/shell/sources.json` exactly as the
installer does (`Stage-ShellPrototype.ps1 -Prototype shell-live`), starts the
built `quickshell/qs.exe` against an isolated temporary profile, and completes
once every drawer has presented two frames and readiness/control bindings have
settled, after a queued binding turn. Property changes recheck readiness even
if no further frame is drawn. A
15-second readiness deadline replaces the old fixed three-second settling
pause. The process uses `QT_QPA_PLATFORM=offscreen` and
the Qt Quick software backend. Tray hook, blur, tiling, background/desktop
embedding, notification mirroring, hotkeys, Wallpaper Engine and every service
control are off; an empty keybind list and `CAELESTIA_SHELL_SMOKE_CI` let the
shell exit itself. The script also checks the build's backend and M3Shapes
revisions against `windows/sources.lock.json`. A QML error, missing import or
plugin DLL, missing pass marker, or 90-second timeout fails the run.

The exit code is 0 on pass and 1 on failure, with a one-line summary. The
temporary stage, profile, stdout/stderr and Quickshell text log are removed on
pass, and kept with matched diagnostics printed on failure. The smoke also
fails if its captured output contains a MAC-like address or any
`quickshell.windows.bluetooth` activity, and it redacts those patterns from
failure output. `-TimeoutSeconds`, `-RunRoot` and `-Keep` help with debugging.
`QS_RUNTIME_DIR` only selects where Quickshell writes its own run/log files; it
is not a containment boundary and accepts relative, traversal and UNC paths.
The command does not install anything, run the live shell, or read the live
profile.

## Release-facing checks

For coordinated shell/backend changes, use the
[exact-pair integration entry point](ci/PAIR-INTEGRATION.md). Candidate builds
use an explicit exact-SHA backend clone outside the shell, preserve strict
production pins, and cannot be assembled as releases. A candidate preflight
receipt does not replace the final pinned main-push receipt for its own shell
commit.

The repository ships four validation interfaces:

- `Test-Environment.ps1 -Json -Strict` checks prerequisites and source pins.
- `Test-Smoke.ps1 -BuildRoot <build> -QtPrefix <qt>` runs the isolated
  production smoke above.
- `Test-InstallLicenses.ps1 -BuildRoot <build> -QtPrefix <qt>` installs,
  updates and uninstalls a temporary prefix while checking notices and profile
  preservation. It does not launch the live shell or enable autostart.
- `Test-PublicDocs.ps1` checks the shipped documentation for private
  references and unresolved links without network access.

Private fixture, benchmark and exploration harnesses are not part of the
production source tree. Their historical results are not current validation.
Keep validation output outside the checkout and record the exact source,
dependency pins, native build revision, commands and limitations.

Build once, then share the matching build read-only for review. A QML-only
change can stage its own production source against matching native artifacts;
native input or dependency changes require an incremental build by the build
root's owner. Do not change a payload during a measurement. Run appropriate
checks once; a failure needs diagnosis and a focused rerun.

## Installed-shell acceptance

Install and start using [the production shell instructions](shell/README.md).
Use [LIVE-CHECKLIST.md](docs/LIVE-CHECKLIST.md) for real input, device control,
mixed-DPI movement, recovery and daily use. Build and offscreen smoke passes
cannot establish those behaviors. Desktop takeover, autostart, tiling and
mutating hardware controls remain explicit opt-ins.
