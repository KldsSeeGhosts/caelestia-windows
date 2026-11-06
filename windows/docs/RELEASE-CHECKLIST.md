# Windows release checklist

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

Unsigned previews have explicit policy limitations. Do not disable Smart App
Control, antivirus or organizational protections to run them. The following
checks apply before claiming a signed release:

- [ ] Once both repositories are public, apply to SignPath Foundation's free
  open-source code signing. Paid alternatives (Azure Artifact Signing, an OV
  certificate) need a separate maintainer decision.
- [ ] Add a Windows CI job that builds from the tagged sources and signs every
  shipped `.exe` and `.dll` (`qs.exe`, Caelestia plugins,
  `caelestia-settings.dll`) with an RFC 3161 timestamp. Keep signing
  credentials in the signing service, never in the repository.
- [ ] Before packaging, fail the release if any shipped native binary is
  unsigned or has an invalid Authenticode signature
  (`Get-AuthenticodeSignature`).
- [ ] On a machine with Smart App Control **on**, install the signed payload
  and confirm that `Microsoft-Windows-CodeIntegrity/Operational` logs no
  3033 or 3077 events for the install prefix.

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
