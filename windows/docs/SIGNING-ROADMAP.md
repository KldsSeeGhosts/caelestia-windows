# Signing roadmap

The [verified public release table](../release/PUBLIC-RELEASE.md) records the
recommended release's actual unsigned status. Neither this roadmap nor an
authenticated development-channel pointer gives its application files an
Authenticode publisher signature.

Design note for a signing pipeline that can produce a signed stable release.
Nothing in this document is implemented. The development channel stays unsigned;
only stable releases will be signed, and only after this work lands and the
owner's SignPath application is accepted.

The standalone verifier in
[Test-AuthenticodeSignatures.ps1](../scripts/Test-AuthenticodeSignatures.ps1)
checks an extracted bundle. It is not wired into CI and is not a signing
pipeline.

## 1. Stable assembly and publication contract

A signing hook cannot be bolted onto the development packager. The channel must
be part of assembly:

- `New-CaelestiaRelease.ps1:89` currently rejects stable release IDs. It accepts a
  development identity or `CORE-local`, and the error says it will never accept a
  promotion alias. A stable path needs its own contract, not a relaxation of that
  guard.
- Channel selection must be explicit and enforced before any signing code runs.
  A development tag, a branch ref, a pull request or a re-run of a development
  candidate must never reach a signing hook.
- Development assets and their DSSE records are immutable. A stable release must
  be assembled from the tested source and native inputs at the stable tag, not
  relabelled from a development bundle. Nexus promotion currently keeps the
  development bundle bytes; a stable publication path needs separate,
  authenticated metadata that describes the signed stable bytes.
- The release manifest, ZIP digest and Nexus metadata must describe the signed
  bytes that users download. `nativeInputs` keeps the unsigned build provenance.

## 2. Trust boundary for the signing job

The signing job holds a SignPath token and must not be a general build or test
job.

- It consumes the exact producer artifact from the verified producer run. It
  authenticates that artifact by run identity, repository, commit and workflow
  identity (for example through a GitHub artifact attestation or OIDC-issued
  identity), not by a ZIP or checksum supplied by a release workflow or a human.
- It never executes code from the downloaded artifact. Verification and any
  repackaging happen in a separate least-privilege job; only the signing job
  receives the token.
- Pull requests, fork runs and ordinary build jobs cannot obtain the token. The
  signing environment requires explicit owner approval.
- A missing, mismatched or unverifiable producer artifact fails closed. There is
  no fallback to an arbitrary download URL, a manually uploaded ZIP or a
  hand-written checksum.

## 3. Signing receipt and the installer verifier

The signed bytes need a bridge between the unsigned build provenance and the
deployed files.

- `Install-CaelestiaRelease.ps1:165` allows only `release.json`, `Install.cmd`,
  `Install-CaelestiaRelease.ps1` and `INSTALL-RELEASE.md` as bundle-root files.
  A signing receipt must be either embedded in one of those files or added to
  that allowlist by a reviewed change, and it must be named explicitly. Do not
  drop an unlisted `signing-receipt.json` into the root and expect the installer
  to accept it.
- The receipt should record, for every signed file, the unsigned SHA-256, the
  signed SHA-256 and the signing identity. `nativeInputs` stays unsigned.
- The installer must verify the receipt location and shape before using it. A
  signed package without a valid receipt fails verification.

## 4. Refresh deployed-byte metadata after signing

Signing changes the deployed bytes. Every equality check that compares unsigned
build output with the payload must be updated together, not weakened:

- `release.json` `dependencies.capture.sha256` (the capture host's recorded
  build hash).
- The supervisor's `DesktopTakeover.build.json` `assemblySha256`.
- The supervisor comparison in
  `windows/ci/Test-NexusCandidatePayload.ps1:80`.
- The current source-script hashes compared in
  `windows/scripts/Caelestia-SourceAssets.ps1:377`.

The rule is: keep the unsigned hashes in `nativeInputs`, add the signed digest
where the deployed bytes are checked, and prove that only the reviewed signed
set changed. Do not delete these checks or make them non-strict.

## 5. PE metadata for SignPath

SignPath Foundation requires product name and product version metadata
restrictions on every signed PE file. The build must emit a `VERSIONINFO`
resource with:

- product name `Caelestia Windows`;
- product version set to the same reviewed core version in every first-party PE.

The resource is missing today in the capture host, the managed supervisor and
the Caelestia QML modules. Add it to each build:
[windows/capture](../capture) (Rust resource), the
`DesktopTakeover.cs` compile, and the CMake module targets. Keep the draft
[artifact configuration](../signpath/caelestia-windows-stable.xml) restrictions;
do not remove them to make a request pass.

## 6. Qt publisher certificate renewal

The verifier accepts only the exact literal subject measured on the 90 reviewed
Qt DLLs. It does not rebuild the identity from parsed CN and O fields, because
.NET renders quoted and escaped values as different strings and a parsed match
would accept a certificate that merely reuses the trusted names. A renewed Qt
certificate changes the subject, so every Qt file fails with
`unexpected-signer` and the release is not verified.

When Qt renews its certificate, measure the new subject on every reviewed Qt DLL
with `Get-AuthenticodeSignature`, confirm the deployed set still comes from The
Qt Company, and update the literal allow-list in
[Caelestia-Signing.ps1](../scripts/Caelestia-Signing.ps1) in a reviewed change.
Do not restore a parsed CN/O fallback to make the old check pass.

## 7. Activation conditions

Signing may start only when all of these are true:

- This roadmap's stable assembly contract, trust boundary, receipt and metadata
  refresh are implemented and reviewed.
- Every signed PE has the required `VERSIONINFO`.
- The owner's SignPath Foundation application is accepted, the project and
  signing policy exist, and manual approval is enforced.
- The artifact configuration is registered from the reviewed draft, and the
  registered copy matches the repository copy.
- The installer displays the privacy policy and lets the user disable the
  automatic data transfers listed in it at installation time, and the installed
  shell honours that choice. A runtime switch alone does not satisfy this.
- A signing-aware release has been verified end to end on a disposable machine,
  including a failed-signing case that publishes nothing.

SignPath's terms also require the privacy policy to be shown during installation
and a way for users to disable the data transfers that are not required by the
application's specification. That control must exist when the user installs, not
only later through a runtime switch such as Nexus > Services. The installer must
present the policy and persist an explicit opt-out for the automatic transfers
in [CODE-SIGNING-POLICY.md](CODE-SIGNING-POLICY.md#privacy) (the weather
lookups, and any future automatic request), and the installed shell must honour
it. The current installer shows neither, and the shell's only weather control is
`services.weatherLocation`. The opt-in CPA and colour-scheme requests are already
off until the user supplies a configuration or chooses the action, but they must
be named in the same installation-time choice. Resolve all of this before
claiming signing readiness.
