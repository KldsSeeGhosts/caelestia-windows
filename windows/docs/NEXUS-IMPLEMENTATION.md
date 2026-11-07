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

Development identity is `CORE-dev.EPOCH.RUN.ATTEMPT`, replacing devFloor and the
999999 cap. Reviewed epoch increments handle workflow replacement/reset;
attempts get distinct immutable identities. Publication requires source ancestry,
supersession and same-attempt idempotency. Pointer sequence is independent.

Compiled core, signed channel alias, immutable build and selected channel are
distinct. A stable 1.0 alias promotes tested 1.0-core bytes, never a 0.2 payload.

CNG ECCPUBLICBLOB import avoids modern-only EC import APIs. P1363 signatures
are explicitly 64 bytes; native PKCS8 import is tested. This is not full TUF.

Authenticated absolute ZIP count/size bounds replace the arbitrary 200:1
compression ratio rule. TLS flags are not globally changed.

Continuous installation locking and same-thread installer invocation replace
the unsafe unlocked-download/child-installer handoff. Profile schema changes
fail closed; there are no automatic snapshots, migrations or unrelated profile
reads. Security highwater survives uninstall even with profile purge.

## Candidate and publication implementation

S5 and S6 are implemented, inert by default. The active Windows workflow and
its template remain byte-identical, with unchanged producer
ae98287c8cd96db4ea4642cc91a1cd9ba7c32a1f and validator digest
220ab389252a15b8f4d9db25076aa01a927b3b07c62f3a07a76d1431d560f275.

- Independently validate the pinned trusted validator/receipt, raw nonzero test
  inventories, pair request, tested outputs and exact main
  repo/event/head/run/attempt/toolchain/source identity. Do not trust an
  editable pair-result boolean or weaken existing pair eligibility.
- Assemble from the tested native tree without recompilation, including the
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

Trust has no keys. Workflow variables are unset by default. Owner setup is
documented in [UPDATES.md](../../UPDATES.md). No private key, secret,
environment, branch, channel or release was created. The owner key-tool CLI
acceptance was not run after an execution-policy denial and must not be
inferred from primitive tests.

Hosted independent exact-SHA validation, source-asset assembly timing,
disposable Windows 11 update/rollback/update, interrupted downloads,
offline/clock behavior, autostart preservation and SAC/SmartScreen acceptance
remain gates. First hosted candidate timing and supplier acquisition must be
measured; the native job's 120-minute budget is an upper bound, not a timing
claim. No release, key, secret, environment or channel was published.
