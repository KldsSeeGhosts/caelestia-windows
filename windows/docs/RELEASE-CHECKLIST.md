# Windows release checklist

The [verified public release table](../release/PUBLIC-RELEASE.md) records the
current recommendation. After qualification, review `public-release.json`
against the published ZIP's manifest and sidecars, update its table and site
patch together, and run the offline validator plus its anonymous `--online`
check. Follow the site handoff's staging and post-publication checks. A failed
check must leave the previous complete Pages deployment available.

Nexus ships configured development root trust. Development publication requires
the ordered owner setup in [UPDATES.md](../../UPDATES.md). Preview/stable
promotion stays inactive. The remaining producer and client acceptance gates in
[NEXUS-IMPLEMENTATION.md](NEXUS-IMPLEMENTATION.md) still apply. The current
client tests do not certify a release or authorize a live bootstrap.

This is a maintainer checklist, not an authorization to change repository
visibility, tag, push, enable workflows or publish. Keep the existing Linux
release workflows disabled. Record failures and untested cases rather than
describing a build or prototype smoke as a validated shell release.

## Source and public availability

Public source starts from reviewed snapshots. Older private repositories,
history, issues and attachments remain private. A branch squash does not remove
GitHub pull-request refs, edited discussion history or attachments.

- [ ] The maintainer approves the exact publication of
  [caelestia-windows](https://github.com/KldsSeeGhosts/caelestia-windows) and
  [caelestia-quickshell-windows](https://github.com/KldsSeeGhosts/caelestia-quickshell-windows)
  and [Glazier](https://github.com/KldsSeeGhosts/glazier).
  Never attach public remotes to old private clones.
- [ ] Review every ref being published for credentials,
  personal data, private tracker references, private links and internal-only
  notes. Check the backend and Glazier too. Only the reviewed clean commits and
  release tags may be sent to the public repositories.
- [ ] Run `powershell -NoProfile -File windows/scripts/Test-PublicDocs.ps1` and
  keep its output with the release record. It fails on private tracker
  references, personal paths, agent assignments and links that do not resolve
  inside the repository or to a public URL.
- [ ] Confirm the release commit, backend gitlink and
  `windows/sources.lock.json` agree. Backend changes must be committed and
  available in the backend fork. Confirm the M3Shapes pin too.
- [ ] Confirm notices, upstream attribution, source URLs and license texts
  reflect the exact payload, including the AI-assistance disclosure. The
  public attribution retains required copyright and third-party notices.
- [ ] Verify the release tree matches the tested source and all dependency
  gitlinks resolve. Do not rewrite published tags or history.
- [ ] Before binary distribution, verify source access without
  repository credentials.

## Build and compatibility

- [ ] Follow [NATIVE-BUILD.md](../NATIVE-BUILD.md) from a clean recursive
  checkout with the documented toolchain.
- [ ] Run `powershell -NoProfile -File windows/scripts/Test-Environment.ps1 -Json`;
  record the prerequisite report separately from build and runtime results.
- [ ] Build with `windows/scripts/Build-Prototype.ps1 -PublicRelease`; record source pins,
  Qt/compiler/SDK versions and build logs.
- [ ] Run the public smoke command in
  [CONTRIBUTING.md](../../CONTRIBUTING.md). Test each supported monitor and
  native DPI, plus mixed-DPI movement, negative origins and transparency.
- [ ] Validate claimed live controls, device loss/recovery, sleep/wake,
  input/focus, notifications, session operations and desktop restoration.
  Keep one active tiler; takeover and autostart must be deliberate test opt-ins.
- [ ] Attach evidence (logs, screenshots, results) to the release pull
  request or as release assets, not the repository. State all unsupported
  and untested behavior.

## Install, update and remove

- [ ] Run `Test-InstallLicenses.ps1 -BuildRoot <build> -QtPrefix <qt>` for the
  temporary-prefix install/update/uninstall and notice-integrity check.
- [ ] On a clean Windows 11 user profile, install without autostart, launch,
  exercise exact-instance State/Restart/Quit, and check runtime deployment
  without developer PATH entries.
- [ ] Update a stopped installation; confirm edited configuration, state,
  profile-local Python environment and user data survive. Test rollback with
  the previous supported payload.
- [ ] Separately test opt-in autostart and desktop takeover, clean exit and
  crash recovery; restore the original taskbar, work areas and tiler.
- [ ] Verify `licenses/LICENSE`, `THIRD-PARTY-NOTICES.md`, source pins,
  backend LICENSE/LICENSE-GPL, m3shapes, all bundled fonts and backend
  third-party notices in the installed `licenses/` tree.
- [ ] Check Qt's supplied license files and SBOMs from the exact Qt prefix
  against all deployed modules and embedded third parties. Supply any missing
  license texts; an SBOM alone is insufficient. Check CRT redistribution terms.
- [ ] With Python available, provision colour generation in the profile-local
  venv and verify Caelestia CLI, materialyoucolor and Pillow license metadata,
  including Pillow's bundled-library notices.
- [ ] Uninstall; verify binaries, `licenses/`, the prefix-specific shortcut
  and autostart entry are removed while user data remains. Separately test
  `-Purge` with a disposable profile. Verify other shell installations survive.

## Code signing

Development (`v*-dev.*`) and preview packages are unsigned by policy; that is
not a defect and must not be described as signed. Do not disable Smart App
Control, antivirus or organizational protections to run them. The owner's
decision is that stable releases will be signed through SignPath Foundation, but
no release is signed today and no signing pipeline exists. The full policy is
[CODE-SIGNING-POLICY.md](CODE-SIGNING-POLICY.md);
[INSTALL-RELEASE.md](INSTALL-RELEASE.md) has the user-facing verification
steps, and [SIGNING-ROADMAP.md](SIGNING-ROADMAP.md) lists the work that must land
before signing can start.

The checks below become release gates only after that roadmap is implemented.
They are not satisfied today:

- [ ] The stable assembly and publication contract exists; the channel is
  enforced before any signing hook, development assets and DSSE records are
  immutable, and signed stable bytes have separate authenticated metadata.
- [ ] The signing job consumes the exact verified producer artifact by run and
  source identity, never a release-supplied ZIP or checksum, and never executes
  downloaded code in the job that holds the signing token.
- [ ] The installer verifier accepts an explicit signing-receipt location
  without widening its root-file allowlist beyond reviewed names.
- [ ] `dependencies.capture.sha256`, the supervisor `assemblySha256`, the
  candidate supervisor comparison and the source-asset hashes describe the
  signed bytes, while `nativeInputs` keeps the unsigned provenance.
- [ ] The first-party PE files carry a `VERSIONINFO` resource with product name
  `Caelestia Windows` and the release core version. The draft artifact
  configuration enforces that metadata, so a request fails closed without it.
- [ ] SignPath onboarding is complete: application accepted, project and signing
  policy with manual owner approval, artifact configuration registered from the
  reviewed draft, and a scoped token held only by the protected signing job.
- [ ] Every signed release's reviewed first-party `.exe`, `.dll` and `.ps1` files
  pass
  `Test-AuthenticodeSignatures.ps1 -Channel stable -ExpectedSignerSubject '<exact subject>'`:
  Valid signature, RFC 3161 timestamp and the recorded publisher subject.
- [ ] Qt DLLs, Qt plugins and Qt QML modules still carry Qt's signature and were
  not re-signed. `m3shapes.dll`, `payload/qml/M3Shapes/**` and `qs.exe` are not
  signed by the project certificate.
- [ ] `release.json` `files[]` sizes and hashes, the ZIP SHA-256 sidecar and the
  manifest SHA-256 sidecar all describe the signed bytes. The ZIP and its
  sidecars are the ones the signing run produced, not an earlier unsigned build.
- [ ] On a machine with Smart App Control **on**, install the signed payload
  and confirm that `Microsoft-Windows-CodeIntegrity/Operational` logs no
  3033 or 3077 events for the install prefix. Record that `qs.exe` is unsigned
  and may still be refused; that is a known limitation, not a signing failure.
- [ ] Signing credentials stayed in SignPath and the protected signing job. No
  token, certificate or private key appears in the repository, logs or
  artifacts.

## Tag and publish

- [ ] The maintainer approves the tested release scope and known limitations.
- [ ] Tag the exact tested port revision and identify the corresponding
  backend revision/tag. Make the complete corresponding sources and any
  license-required build/relink materials available with the release.
- [ ] Assemble archives from that tested payload with notices intact; record
  SHA-256 checksums, supported Windows builds, dependency versions, installation,
  update/rollback, uninstall, recovery and known limitations in release notes.
- [ ] After explicit maintainer approval, publish the tag, source and binary
  artifacts. Download the published payload and recheck checksums, notices
  and clean-profile installation.
