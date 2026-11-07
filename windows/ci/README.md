# Public Windows CI

The active workflow is
[.github/workflows/windows-build.yml](../../.github/workflows/windows-build.yml).
The `windows-build.yml.template` is an inert identical copy for review and
recovery, not a second active workflow.

[Exact-pair integration](PAIR-INTEGRATION.md) documents immutable candidate
inputs, the trusted producer validator, separate source roots, receipt
semantics and coordinated backend/shell changes.

## Gates and build scheduling

Every push to `main`, pull request and manual dispatch runs fast source,
documentation, PowerShell, JavaScript and quota-provider regressions first.
After those pass, two jobs can run independently:

- Installer/rollback tests and the real colour-worker tests use isolated,
  temporary profiles and pinned Python dependencies.
- The native job prepares the Windows tools and runs an early, unrecorded
  Services preflight before compiling anything. It then runs the capture Rust
  tests, builds and tests the backend fixtures, builds the production payload
  and plugin tests once, and runs the recorded Services suite, plugin CTest,
  shell fixtures and production smoke. Compile parallelism comes from the
  runner's processors and memory; test execution stays serial.

Only a narrow allowlist of documentation and issue-template changes skips the
native job. Unknown files, empty diffs, first pushes and manual dispatches
require a build. The path decision itself has regression tests. Installer and
fast checks still run for documentation changes. The final `Windows validation`
job fails if any applicable gate failed, was cancelled or was unexpectedly
skipped. No branch-protection settings are changed by this workflow.

[Test-Validation.ps1](../scripts/Test-Validation.ps1) is the shared local/CI
entry point. [Coverage and exclusions](../tests/README.md) distinguish
offscreen checks from live-desktop acceptance.

## Tooling and cache trust

The authoritative [toolchain specification](../toolchain.json) selects
`windows-2022`, VC tools 14.44.35207 and SDK 10.0.26100.0 explicitly.
A hosted label is not a version pin: every build asserts the actual tool versions
before compiling. The toolchain includes Python 3.12, CMake 4.4.4, Ninja 1.13.2,
aqtinstall revision `076e1659807d0b362a3ed684d54c2e9c775eb9c7`,
Qt 6.11.2 `win64_msvc2022_64`, LLVM 20.1.8 and CLI11 2.5.0.
Qt includes `qtshadertools qtimageformats` and archives
`qtbase qtdeclarative qtsvg qttools`, not `qttranslations`.
Rust/Cargo 1.99.1 and explicit `x86_64-pc-windows-msvc` target build Glazier's
locked dependency graph. Rust is not selected through `stable`.
`Prepare-Toolchain.ps1` is the same local/hosted recipe: hash-locked Python
wheels, verified aqt source, LLVM/CLI11 SHA-256, six committed Qt archive hashes,
and the hash-checked official Rust release manifest plus rustup's component
verification. `Build-Prototype.ps1` never installs missing tools.
Preparation, build, release preflight, staging, smoke and shared QML fixture
entry points explicitly load inbox Utility/Archive modules from the running
PowerShell engine. This is process-local: loading them during preparation does
not repair a later Python-launched child process. The regression exercises each
entry point's real bootstrap with script-module discovery disabled and verifies
that it leaves the caller's `PSModulePath` unchanged.
Serviced compiler/linker file versions and Rust's official release commit are
asserted too. The selected VS redist marker must resolve CRT DLLs matching the
qualified `vcRedistVersion` (14.44.35211.0), not merely a plausible folder name.
The release preflight rechecks that same actual supplier source. Qt's packaged
SBOM compiler/linker versions are asserted separately; they do not declare a
minimum runtime or substitute for clean-VM acceptance.

The versioned exact-match cache contains Qt, LLVM/CLI11 archives and extracted
trees, and pip's download cache. Warm runs avoid extracting LLVM and CLI11
again. Archive checksums still run after restore, and required tool files and
versions are checked before use. Python tooling is installed fresh. The cache
identity includes the specification and Python locks, not a floating channel. Only
trusted pushes to `main` save this cache; pull requests and manual candidate
dispatches may restore it but cannot save it. There are
no native object, CMake build, Cargo target, staged-shell or installed-product
caches shared across trust boundaries. Change the cache schema key when the
tooling selection or extraction contract changes.
A ccache 4.14.2 object cache was measured and rejected: CMake 4.4 requests
clang-cl dependency files with `-clang:-MD/-MT/-MF`, and ccache deliberately
refuses `/clang:` options, so every compile was uncacheable. Do not work
around that with `ignore_options` or sloppiness.
The archive hashes authenticate the downloaded inputs, not every byte of an
already extracted cache tree. Reused extracted directories receive required-file,
version and supplier-metadata checks, not a complete per-file hash comparison
with those archives. Trust therefore rests on the existing trusted-`main`-only
cache writer boundary. An untrusted or suspect extracted tree must be discarded
and reprovisioned from the verified archives; it is not made trustworthy by a
version string. No new cache trust or performance guarantee is claimed.

All Actions are commit-pinned. Permissions stay read-only; checkout does not
persist credentials. There is no `pull_request_target`, injected publication
secret, installation into a user's profile, signing or release publication.
The source and every pinned recursive dependency must remain anonymously
accessible. Never substitute private dependency credentials.

## Evidence and limits

Fast and packaging jobs upload compact summaries containing test names, exit
codes, timings, source revision and dirty status, with three-day retention. Raw fixture
logs, profiles and provider data are not uploaded. Native jobs always upload
path-free `toolchain.json` receipts from preparation and build, including the
specification/lock digest and actual versions. Raw `build.json`, environment
reports and build logs contain deployment paths and are not artifact inputs.
The pair recorder retains bounded diagnostic categories in the public receipt.
On isolated hosted fixtures the workflow explicitly enables its `--echo` mode,
so producer, preparation, compile and test failures remain visible in the job
log. Nested integration failures also report the failed stage, exit code and
local log location. `-EchoDiagnostics` shows at most 80 lines / 16,000 characters
from the failed nested stage in that job log. Raw fixture logs are still excluded
from uploaded receipts and artifacts.
Its exact-pair receipts and sanitized JUnit have seven-day retention, as
documented in the [pair contract](PAIR-INTEGRATION.md#execution-and-receipts).

When debugging a pair failure, start with the first failed stage in
`integration-stages.json`, not a later receipt-finalization or envelope refusal.
Read that stage's output in the hosted job log, or its `<stage>.private.log`
under the local results directory. Quiet local mode still names the failing
stage, exit code and log path. Use `-EchoDiagnostics` only with disposable,
isolated fixtures. Never enable raw-output echo for a command that could read
personal data, credentials or secrets.

The native job runs the release assembler's read-only toolchain preflight on
the build receipt. Fast checks exercise supported receipts plus incompatible
VC/SDK/Rust/Qt/build tools, missing fields, stale specification hashes, corrupt
downloads, missing installed VC tools, servicing changes and missing/newer CRT
DLLs through the actual assembler preflight. The runtime minimum stays
14.44.35211.0. This receipt preflight is not a full package/lifecycle gate.

The preparation recipe and version assertions are implemented, not a hosted
pass. A new published PR run must establish clean hosted acceptance. The audited
run 42243987117 used `windows-latest` / VS 2026 and Rust 1.99.1; it did not retain
an actual VC-tools receipt, and no packaging failure was reproduced by the audit.

Local passes establish only the exact tested working tree, native runner and
scenarios. They do not establish hosted acceptance of a workflow edit. Record
fresh cold and warm hosted runs after publication before claiming a CI
performance improvement. Hardware, input, DPI, hotplug, sleep/wake and
long-running desktop acceptance still require the
[live checklist](../docs/LIVE-CHECKLIST.md).
