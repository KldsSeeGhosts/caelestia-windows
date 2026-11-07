# Nexus updates

## Current status

The source contains an authenticated updater client. It is **not activated**.
Shipped trust has no public keys and says `unconfigured`. Checking therefore
makes no network request. Candidate assembly, publication, promotion and
all-channel freshness are implemented but inactive. Their first independent
hosted exact-main run and disposable Windows 11 acceptance remain gates.
A source merge never changes an installed shell.

Public previews remain manual downloads at
https://github.com/KldsSeeGhosts/caelestia-windows/releases.

## After owner activation

Open Nexus, Updates, choose a channel, and explicitly check. Opening the page
does not check automatically. Development requires a second acceptance click.
Preview is the pre-1.0 default; stable is the default from 1.0 when no channel
was selected. Explicit channel selection persists across updates and rollback.
Stable only accepts deliberate 1.0-or-newer promotion, never development
fallback.

An available update shows its channel alias and immutable artifact build
separately. Confirmation downloads, verifies and restarts through the existing
versioned installer. The maintenance singleton owns the request after Nexus
closes. If its result is unconfirmed, refresh the selected version instead of
queueing another request.

Only a strictly newer artifact is offered. A channel switch to an older or
identical build does not reinstall or downgrade. The installed alias describes
the deployment that installed it; checking another channel does not rewrite
artifact identity. Manual bootstrap without an alias receipt truthfully shows
the development build.

Settings stay in the existing profile. This client supports profile schema 1
only and refuses a different schema, rather than silently migrating or
snapshotting arbitrary settings. Rollback selects the retained previous
payload, without restoring old settings. Future migrations require an explicit
compatibility and backup/restore design.

Signature, freshness and network errors never authorize installation.
Root-anchor, keys and channel highwater remain separately under
`%LOCALAPPDATA%\caelestia-update-trust` through rollback and uninstall,
including profile purge. Do not delete this state to get past an error.
Temporary bytes use `%LOCALAPPDATA%\caelestia-windows-updates`. Completed
operations delete their own ZIP/staging tree. Interrupted bytes are never
resumed or reused as trusted input.

## One-time bootstrap

The existing Preview 2 shell has no updater and cannot update itself.
Keep its original ZIP. After producer/client acceptance, rehearse first in a
disposable Windows 11 profile or VM:

1. Authenticate the first updater-enabled bundle's signed release record using
   a reviewed checkout and independently confirmed root fingerprints. A hash
   beside the same untrusted download is not authentication. Initial trust
   establishment is an owner action.
2. Extract outside prefix and profile. Run its installer with
   `-ExpectedManifestSha256 <authenticated-digest> -Restart`. Add `-Autostart`
   only if already opted in. No optional scheme download is needed.
3. Verify current/previous identity and unchanged settings, then check,
   update, rollback and update again through Nexus.

This work does not alter the user's existing Preview 2 install. Live bootstrap
requires separate explicit authorization.

## Operator setup, after the remaining gates

This is DSSE with a custom role policy, not full TUF. Metadata authentication
is separate from Authenticode. Payloads remain unsigned preview code.

- Generate offline root keys using `windows/ci/New-NexusSigningKey.ps1` into
  a new private directory outside source/output/payload trees, preferably an
  encrypted offline volume. Its PKCS8 output is unencrypted; secure it and
  never commit/upload it. Online development/promotion keys must be distinct.
- Review a public-key-only trust PR with fingerprints and threshold. Increment
  `rootVersion` for root-set/threshold changes. Highwater rejects older roots
  or different anchors at the same version. Ship overlapping old/new roots
  through the old authorized chain before removing old roots.
- Create a root-signed keys document with development-only and
  preview/stable-only roles, expiry and increasing version. Delegated keys
  cannot renew this offline-root document.
- Once implementation and hosted candidate evidence are reviewed, protect `nexus-channels` against
  force push/deletion. Restrict development publishing to main and its own
  environment/key. Require owner review and a separate promotion environment
  for preview/stable publication and freshness.
- Renew **every configured channel**, without changing its release.
  Development credentials must never refresh preview/stable. Expired
  publisher renewal must still verify the old signed document, increment
  sequence and bound new expiry. Clients continue to reject expiry.
  Missing-first-pointer, malformed-pointer and expired-pointer cases differ.
  Root/key expiry and rotation are separate gates.
- Enable publisher variables last, after exact-main hosted validation,
  source/supplier/license/privacy coverage and immutable asset verification.
  `NEXUS_DEVELOPMENT_PUBLISH=enabled` enables development publication and its
  freshness job in `nexus-development`. `NEXUS_PROMOTION_PUBLISH=enabled`
  enables explicit promotion and preview/stable freshness in `nexus-promotion`.
  Both environments must restrict deployment to main; promotion requires
  owner review, including scheduled freshness. Their distinct secrets are
  `NEXUS_DEVELOPMENT_SIGNING_KEY` and `NEXUS_PROMOTION_SIGNING_KEY`.
  A secret is base64 PKCS8, or a JSON array of base64 PKCS8 values for a
  distinct-key threshold. Keys remain in process memory, never repository files.

Same-attempt retries recover partial drafts without replacing assets or tags.
An Actions rerun has a new immutable attempt identity and requires the full
producer job to rerun; it cannot adopt a previous attempt's candidate.
Superseded builds do not move pointers. Pointer commits use non-force CAS and
bounded revalidation/retry. Invalid pointers never become missing pointers;
only first publication seeds a missing channel. Online freshness can renew an
expired authentic pointer with currently authorized keys, not expired keys or
the offline keys document. Clients still reject expired metadata.

Promotion copies identical tested assets, including the unchanged development
manifest and compiled core. Only signed alias/pointer records change. A stable
1.0 release therefore requires tested 1.0-core bytes; 0.2 cannot be relabelled.
No release pruning or unreferenced draft cleanup runs automatically.

See [VERSIONING.md](VERSIONING.md) and the
[implementation boundaries](windows/docs/NEXUS-IMPLEMENTATION.md).
