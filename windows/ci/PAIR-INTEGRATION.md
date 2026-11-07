# Exact shell/backend integration

## PR native reuse is not exact-pair evidence

QML/JS/asset-only PRs may run **Verified native reuse and offscreen regressions**
using `native-reuse-<sha>` from the newest validated main-push ancestor run of
`.github/workflows/windows-build.yml`. See [CI scheduling](README.md) for the
fail-closed classifier, artifact inventory and independent verification.
`Invoke-PairIntegration.ps1 -TestOnly` shares the Services, Shell and plugin
entry points, but returns before journal creation, compilation, release
preflight, smoke, integration reporting or any downstream receipt processing.
It writes only `reuse-tests.json`; the separate reuse summary records source,
producer, hashes and outcomes. It never produces or edits `candidate-result.json`,
`pair-result.json`, a downstream pair receipt or release eligibility.

Backend fixtures are skipped only after the unchanged gitlink and lock are
verified, because the trusted base main run validated that backend. Unavailable,
expired or refused reuse inputs select full fixtures/build/pair validation.
Once reuse tests start, a test failure fails the required aggregate. A skipped
reuse job cannot validate a reuse-classified PR. Main pushes always build fully;
candidate and publication semantics below are unchanged.

## Full exact-pair validation

The **Native build and offscreen regressions** and **Backend fixtures and
portable tier** jobs test an exact shell/backend pair in parallel. **Exact-pair
receipt** joins their evidence. **Windows validation** propagates failed, cancelled,
missing and unexpectedly skipped required jobs. These checks use hosted
Windows runners, read-only repository permissions and no release secrets or
personal desktop. Contract fixtures are not native acceptance.

## Inputs and source isolation

Dispatch **Windows build** with `mode=pinned` (default) or `mode=candidate`.
`shell_sha` defaults to the workflow's SHA. Every supplied source identifier
must be exactly 40 lowercase hexadecimal characters, not a branch, tag,
abbreviation or PR number. The shell commit must already contain this entry
point and the supported toolchain. Missing commits, incompatible shells,
dirty checkouts, noncanonical origins and resolved-SHA mismatches fail.

Pinned mode rejects a supplied `backend_sha`, requires the backend gitlink and
source lock to agree, and requires that revision to be an ancestor of backend
`main`. PR checks test GitHub's exact synthetic merge SHA, not an assumed PR
head. Candidate mode requires `backend_sha` and creates a separate canonical
backend clone outside the shell. It never checks a candidate out into the
shell submodule or rewrites `sources.lock.json`. The shell's normal strict
dependency checks remain enabled.

Manual and main-push runs have unique concurrency groups and cannot cancel
each other, including pending runs. Only superseded PR runs are cancellable.
Only a **push to main** can save the shared tooling cache. Candidate dispatches
and fork PRs may restore, but cannot save that trusted cache.

## Execution and receipts

The consumer pins the backend producer's revision and validator blob SHA-256
in [pair-contract.json](pair-contract.json). It fetches that known revision,
extracts the validator, verifies its digest before execution and uses that
copy for every recorder action. The backend under test does not supply the
pass validator. Producer contract tests and the fixture-phase runner are
extracted from the same known revision. The producer's canonical `override`
field stays `false`; explicit candidate status is recorded by the consumer.

The recorded stages are source inspection, producer contract fixtures,
canonical tool preparation, backend fixture configure/build/portable tests
and consuming-shell integration. `fixtures` and `build` run in parallel, each
with independent sources/producer/prepare stages and an unfinalized receipt.
The `pair` join requires both jobs to succeed and their actual-toolchain records
to be identical before trusted merge, normal finalize and independent envelope.
One-day exact-run/attempt artifacts carry allowlisted inputs. Candidate assembly
depends on the join and aggregate validation. Documentation-only runs must skip
fixtures, build and pair together. Estimated critical path is
`max(fixtures, build) + join overhead`, plus checkout/tool preparation.
Integration executes:

1. Services suite.
2. Production `Build-Prototype.ps1 -PublicRelease -PluginTests -Jobs <jobs>`,
   including the actual backend, plugins, M3Shapes and locked Glazier.
3. The release assembler's read-only toolchain preflight.
4. Plugin CTest with `--no-tests=error`.
5. Shell suite.
6. Production graph staging and isolated offscreen smoke.

`<jobs>` is measured once per native job by
[Get-BuildJobs.ps1](Get-BuildJobs.ps1): the smaller of the logical processor
count and `floor(physical memory / 3 GiB)`, clamped to 1-16. Invalid or nonfinite
memory measurements fail closed. The same value drives the capture Rust build,
the trusted fixture build and production. It changes compile scheduling only.
CTest, QML suites and recorded stages stay serial.

Before any native compilation, the workflow runs the same Services command
once with `-ServicesPreflightRoot`. That early copy writes only under its own
fresh root, disjoint from pair results, the production build, sources and
read-only tools in both directions. Preflight rejects junction/symlink
ancestors on these paths rather than guessing where output will land.
It is not recorded in the receipt or envelope and is never evidence.
A failure stops the job early; a pass changes
nothing, because recorded integration reruns Services from scratch.

Candidate builds require both `-BackendRoot` and
`-CandidateBackendRevision`; smoke requires the same explicit SHA.
Release assembly rejects candidate and legacy builds, including candidates
whose SHA happens to equal the current pin. The toolchain-only preflight
remains available to candidate tests.

`pair-results-<run-id>-<attempt>` retains only the request, producer receipt,
consumer envelope and sanitized portable/integration JUnit for seven days.
The envelope independently checks downstream kind, both requested/resolved
SHAs, the tested shell's spec and combined toolchain digest, actual integration
stage outcomes and nonzero plugin/integration tests. It records normalized
commands with private paths replaced by role tokens, real stage durations,
suite command counts, available assertion counts, CTest counts and skip
reasons. Gate-command counts and executable counts are not assertion counts.
Unreported assertions remain explicitly uncounted.

Raw command output, profiles, local-root metadata, original JUnit and logs
stay private on the runner and are not artifact inputs. The recorder does not
stream raw native output to Actions. Stage state is saved before launch and
after exit. A failed or interrupted stage, missing report, zero tests or
cancelled workflow can never become a pass through artifact upload. When the
runner can finalize, failure receipts are retained; checkout failure, hard
runner termination or upload failure can prevent an artifact altogether.
Read the actual check/run conclusion as well as the receipt.

Receipts are not signatures or an authorization boundary against arbitrary PR
code. A release consumer must additionally verify the producing workflow,
repository, run/attempt, successful conclusion and artifact provenance.

## Coordinated changes and final integration

Test an unmerged backend with a candidate dispatch first. After the backend
merges, update the shell gitlink and `quickshell.revision` together to the
backend **main commit**. That shell PR receives a fresh pinned-pair check.
After the shell merges, its main-push run tests its **own shell SHA**.
Only that successful pinned main-push pair can set `releaseEligible=true`.
Candidate preflight and PR receipts are never relabeled as the final pair.
Receipts are artifacts, not commits back into their own tested source.

The producer is temporarily pinned to backend PR #24 head
`d91a9128294f60d3c1d0ec6d278483d80544ce98`, including its byte-exact validator
digest. Hosted success/failure/cancellation controls still gate qualification;
a merged producer is not itself a successful consumer receipt.
Replace this temporary revision after backend #24 merges; the validator blob
hash remains unchanged if the PR merges without changes.
The producer's shell pin supplies toolchain policy only, not the shell under
test, so updating it does not create a pair-SHA fixed point.

Public builds remap backend paths to `/backend/...` in both pinned and candidate
mode. Earlier pinned releases used `/source/windows/deps/quickshell/...`;
account for this change when comparing embedded source/debug strings or bytes.

## Local contract checks and hosted controls

```powershell
powershell -NoProfile -NonInteractive -File windows/scripts/Test-PairContract.ps1
```

These SDK-free tests use synthetic Git repositories and disposable receipts.
They cover mutable/missing inputs, mismatches, dirt, bad origins, external
candidate isolation, trusted validator digests, independent expectations,
failed/skipped stages, missing plugin reports and actual build/smoke/release
refusal paths without starting native applications.

Hosted acceptance must separately retain a clean pinned run, a valid unmerged
candidate run, missing/incompatible SHA refusals, a real backend API/import
break that fails the consuming shell, and a cancelled in-flight dispatch.
Inspect fork permissions, cache-save skips and final aggregation as well.
A contract-validator mutation alone does not prove downstream API detection.
Offscreen success establishes only the exercised staged graph and contracts,
not Windows 11 graphics, hardware, interactive input or package qualification.
