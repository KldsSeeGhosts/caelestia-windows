# Nexus implementation boundaries

This is an implementation handoff, not release or live acceptance.

## Implemented

- Authoritative native core 0.2.0 and build provenance digest; general SemVer 2
  parsing/precedence and a separate restricted publication grammar.
- Strict UTF8/integer JSON with duplicate/case-conflicting field rejection;
  DSSE PAE and CNG P-256 SHA256/P1363 verification and PKCS8 signing.
  Root/delegation thresholds and roles, expiry, repository/channel/release
  bindings, replay and same-build/different-payload rejection.
- Unconfigured trust performs no transport. Serialized atomic root/keys/channel
  highwater lives outside installation/profile.
- Bounded HTTPS with system proxy defaults, no credentials/cookies, explicit
  redirect/final-host policy and body cancellation. No TLS, certificate or OS
  security setting changes.
- ZIP preflight before writes: local nonlinked paths, canonical components,
  signed count/size, case duplicates, file/directory collisions and special-file
  rejection. Counting extraction uses CreateNew.
- Existing maintenance queue, watchdog, journal, selector fence and both
  installation mutexes. Worker invokes the verified installer on the same
  thread without releasing those locks. Recursive acquisition is natively
  tested. No second process cleanup/activation path.
- Nexus explicit checks, channels, confirmation, notes, progress and singleton
  ownership after page close. Old status/journal schemas remain readable.
- Exact committed-byte source notice rules for added payload files.
  New root helpers remain self-sufficient after rollback.

## Design corrections

General SemVer allows `+metadata`, ignored for ordering. Numeric identifiers use
decimal string comparison, not bounded integer parsing.

Development identity is plain SemVer, computed from the reviewed base and
immutable first-parent merge titles. Allocation never reads publication state
or mutable labels. Gaps consume versions and re-runs keep their original version.
Publication requires strict channel advancement, source ancestry and unchanged
immutable bytes. Pointer sequence and run/attempt provenance are independent.
See [VERSIONING.md](../../VERSIONING.md) for the bridge prerequisite and fold.

The compiled native version, display version and build version agree.
Development and preview tags have channel suffixes. Stable uses an unqualified
tag and requires tested 1.0-or-newer bytes, never a relabelled 0.x payload.
Promotion preserves identical artifacts and changes only signed channel records.

CNG ECCPUBLICBLOB import avoids modern-only EC import APIs. P1363 signatures
are explicitly 64 bytes; native PKCS8 import is tested. This is not full TUF.

Authenticated absolute ZIP count/size bounds replace the arbitrary 200:1
compression ratio rule. TLS flags are not globally changed.

Continuous installation locking and same-thread installer invocation replace
the unsafe unlocked-download/child-installer handoff. Profile schema changes
fail closed; there are no automatic snapshots, migrations or unrelated profile
reads. Security highwater survives uninstall even with profile purge.

## Candidate and publication implementation

S5 and S6 are implemented, gated by owner-controlled variables. The active Windows workflow and
its template remain byte-identical, temporarily pinning backend PR #24 producer
bd5c68196edbdaad23db8f28ca64214d075711b4 and validator digest
e7e890428a49812208866349a00482cf0cddbca6ebbaf71cb7a06a5c3284b5a0.

Development releases are signed after one full verification pass on the exact
main commit. Production runs before the recorded tests and exports its native
files. The read-only assembly job consumes that same-run artifact and prepared
sources while tests continue. It runs the source, assembly, coverage, license,
original-ZIP and payload content gates once. A credential-free sealing step
independently verifies final pair evidence, exact native inventory equality and
all asset hashes, then writes the unchanged candidate schema and evidence
provenance. Development publication retains run, receipt, version and header
checks without repeating content verification. Preview or stable promotion
re-verifies sources and payload independently. The deleted shadow experiment
has no remaining workflow path.

- Independently validate the pinned trusted validator/receipt, raw nonzero test
  inventories, pair request, tested outputs and exact main
  repo/event/head/run/attempt/toolchain/source identity. Do not trust an
  editable pair-result boolean or weaken existing pair eligibility.
- Assemble from the production native tree without recompilation, including the
  prebuilt managed supervisor. The pre-validation build inventory hashes every
  consumed native output, rechecked before assembly and against the final
  manifest. Complete
  histories, exact source/supplier/license notices and privacy coverage are
  mandatory. Retain only allowlisted public artifacts, not raw output.
- Separate data-only bundle verification/NoIntegration fixtures on Server 2022
  from real Windows 11 acceptance. Do not strip the production OS guard or
  introduce a production bypass flag.
- Wait for all canonical validation, including Packaging, before main-only
  gated publication. No workflow_run privileged consumption, self-hosted
  workstation runner or broad token permissions.
- Behavioral fixtures cover immutable partial-upload recovery, same-bytes idempotency, attempts,
  overlapping/superseded builds and non-fast-forward pointers using fake
  git/gh before enabling writes.
- Identical-byte promotion and role-limited freshness cover all
  configured channels. Only offline roots renew the keys document. Publisher
  expiry renewal must not weaken client expiry rejection.

Candidate eligibility is recomputed through the unchanged pinned validator,
not accepted from a pair-result boolean. Publication additionally checks the
exact GitHub repository/event/main/workflow/run/attempt, successful prerequisite
jobs and same-run artifact metadata. Sources/notices are independently
reproduced; payload verification executes checkout code only. Retained assets
are explicitly allowlisted; raw logs/build/environment/profile data stay local.

Draft assets are uploaded without clobber, downloaded and hash-verified before
finalization, then exposed by a non-force pointer CAS. Authenticated existing
record bytes are reused on retry despite randomized signatures. Rerun attempts
require new producer outputs. Partial old drafts stay unreferenced. Promotion
copies identical assets and requires exact core/ancestry/monotonic aliases.
Development and promotion freshness use distinct roles; only offline roots
renew the keys document. Expired-pointer publisher renewal is not a client
expiry bypass. Missing, invalid, expired and revoked metadata stay distinct.

Worker tests now exercise Check, actual generated queued arguments, authenticated
download/extract/bootstrap/install, rollback and reinstall, retained profile
bytes and trust highwater, stale and late selectors, changed signed target,
wrong manifest, both queue exclusions, interruption and watchdog fencing.
Tasks, transport, readiness and integration use recording boundaries on
disposable data. These are not real HTTPS or Windows installation acceptance.
Pipeline tests use ephemeral native CNG primitives, a fake GitHub API and a
local bare Git remote. Guard mutation coverage remains partial, not the full
design mutation matrix.

Candidate failures report the stage, exit code and private log location.
Disposable CI opts into an 80-line/16,000-character diagnostic tail; private
logs are never retained release assets. Publication emits fixed gate reasons
and preserves source/payload/crypto child diagnostics privately without
echoing signing environments, arguments or arbitrary exception values.
Both new assembly/verifier entrypoints explicitly import the running Windows
PowerShell engine's inbox modules, including under inherited PowerShell 7
module paths.

Local CORE-local assembly and complete source preparation are also exercised
without signing or publication. A separately labelled data-only rehearsal
uses the unchanged local manifest/native bytes, not a forged development
identity. Neither rehearsal establishes exact-main Actions eligibility.
Release notes link the immutable tested changelog and source, rather than
automatically quoting commit subjects.

## Inactive and unaccepted gates

Shipped trust is configured with root
`f9f6c4d0f94cedcd81a6abb84b1b60b1e58b59c54cb723d4f583e22d24602893`,
root version 1 and threshold 1, for development activation. Preview/stable
promotion and freshness remain inactive. Workflow variables are unset by
default. The ordered owner procedure in [UPDATES.md](../../UPDATES.md) covers
offline generation, `New-NexusKeysDocument.ps1`, the keys-only orphan
`nexus-channels` branch, branch protection, the main-only `nexus-development`
environment/secret, `NEXUS_DEVELOPMENT_PUBLISH=enabled`, first main publication
and `Get-NexusBootstrapRelease.ps1`.

No private owner key, GitHub secret, environment, metadata branch, channel or
release was created by this change. Owner-tool CLI tests use ephemeral keys
and disposable files under Windows PowerShell 5.1. Bootstrap tests use recording
transport, not real HTTPS. The client verifier and trust loader are unchanged.
First publication seeds a missing development pointer, but requires an existing
branch and valid root-signed keys document. Freshness skips missing pointers;
it does not bootstrap them. Branch rules that prevent Actions non-force pushes
or token write permissions would block publication.

Hosted independent exact-SHA validation, source-asset assembly timing,
disposable Windows 11 update/rollback/update, interrupted downloads,
offline/clock behavior, autostart preservation and SAC/SmartScreen acceptance
remain gates. First hosted candidate timing and supplier acquisition must be
measured; the native job's 120-minute budget is an upper bound, not a timing
claim. No release, key, secret, environment or channel was published.
