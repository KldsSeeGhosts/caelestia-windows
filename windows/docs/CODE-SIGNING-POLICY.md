# Code signing policy

Free code signing provided by [SignPath.io](https://about.signpath.io),
certificate by [SignPath Foundation](https://signpath.org).

This policy covers the Windows x64 releases published from
[KldsSeeGhosts/caelestia-windows](https://github.com/KldsSeeGhosts/caelestia-windows).
The project is licensed under [GPL-3.0](../../LICENSE). SignPath Foundation's
conditions are at [signpath.org/terms](https://signpath.org/terms).

**Current state.** No release is signed. There is no stable release, no signing
credential and no signing job in this repository. Development and preview
packages are unsigned. This page records the policy the project intends to apply
once a signing pipeline exists, and the work that pipeline still needs is in
[SIGNING-ROADMAP.md](SIGNING-ROADMAP.md). Do not describe any current download
as signed.

A signature proves which publisher produced a binary and that the signed bytes
are the ones that publisher released. It does not certify that the software is
free of defects, and it does not replace the manifest digests, source provenance
or Windows qualification described in [INSTALL-RELEASE.md](INSTALL-RELEASE.md)
and [RELEASE-CHECKLIST.md](RELEASE-CHECKLIST.md).

## Release channels

| Channel | Reference | Signed | Notes |
| --- | --- | --- | --- |
| Development | `vX.Y.Z-dev.EPOCH.RUN.ATTEMPT` | No | Every green `main` push publishes a pre-release. These are continuous development builds. |
| Preview | `vX.Y.Z-preview.N`, `vX.Y.Z-rc.N` | No | Pre-1.0 aliases of tested development artifacts. The existing `v0.1.0-preview.2` release is one. |
| Stable | `vMAJOR.MINOR.PATCH`, `MAJOR >= 1` | Intended | The owner's decision is that stable releases will be signed through SignPath Foundation once the pipeline exists. No stable release exists today. |

The table describes this project's own publisher signature. Deployed Qt DLLs
carry Qt's signature in every channel; that is a vendor signature, not one from
this project.

The channel classification is implemented in
[Caelestia-Signing.ps1](../scripts/Caelestia-Signing.ps1)
(`Get-CaelestiaReleaseChannel`). It is used by the standalone verifier and its
fixtures only; no CI job runs it. A tag that is not an unqualified core of 1.0.0
or newer is never treated as stable. Promotion to the Nexus `stable` channel
already requires the alias to equal the core and refuses a 0.x core, so the tag
grammar and the channel metadata agree.

Development and preview releases stay unsigned on purpose. They change with
every push, they are not manual release decisions, and signing each one would
exhaust the approval process that makes a signature meaningful. If a preview is
blocked by Smart App Control, antivirus or an organizational policy, do not
disable that protection. Wait for a stable release or build from source.

## What a stable release would sign

Only files this repository builds. The reviewed set is
[windows/release/signing-inventory.json](../release/signing-inventory.json):
38 PE files and 18 PowerShell files. The verifier fails if the bundle is missing
one of them, or contains a first-party file that is not in the inventory.

| Signed artifact | Built from | Kind |
| --- | --- | --- |
| `payload/caelestia-capture.exe` | [windows/capture](../capture) (maintained first-party capture source, MIT) | PE, Authenticode |
| `payload/DesktopTakeover.dll` | [windows/scripts/DesktopTakeover.cs](../scripts/DesktopTakeover.cs), compiled during native build | PE, Authenticode |
| `payload/caelestia-*.dll` | Caelestia helper DLLs built from this repository | PE, Authenticode |
| `payload/qml/Caelestia/**/caelestia-*.dll` | Caelestia QML plugin modules built from this repository | PE, Authenticode |
| `Install-CaelestiaRelease.ps1` | [windows/scripts/Install-CaelestiaRelease.ps1](../scripts/Install-CaelestiaRelease.ps1) | PowerShell, Authenticode |
| 17 `payload/*.ps1` scripts | The maintenance, launcher, update and uninstall scripts | PowerShell, Authenticode |

Every signature would be SHA-256 Authenticode with an RFC 3161 timestamp. A
stable release would fail verification if any listed file is unsigned, has an
invalid signature, has no timestamp, or is signed by a publisher other than the
exact certificate subject recorded for SignPath Foundation.

## What is not signed, and why

| Artifact | Why it is not signed with the project certificate |
| --- | --- |
| `payload/qs.exe` | It is a build of the modified Quickshell fork. SignPath Foundation's rules for a modified upstream project require the upstream project to publish signed builds; Quickshell ships no signed Windows binaries. The file's version resource also identifies Quickshell, not this project. It stays an unsigned upstream binary inside a signed package, which the same rules permit. |
| `payload/m3shapes.dll`, `payload/qml/M3Shapes/**` | Third-party [soramanew/m3shapes](https://github.com/soramanew/m3shapes), pinned as a submodule and licensed Apache-2.0. Only its maintainers may sign it. |
| `payload/Qt6*.dll`, `payload/plugins/**`, `payload/qml/**` outside `Caelestia` and `M3Shapes` | Qt's own binaries keep Qt's signature. They are verified, never re-signed. |
| `Install.cmd` | A batch file. Authenticode has no signature format for it. |
| The release ZIP | The ZIP is not signed. Its SHA-256 and the manifest SHA-256 are published beside it. |
| `release.json`, `INSTALL-RELEASE.md`, licences, fonts, SBOMs, QML files | Data, not executable code. |

[windows/signpath/caelestia-windows-stable.xml](../signpath/caelestia-windows-stable.xml)
is a draft artifact configuration for the intended signed set. It is not
registered with SignPath and no signing service consumes it. A future signing
pipeline must verify the same ownership rules independently.

## Build and signing status

There is no signing pipeline. In particular:

- `.github/workflows/windows-build.yml` does not sign anything and does not
  verify publisher signatures. The development publisher creates a tag on every
  green `main` push, and those tags must never start a signing run.
- There is no stable assembly and publication contract. `New-CaelestiaRelease.ps1`
  currently rejects stable release IDs, and Nexus promotion keeps the development
  bundle bytes. A stable signed bundle cannot be produced by relabelling a
  development artifact; it must be assembled and signed at the stable tag with
  its own provenance.
- [Test-AuthenticodeSignatures.ps1](../scripts/Test-AuthenticodeSignatures.ps1)
  is a standalone verifier. It checks the reviewed inventories, the bundle
  manifest and the signatures of an extracted bundle. No CI job calls it.
- No SignPath API token, certificate, private key or signing credential exists
  in this repository or in its Actions configuration.

The requirements for a real pipeline are listed in
[SIGNING-ROADMAP.md](SIGNING-ROADMAP.md). Signing activates only after that work
is done, the owner's SignPath application is accepted and the service is
configured.

## Team roles

SignPath Foundation requires the project team to name the people behind three
roles. The project has a single maintainer today; the owner fills in the real
handles before applying and keeps this list current. Replace each placeholder
with a GitHub handle or team link.

| Role | Who | Responsibility |
| --- | --- | --- |
| Authors | `<author-github-handle>`, repository [CODEOWNERS](../../.github/CODEOWNERS) | May change source and build scripts without an additional review. |
| Reviewers | `<reviewer-github-handle>` | Reviews every proposed change from someone who is not a committer. |
| Approvers | `<approver-github-handle>` | Decides whether a specific release may be signed. The owner is the single approver. |

Every signing request would need a manual approval. The approver would confirm
that the request belongs to the exact tested stable release, that the workflow
run is the trusted producer run, and that the signing request is not a re-run of
a superseded build. A rejected or denied request is not retried with relaxed
settings.

All team members use multi-factor authentication for both GitHub and SignPath.
That is a condition of the SignPath Foundation subscription, not a local
convenience.

## Verifying a release

Current development and preview releases are unsigned. For them, verify the ZIP
and manifest SHA-256 values as described in [INSTALL-RELEASE.md](INSTALL-RELEASE.md).
A publisher check is not available and the installer does not pretend to provide
one.

Once a signed stable release exists, these steps apply:

1. Download the ZIP and its `.zip.sha256` from the project's
   [releases page](https://github.com/KldsSeeGhosts/caelestia-windows/releases),
   never from an unrelated mirror.
2. Check the ZIP digest: `Get-FileHash -Algorithm SHA256 <zip>`.
3. Extract the whole ZIP. In Windows PowerShell, check a signed file:

   ```powershell
   Get-AuthenticodeSignature .\payload\caelestia-capture.exe | Format-List Status, SignerCertificate, TimeStamperCertificate
   ```

   `Status` must be `Valid`, the signer must be the recorded SignPath Foundation
   subject, and a timestamp must be present.
4. Verify the whole bundle with the project's own check from a reviewed checkout:

   ```powershell
   powershell.exe -NoProfile -File windows\scripts\Test-AuthenticodeSignatures.ps1 `
       -BundleRoot <extracted-bundle> -Channel stable `
       -ExpectedSignerSubject '<exact certificate subject>'
   ```

   It first checks the reviewed file set against
   `windows/release/signing-inventory.json` and
   `windows/release/vendor-privacy-review.json`, then confirms that Qt DLLs kept
   their Qt signature and that no third-party file was re-signed with the
   project certificate.
5. Run the installer with `-ExpectedManifestSha256` from trusted release
   metadata, as described in [INSTALL-RELEASE.md](INSTALL-RELEASE.md).

## SmartScreen, Smart App Control and antivirus

Windows treats signed and unsigned software differently, and a signature only
changes part of that behavior.

- Publisher identity and SmartScreen reputation are separate. A valid signature
  identifies who signed the bytes. SmartScreen's "unknown publisher" warning and
  its app reputation come from Microsoft's own data and can still warn for a
  newly signed release while reputation accumulates. A signature does not grant
  reputation.
- Smart App Control only allows software it considers safe. A valid signature
  helps, but Smart App Control also weighs its own reputation data. Because
  `qs.exe` is not signed by this project, Smart App Control can still block a
  stable release on a machine where it is enforced. Do not disable Smart App
  Control, antivirus or an organizational policy to work around that.
- Antivirus and enterprise policies are independent of Authenticode. A signature
  does not whitelist a binary.
- The per-user installer runs its own PowerShell process with
  `-ExecutionPolicy Bypass`. That is a process-scoped execution-policy choice,
  not a signature, and it changes no persistent policy.

## Privacy

This section is the privacy statement referenced by the code signing policy. It
replaces the blanket sentence that nothing leaves the machine: some features send
specific data to specific services, described below. The shell sends no
telemetry. Local profile settings, window titles, notification contents and
clipboard data are not included in these requests.

| Service | When it is contacted | Data sent | Privacy policy |
| --- | --- | --- | --- |
| ipapi.co (Kloudend, Inc.) | A weather surface loads (the dashboard and lock screen show weather) and `services.weatherLocation` is blank. The shell asks for an approximate location at most once per refresh window; it backs off on rate limits. | The source IP address and ordinary HTTPS request headers. The response supplies approximate latitude, longitude and city. No account or profile data is sent. | [ipapi.co/privacy](https://ipapi.co/privacy/) |
| OpenStreetMap Nominatim | After the shell has coordinates, to turn them into a place name. | Coordinates, preferred language (`accept-language`) and a `User-Agent` with the shell version. The server also sees the source IP address. | [OpenStreetMap Foundation privacy policy](https://osmfoundation.org/wiki/Privacy_Policy) |
| Open-Meteo | When a city name is configured (geocoding search), and whenever the weather widget loads a forecast. | A city name or coordinates, the requested weather fields, language and time zone. Open-Meteo's logs may contain coordinates and IP addresses. | [Open-Meteo terms and privacy](https://open-meteo.com/en/terms#privacy) |
| GitHub | Settings > Updates checks for updates when the user asks it to. The shell fetches the authenticated `nexus-channels` metadata from `raw.githubusercontent.com` and, if the user installs, the release ZIP from `github.com`. | Source IP address, requested URL, `If-None-Match` and ordinary HTTPS request headers. No GitHub account, token or profile data is sent. | [GitHub privacy statement](https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement) |
| YouTube (Google) | A media player is playing a track whose URL is a YouTube watch page, and the media artwork is visible. The shell loads the video thumbnail as cover art. | The video ID in the thumbnail URL, source IP address and ordinary image-request headers. | [Google privacy policy](https://policies.google.com/privacy) |
| PyPI | Only when the user opts into preparing the colour-scheme runtime. `pip` downloads locked packages (`materialyoucolor`, `pillow`) from the package index. | Package names and versions, a Python/pip user agent and the source IP address. No profile data is sent. | [PyPI privacy help](https://pypi.org/help/#privacy) |
| GitHub (Git) | The same opt-in colour-scheme preparation installs the Caelestia CLI from a pinned commit over `git+https`. | Source IP address and the repository/commit requested. No GitHub account or token is sent. | [GitHub privacy statement](https://docs.github.com/en/site-policy/privacy-policies/github-general-privacy-statement) |
| Microsoft | Never automatically. If the Visual C++ runtime is missing, the installer prints Microsoft's official download link and leaves the decision to the user. | If the user follows the link, Microsoft sees the request under its own terms. | [Microsoft privacy statement](https://privacy.microsoft.com/privacystatement) |
| SignPath.io | Only a future release-signing pipeline, which does not exist. The installed shell never contacts SignPath. | The release artifact and its workflow, repository, commit and run metadata. No end-user profile data. | [SignPath privacy policy](https://signpath.io/privacy-policy) |

Ways to avoid or limit the automatic requests:

- Set `services.weatherLocation` to a fixed city or coordinates in
  `shell.json`. No ipapi.co lookup is made then, and Nominatim is not needed.
  The weather surfaces still request the forecast from Open-Meteo. The shell
  does not currently expose a separate switch that disables weather network
  access altogether.
- Update checks are user-initiated from Settings > Updates. They do not run on
  startup.
- Colour-scheme runtime preparation is opt-in. Basic use does not download
  packages.
- Media artwork is only loaded while a player is active and the artwork is
  visible. The URL can come from the player or, for YouTube URLs, from the
  thumbnail fallback.

Signing does not add a network feature to the installed shell. SignPath would see
the release workflow and artifact, not the user's machine.

## Incident handling, rotation and revocation

The code signing certificate would be issued to SignPath Foundation, which is
the publisher named by the signature. The project cannot reissue it directly.
No certificate or token exists today; these are the procedures the pipeline must
follow once one does.

- **Compromised API token.** Revoke it in SignPath, issue a new one, and replace
  it in the protected CI environment. Pause stable publication until the
  replaced token is the only valid submitter. No token is ever committed.
- **Compromised or withdrawn certificate.** Suspend stable publication, report to
  SignPath at support@signpath.io, publish a security advisory through
  [SECURITY.md](../../SECURITY.md), and re-sign the affected release after a new
  certificate is available. Users must treat binaries signed by a revoked
  certificate as untrusted.
- **Compromised signing environment or workflow.** Disable the signing job,
  revoke the token, audit the workflow history, and rebuild from reviewed
  commits. Never re-sign an unchanged artifact to hide a workflow change.
- **Wrong or partial signature.** The release fails verification and is not
  published. The pipeline must never publish an unsigned or partially signed
  artifact as stable.
- **Rotation.** When SignPath replaces its certificate, record the new subject
  and update this page. An RFC 3161 timestamp proves that an older signature was
  created while its certificate was valid, so old releases remain verifiable
  after the certificate expires, unless the certificate was revoked or the chain
  is no longer trusted.

## Current state

- No release is signed. There are no stable releases.
- `v0.1.0-preview.2` and the `v0.2.0-dev.*` pre-releases are the only published
  tags.
- The standalone verifier, its reviewed inventories and the draft artifact
  configuration are checked in but not wired into CI.
- First-party PE files do not yet carry a `VERSIONINFO` resource with product
  name `Caelestia Windows` and the release core version. SignPath's metadata
  restrictions require it, so a signing request would fail closed until the
  build emits it.
- The candidate payload verifier and source-asset coverage still compare
  unsigned hashes with deployed bytes. Signing would change those bytes, so the
  metadata refresh described in [SIGNING-ROADMAP.md](SIGNING-ROADMAP.md) must
  land before a signed stable candidate can pass.
