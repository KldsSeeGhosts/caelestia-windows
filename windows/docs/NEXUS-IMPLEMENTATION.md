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
attempts get distinct immutable identities. Future publication still needs
source ancestry, supersession and idempotency. Pointer sequence is independent.

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

## Missing and unaccepted

S5 and S6 are missing. No candidate assembler, write-token job, publisher,
promotion workflow or scheduled freshness task has been added. The active
Windows workflow and its template remain unchanged, as do producer
ae98287c8cd96db4ea4642cc91a1cd9ba7c32a1f and validator digest
220ab389252a15b8f4d9db25076aa01a927b3b07c62f3a07a76d1431d560f275.

Remaining producer work:

- Independently validate pinned trusted validator/receipt, raw nonzero test
  inventories, pair request, tested outputs and exact main
  repo/event/head/run/attempt/toolchain/source identity. Do not trust an
  editable pair-result boolean or weaken existing pair eligibility.
- Assemble from the tested native tree without recompilation. Complete
  histories, exact source/supplier/license notices and privacy coverage are
  mandatory. Retain only allowlisted public artifacts, not raw output.
- Separate data-only bundle verification/NoIntegration fixtures on Server 2022
  from real Windows 11 acceptance. Do not strip the production OS guard or
  introduce a production bypass flag.
- Wait for all canonical validation, including Packaging, before main-only
  gated publication. No workflow_run privileged consumption, self-hosted
  workstation runner or broad token permissions.
- Test immutable partial-upload recovery, same-bytes idempotency, attempts,
  overlapping/superseded builds and non-fast-forward pointers using fake
  git/gh before enabling writes.
- Implement identical-byte promotion and role-limited freshness for all
  configured channels. Only offline roots renew the keys document. Publisher
  expiry renewal must not weaken client expiry rejection.

Client tests cover primitives, persisted checks, fail-closed worker arguments,
existing rollback/uninstall transactions and offscreen QML. They do not yet
establish a full authenticated happy-path worker with synthetic
installer/readiness boundaries, every queue/TOCTOU/watchdog interruption, or
real redirected TLS download. Add those controls before configuring trust.
Guard mutation coverage is partial, not the design's full mutation matrix.

Hosted independent exact-SHA validation, source-asset assembly timing,
disposable Windows 11 update/rollback/update, interrupted downloads,
offline/clock behavior, autostart preservation and SAC/SmartScreen acceptance
remain gates. No release, key, secret, environment or channel was published.
