# Public Windows CI

Validation and Nexus delivery use separate jobs with read-only permissions
outside publication. See [implementation boundaries](../docs/NEXUS-IMPLEMENTATION.md).

The active workflow is
[.github/workflows/windows-build.yml](../../.github/workflows/windows-build.yml).
The `windows-build.yml.template` is an inert identical copy for review and
recovery, not a second active workflow.

[Exact-pair integration](PAIR-INTEGRATION.md) documents immutable candidate
inputs, the trusted producer validator, separate source roots, receipt
semantics and coordinated backend/shell changes.

## Gates and build scheduling

Every push to `main`, pull request and manual dispatch starts `Change scope`
on Ubuntu 24.04 alongside Fast regressions and two packaging shards on separate
Windows runners. Each of these jobs refuses mutable dispatch inputs before
checkout. Scope uses a full-history checkout; its `native=none|reuse|full`
decision unlocks the applicable native gates:

- Fast source, documentation, PowerShell, JavaScript and quota-provider regressions.
- Installer/rollback tests and the real colour-worker tests use isolated,
  temporary profiles and pinned Python dependencies. The Packaging inventory in
  `Test-Validation.ps1` assigns VersionedInstall to `-Shard 1/2` and the remaining
  seven tests to `-Shard 2/2`. Warm run 42421527915 attempt 2 measured 139.45s
  and 145.90s respectively. Colour tests run beside shard 1 only. Matrix
  fail-fast is disabled; validation requires the entire matrix to succeed.
  Omitting `-Shard` still runs the complete inventory. `-ListTests` reports
  the selected names without executing tests.
- `fixtures` prepares tools, records sources/producer/prepare, then runs backend
  configure/build/portable and inventory on its own unfinalized receipt. It also
  runs the first-party capture Rust regressions and retains `capture-rust-*`.
- `build` prepares the Windows tools and runs recorded integration:
  Services, the production payload/plugin-test build, the read-only release
  toolchain preflight, plugin CTest, shell fixtures and production smoke.
  Compile parallelism comes from the runner's processors and memory. Shell
  fixtures use two independent PowerShell processes at a time, with separate
  output roots and disposable profiles. Every fixture still checks its original
  assertion floor and timeout; every selected script must finish. Failures do
  not cancel the remaining fixtures. Services, CTest and integration stages
  stay serial. Local validation defaults to serial; `-Suite Shell -QmlJobs 2`
  opts into the same scheduling.
  Recorded Services runs before compilation. CI omits the duplicate unrecorded
  preflight; the local `-ServicesPreflightRoot` diagnostic remains available.

`pair` waits for both native jobs to succeed, checks out the same recursive ref,
re-resolves the pair and re-bootstraps the trusted producer. It requires identical
actual-toolchain JSON records (all fields, independent of key order), merges the
unfinalized receipts, finalizes with fresh source verification and independently
computes the envelope. It does not compile or restore tools.

Full-build graph: `{scope, checks, packaging[1/2], packaging[2/2]}` start together;
`scope -> {fixtures, build}`;
`{fixtures, build} -> pair`; `{scope, checks, packaging, fixtures, build, pair}
-> validation`; `{scope, pair, validation} -> candidate -> publish`.
Estimated native critical path: `max(fixtures, build) + join overhead`.
Observed stage durations of 8m45s and 9m30s suggest roughly 9m30s plus join
instead of 18m15s sequential work, excluding checkout/tool preparation and
artifact service variability.

Only pull requests may skip compilation. Documentation-only means `none` for
the existing top-level README/CONTRIBUTING and Windows README/NATIVE-BUILD/
ROADMAP/docs Markdown paths. `.github/` and `windows/ci/`, including their docs,
always mean `full`. For other PR changes, `Test-CaelestiaCiNativeInput`
governs reuse. It extends the installer/release `Test-CaelestiaCaptureNativeInput`
override (which stays unchanged, so local script edits can still be installed
over an existing native build) and fails closed: only QML/JS/image/font files
already declared in `windows/shell/sources.json` are non-native. Native paths,
build/test scripts, toolchain, locks, gitlinks, unknown files, ambiguous names
and empty diffs require `full`. Every non-PR event, first push or unavailable
base also means `full`. No separate broad UI path list is maintained.

`reuse` runs **Verified native reuse and offscreen regressions** with read-only
contents/actions access. Among the 30 newest `push` runs of this exact workflow
file on `main`, it picks the newest whose head SHA is an ancestor of the PR head,
whose **Native build and offscreen regressions** and **Windows validation** jobs
succeeded, and which has a live `native-reuse-<sha>` artifact. It then downloads
that artifact using the run ID and the read-only GitHub token. Release delivery
jobs (candidate, publication) are not native validation and do not affect
eligibility. Right after a merge, while the newest main run is still building,
the previous validated ancestor is used. `verify` then independently reclassifies
the whole ancestor..head diff, so any native change in between selects `full`.
Only trusted main pushes upload these artifacts. Fourteen-day retention keeps
recent producers useful without indefinitely storing executable build outputs;
older ones deterministically fall back to compilation.

The artifact contains `b-public/logs/build.json`, `quickshell/qs.exe`,
`install/caelestia-capture.exe`, `install/DesktopTakeover.dll`, the installed
native QML tree, and plugin test EXEs/DLLs plus generated `CTestTestfile.cmake`
entry points under `caelestia/`. `reuse-files.json` inventories every transferred
file. It contains no pair receipts, CMake cache, objects, PDBs or release
eligibility. The exporter shares the native allowlist with candidate transfer.

Before tests, verification requires the recorded base revision and clean
source, unchanged backend gitlink/source lock/toolchain spec, matching backend
pin, every `nativeInputs` hash, every transferred-file hash, complete inventories,
and an independent base-to-head classifier rerun. Reuse restores, never saves,
the tooling cache for Qt and provisions only hash-locked Python test tools.
Missing/expired artifacts, unavailable trusted runs, failed verification or
missing Qt runtime select the normal fixtures/build/pair path. Test failures
after successful verification fail validation.

The existing `Invoke-PairIntegration.ps1 -TestOnly` path calls the same Services,
Shell and plugin CTest entry points against the PR checkout, without compilation
or pair reporting. Backend fixtures are skipped because the unchanged backend
pin was validated by the successful base main run. The separate
`native-reuse-summary.json` records base SHA, producing run ID, artifact name,
verified hashes and test outcomes, never pair-result or release eligibility.
Candidate/publication remain full-build main-only.

Reuse can only be exercised after a main run containing this producer completes.
The target of roughly 5-6 minutes end to end is an estimate, not a measured
result; checkout, cache and artifact transfer can change it.

The path decision itself has regression tests. Installer and
fast checks still run for documentation changes. The final `Windows validation`
job fails if any applicable gate failed, was cancelled or was unexpectedly
skipped. In reuse mode it requires reuse success with all three native jobs
skipped, or an explicit full fallback with all three successful. In `none` mode
reuse and all native jobs must be skipped. No branch-protection settings change.

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
versions are checked before use. A separate exact-key cache contains the prepared
Python venv, including pip, bootstrap packages, locked tools and verified aqt.
Its key includes the full setup-python patch version and runtime fingerprint,
specification, both locks, preparation recipe and verifier. A rebuilt interpreter
with the same version selects a new key. Only a trusted main push saves it. Before any
cached program runs, the uncached setup-python interpreter verifies the pinned
input digest, interpreter identity, original installation paths and every file
hash, including metadata and bytecode. Missing environments use the normal
hash-locked installation. Incomplete or changed environments fail preparation.
Archive verification, Rust provisioning and actual-toolchain assertions still
run after a cache hit. This cache uses the same trusted-writer boundary as the
extracted tool cache; its inventory is not a signature. Pull requests and manual
candidate dispatches may restore either cache but cannot save them. There are
no CMake build, Cargo target, staged-shell or installed-product caches.
Change the cache schema key when the
tooling selection or extraction contract changes.
A ccache 4.14.2 object cache was measured and rejected: CMake 4.4 requests
clang-cl dependency files with `-clang:-MD/-MT/-MF`, and ccache deliberately
refuses `/clang:` options, so every compile was uncacheable. Do not work
around that with `ignore_options` or sloppiness.

The opt-in replacement is sccache 0.15.0, provisioned by
`Prepare-Sccache.ps1` with the same SHA-256-pinned archive as the backend.
It is only an accelerator: if the download fails (for example GitHub release
5xx errors), the script deletes the partial archive, writes a `::warning::`,
sets no `CI_COMPILER_LAUNCHER` and exits 0, and the jobs build without a compiler
launcher. The workflow then passes neither `-CompilerLauncher` nor
`-RustCacheDirectory` to the production integration, skips the statistics steps
and saves no cache. A checksum mismatch, extraction failure or version mismatch
still fails the step.
Backend hosted windows-2022 measurements reduced fixture compilation from
366 seconds cold to 104 seconds warm: 290/291 hits, zero non-cacheable
compilations, zero errors, about 8 MB of objects. Unlike ccache, sccache handles
CMake 4.4's clang-cl dependency flags. The backend pin also reduces fixture
compile edges from 291 to 224 and the recovery test from about 46 to 15 seconds.
These backend measurements are not shell end-to-end performance evidence.

Fixtures and production use separate runner-local `SCCACHE_DIR` directories and
restore-only Actions caches. Keys include schema, sccache version and canonical
toolchain contract, then `-main-<run_id>-<attempt>`; restore prefixes omit source
and CMake files because sccache keys each object by compiler, arguments and
preprocessed input. Every save requires a successful trusted `main` push.
PRs and dispatches only restore. Text/JSON statistics are retained for seven
days and the server must stop successfully before saving. Objects, like
extracted tools, rely on this writer trust boundary, not just archive hashes.
No objects or cache state enter native reuse/candidate artifacts or receipts.

`Build-Prototype.ps1 -CompilerLauncher <absolute executable>` is explicit opt-in;
without it every configure clears both C/C++ launchers, including existing
CMake caches. With a launcher it also disables precompiled headers
(`CMAKE_DISABLE_PRECOMPILE_HEADERS=ON` plus the backend's `NO_PCH=ON`), because
sccache cannot cache MSVC-style PCH compiles (`/Yc`, `/Fp`): on hosted CI, 409 of
590 production compiles were uncacheable with PCH on. PCH changes compile speed,
not the program. Locally (16 threads) the full C++ build took 88 s with PCH,
127 s with PCH off and a cold cache, and 48 s warm, with 569/569 compiles
cacheable. Backend `49bcf7b` added the one include that had relied on the PCH.
Without a launcher, PCH stays on. The shared configure arguments cover backend/brightness,
optional fixtures, M3Shapes and plugins. CI passes the launcher only to the
production integration build and the backend fixture gate. Local developer
builds, tooling contracts and `logs/build.json`/`nativeInputs` provenance
semantics are unchanged. Release/debug-info flags are not changed for caching.
Production also opts into `-RustCacheDirectory C:\sccache-rust-production`.
Only its Cargo invocation sets `RUSTC_WRAPPER` to the same pinned launcher,
disables incremental compilation and selects a separate cache directory and
server port 4227. The C/C++ server stays on its default port. The build restores
the caller's Rust/cache environment afterward. Rust has its own restore-only
Actions cache, trusted-main-only save and seven-day statistics artifact, which
also records the capture build duration. No Cargo target tree is cached.
On this Windows workstation with 16 build jobs and fresh Cargo targets, capture
release compilation took 41.75 s without the wrapper, 46.57 s cold and 17.15 s
warm. Warm Rust statistics were 26 hits and 2 misses, with 16 non-cacheable
calls, including 10 crate-type exclusions and 6 compiler probes. Sccache cannot
cache linked binaries or proc-macros, so the capture executable still compiles
and links on every fresh build. Sccache also reports one compilation failure
in each local run despite a successful Cargo build.
On hosted PR run 42421527915, a warm Rust cache (26 hits, 2 misses) cut the
recorded production integration step from 6m38s to 5m18s and the native job
from 9m37s to 7m54s. Push to `Windows validation` went from 10m31s to 8m50s.
Capture tests remain
uncached in fixtures. Public path remapping, capture hashes and the native
inventory in `logs/build.json` are unchanged.
The archive hashes authenticate the downloaded inputs, not every byte of an
already extracted cache tree. Reused extracted directories receive required-file,
version and supplier-metadata checks, not a complete per-file hash comparison
with those archives. Trust therefore rests on the existing trusted-`main`-only
cache writer boundary. An untrusted or suspect extracted tree must be discarded
and reprovisioned from the verified archives; it is not made trustworthy by a
version string. No new cache trust or performance guarantee is claimed.

All Actions are commit-pinned. Validation permissions stay read-only; checkout
does not persist credentials. There is no `pull_request_target`, privileged
`workflow_run` consumption or installation into a user's profile.
The source and every pinned recursive dependency must remain anonymously
accessible. Never substitute private dependency credentials.

## Evidence and limits

Fast and packaging jobs upload compact summaries containing test names, exit
codes, timings, source revision and dirty status, with three-day retention. Raw fixture
logs, profiles and provider data are not uploaded. Native jobs always upload
path-free `toolchain.json` receipts from preparation and build, including the
specification/lock digest and actual versions. Raw `build.json`, environment
reports and build logs contain deployment paths and are not artifact inputs.
Separate seven-day tooling diagnostics contain fixed directory labels, byte/file
counts before and after preparation, and phase durations for venv, each pip
install, aqt, Rust and final assertions. The seven-day production timing artifact
retains each native CMake configure/build/install duration beside capture timing,
the integration stage journal and the Services/Shell per-fixture summaries,
even on failure. Integration also prints each completed stage's wall time,
outcome and exit code in the job log. These files contain no
commands or machine paths and never enter pair receipts, envelopes or Nexus
inputs. Prepared Python verification and inventory creation have separate phase
timings. Cache hits record the avoided venv and pip phases as skipped, not as
new verification or test passes.
Candidate and publication diagnostics also retain path-free payload verification
phase timings for ZIP extraction, manifest/native checks, privacy scanning and
source coverage. They never enter candidate assets, signed metadata or gate
decisions. ZIP path checks still inspect every ancestor on every call. They use
native filesystem metadata reads without caching earlier link-check results.
Privacy scanning uses the same expressions and scans the same UTF-8 and two
UTF-16 views. Sensitive-content and private-root checks still run
for every view after a generic path is found. Differential tests compare the
previous policy in fresh processes under invariant, English and Turkish cultures,
including the existing current-culture case matching.
Literal private-root searches share prefix probes with the same ordinal
comparison. An absent prefix rules out a whole-root match; a present prefix
still requires the complete root. Prefixes never split a UTF-16 surrogate pair.
Binary drive-path searches first require a literal colon/separator pair;
the unchanged regular expressions still decide every possible match.
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

## Inactive Nexus delivery

After the exact-main pair gate, `New-NexusCandidate.ps1` independently
recomputes eligibility with the pinned producer validator and checks actual
tested native bytes/toolchain/source/version identities. It prepares full
source histories/notices, assembles without recompilation, checks final source
coverage/privacy and runs NoIntegration license lifecycle and original ZIP
verification. Server 2022 verification is data-only; actual install still
requires Windows 11. Assembly runs in its own bounded 120-minute job,
`Assemble exact-tested release candidate`, only after `Windows validation`
succeeds on a native main push. It never delays the required validation result
and cannot start after a failed packaging gate.

The receipt join stages `nexus-inputs-<run_id>-<run_attempt>` for one day. Its
allowlist preserves these paths, restored under `C:\` on the candidate runner:

- `b-public/logs/build.json`: tested provenance, toolchain and native hash inventory.
- `b-public/quickshell/qs.exe`, `b-public/install/caelestia-capture.exe`,
  `b-public/install/DesktopTakeover.dll`: tested executable/supervisor bytes.
- Every file recursively under `b-public/install/qml/`: tested plugins, helper
  DLLs and module metadata, independently re-hashed before assembly.
- `ci-pair/pair-request.json`, `candidate-result.json`, `pair-result.json`:
  immutable request, producer receipt and independent eligibility envelope.
- `ci-pair/integration-stages.json`: exact integration stage journal.
- `ci-pair/portable.xml`, `integration.xml`, `plugins.raw.xml`: independently
  recounted test reports and exported sanitized evidence.
- `ci-pair/Services/summary.json`, `ci-pair/Shell/summary.json` and only each
  summary's `results[].name + ".log"` files in that same suite directory:
  source identity, command outcomes and assertion counts used to recompute
  the envelope. These disposable CI logs are transfer-only, not release assets.

The one-day `pair-integration-<run_id>-<attempt>` build-to-join artifact uses the
same exporter with `-Integration`: the build files and suite reports/logs above,
`pair-request.json`, unfinalized `candidate-result.json`, `pair-local.json`,
production-measured `actual-toolchain.json`, `integration-stages.json`,
`integration.xml` and `plugins.raw.xml`. It excludes `pair-result.json` and
`portable.xml`. The local-root record is transfer-only, never retained or
included in candidate inputs. The one-day `pair-fixtures-<run_id>-<attempt>`
artifact contains only unfinalized `candidate-result.json`, `portable.xml` and
`actual-toolchain.json`. Exact run/attempt artifacts download to `C:/` and
`C:/fixture-input` respectively. The join uploads retained pair receipts/XML,
suite summaries and, on main pushes, the final `nexus-inputs-*` artifact.
Toolchain and capture-Rust artifacts stay with their producing jobs.
Only build can save the trusted-main tooling cache; fixtures and build each
save their own compiler objects on trusted main pushes.

No object/CMake trees, PDBs, environment dumps or unrelated diagnostics transfer.
The candidate checks out the exact SHA recursively,
completes source histories as needed, re-bootstraps the same digest-pinned
trusted producer and restores (never saves) the identical tooling cache key.
`Prepare-Toolchain.ps1` verifies/prepares the matching Qt deployment prefix.
`New-NexusCandidate.ps1` and its independent eligibility checks are unchanged.

A candidate-only rerun fails closed: its new run attempt has no matching
transfer artifact. Even if old evidence were supplied, the independent gate
rejects its pair run attempt (`pair-run-mismatch`). Rerun all jobs to regenerate
build evidence for the new attempt; after the one-day retention, a rebuild is
also required. The hosted candidate path can only be exercised by a real main
push, not a PR or workflow dispatch.

Candidate children run through `nexus_process.py`: start/end labels,
15-second heartbeats, private combined logs and explicit deadlines. Exact
commit history fetches allow 300 seconds, source preparation 1800, assembly
900, coverage/original-ZIP verification 300 each, and license/payload checks
600 each. Timeout exits 124 and terminates the owned Windows process tree.
Fetches are anonymous, noninteractive, nonrecursive and limited to the chosen
commit's ancestry; standalone bundles still require complete history.
Source preparation labels each supplier, notice group and Git bundle.
The three-day `nexus-stage-states` artifact contains stage name, outcome, exit,
duration and budget, plus fixed-label payload verification phase timings.
Publication retains the same path-free verification timings for seven days.
Private logs never become release artifacts.
Echoed failure tails remain bounded and limited to disposable CI inputs.
These limits diagnose stalled work, not certify candidate assembly speed.

The aggregate gate depends only on scope, fast, packaging and applicable native
validation, never candidate output. Publication waits for candidate success and
aggregate validation. Its write token and
development secret exist only in the variable/environment-gated main publish
job. Same-run artifact and exact successful prerequisite jobs are checked
again through GitHub. No PR artifact can reach publication.

`nexus-promote.yml` is explicit, main-only and owner-environment gated.
`nexus-refresh.yml` separately renews development and preview/stable using
their own roles. Every job is inert with the variables unset. Shipped development
root trust is configured with threshold 1; preview/stable promotion stays
inactive. See [UPDATES.md](../../UPDATES.md) for owner setup, immutable
attempt identities, CAS/retry/rotation and remaining external acceptance.
Unit runs native-crypto/fake-GitHub/bare-Git controls; Packaging runs disposable
authenticated worker transactions. These fixtures do not certify real hosted
supplier assembly, authenticated network delivery or live installation.
