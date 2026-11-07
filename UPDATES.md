# Nexus updates

## Current status

Shipped trust is configured for development activation with root fingerprint
`f9f6c4d0f94cedcd81a6abb84b1b60b1e58b59c54cb723d4f583e22d24602893`,
root version 1 and threshold 1. Explicit checks now use authenticated network
transport. Development publication and freshness require the owner setup below.
Preview/stable promotion and freshness stay inactive.
The first independent hosted exact-main candidate run and disposable Windows 11
acceptance remain release gates.
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

1. Use a reviewed checkout and independently confirm the full root fingerprint
   above. Run Windows PowerShell 5.1:
   `powershell.exe -NoProfile -NonInteractive -File windows\ci\Get-NexusBootstrapRelease.ps1 -OutputDirectory D:\NexusBootstrap`.
   The directory must not exist and must be outside the checkout. The tool
   fetches `v1/keys.dsse.json` and `v1/development.dsse.json`, executes the
   unchanged client verifier against shipped trust, and downloads the signed
   pointer's bundle with its exact size and SHA-256. The client requires no
   separate signed release record for development installation. The tool saves
   both authenticated envelopes and prints the manifest digest, build version,
   source revision and exact installer command. It does not extract or install.
2. Extract outside prefix and profile. Run its installer with
   `-ExpectedManifestSha256 <authenticated-digest> -Restart`. Add `-Autostart`
   only if already opted in. No optional scheme download is needed.
3. Verify current/previous identity and unchanged settings, then check,
   update, rollback and update again through Nexus.

This work does not alter the user's existing Preview 2 install. Live bootstrap
requires separate explicit authorization.

## Operator setup

This is DSSE with a custom role policy, not full TUF. Metadata authentication
is separate from Authenticode. Payloads remain unsigned preview code.

Perform these owner actions in order. This source change does not create
GitHub settings, credentials, metadata branches or releases.

1. Generate keys offline with `windows/ci/New-NexusSigningKey.ps1` into new
   private directories outside source/output/payload trees, preferably on an
   encrypted offline volume. The owner has already generated the shipped root.
   Its private PKCS8 is unencrypted. Never commit/upload it. Generate a distinct
   online development key. A future promotion key must also be distinct.
2. Run `windows/ci/New-NexusKeysDocument.ps1` with the offline root, public
   delegated keys, an increasing `-Version`, and an external new `-OutputPath`.
   For example:

   ```powershell
   powershell.exe -NoProfile -NonInteractive -File windows\ci\New-NexusKeysDocument.ps1 -RootPrivateKeyPath D:\OfflineRoot\private.pkcs8 -DelegatedKeysPath D:\NexusPublic\delegations.json -Version 1 -OutputPath D:\NexusPublic\keys.dsse.json
   ```

   `delegations.json` is a JSON array such as
   `[{"publicPath":"development/public.json","channels":["development"]}]`.
   Public paths are relative to that descriptor. Each entry can specify
   `notAfter` in UTC `yyyy-MM-ddTHH:mm:ssZ` format. Otherwise it uses `-Expires`,
   which defaults to 365 days. `-Expires` sets document expiry.
   `-Threshold` defaults to 1 and sets the delegated signing threshold.
   `-TrustPath` defaults to shipped trust. For root thresholds use
   `-RootPrivateKeyListPath D:\OfflineRoot\roots.json`, a JSON array of binary
   PKCS8 paths relative to the list file. This works with PowerShell 5.1
   `-NoProfile -NonInteractive -File` without native array/quote passing.
   Every signer must be a distinct authorized root. The tool self-verifies and
   prints public ids, roles, version, expiry and envelope SHA-256 only.
   Keep development separate from preview/stable. Only offline roots can renew
   this document. Do not give the root private key to Actions.
3. Create an orphan `nexus-channels` branch containing only
   `v1/keys.dsse.json`. Protect it against deletion and force-push. Allow the
   repository Actions token to make normal non-force pointer commits, without
   a required PR/review rule that would block this publication path.
   Do not seed `v1/development.dsse.json` manually. The publisher seeds a missing
   pointer at sequence 1. A missing branch or keys document blocks publication;
   an invalid existing pointer fails closed. Freshness never seeds a pointer.
4. Create environment `nexus-development`, with deployment branches restricted
   to `main`. Add environment secret `NEXUS_DEVELOPMENT_SIGNING_KEY`, the
   development private binary PKCS8 encoded as base64. A distinct-key threshold
   uses a JSON array of base64 PKCS8 strings. Keep this credential out of source
   and logs. Required reviewers, if added, must approve scheduled freshness too.
5. Set repository Actions variable `NEXUS_DEVELOPMENT_PUBLISH=enabled`.
   Leave `NEXUS_PROMOTION_PUBLISH` unset. Do not create/enable promotion as part
   of this activation.
6. Let the first push to `main` complete Windows validation, exact-run candidate
   assembly and development publication. Publication requires successful
   `candidate` and `validation` jobs, a nonempty same-run/attempt candidate,
   and an exact clean trusted checkout. Resolve failed gates before bootstrap.
7. Bootstrap with `Get-NexusBootstrapRelease.ps1` as described above, then
   rehearse update/rollback/update in a disposable Windows 11 profile or VM
   before any separately authorized live installation.

Development publication uses `contents: write` and `actions: read` job
permissions. Development freshness uses `contents: write`, runs Mondays at
08:23 UTC or via `workflow_dispatch` on `main`, and shares concurrency group
`nexus-publication` with publication. Both use `GH_TOKEN=${{ github.token }}`,
`NEXUS_SIGNING_KEY=${{ secrets.NEXUS_DEVELOPMENT_SIGNING_KEY }}` and
`NEXUS_DEVELOPMENT_PUBLISH=${{ vars.NEXUS_DEVELOPMENT_PUBLISH }}`.
Repository/organization Actions policies and metadata-branch protections must
allow those token permissions and normal branch pushes. No PAT is required.

- For later root-set/threshold changes, review public keys and increment
  `rootVersion`. Highwater rejects older roots or different anchors at the same
  version. Ship overlapping old/new roots through the old authorized chain
  before removing old roots.
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
  Both environments must restrict deployment to main; future promotion requires
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
