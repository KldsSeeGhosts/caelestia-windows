# Recommended public release

[public-release.json](public-release.json) is the reviewed recommendation, not
the newest development build and not an automatic update feed. The table below
must match it exactly. The offline validator checks this table, the guide
references and the unapplied site patch.

<!-- public-release:start -->
Recommended public release: [0.1.0-preview.2](https://github.com/KldsSeeGhosts/caelestia-windows/releases/tag/v0.1.0-preview.2).
Channel: preview. Signature status: unsigned.

Windows 11 x64 preview. Direct3D 11 GPU required. Not certified for all hardware, accessibility, visual appearance, long-running stability or performance targets.
[Known limitations](https://github.com/KldsSeeGhosts/caelestia-windows/blob/v0.1.0-preview.2/windows/docs/KNOWN-LIMITATIONS.md).

Runtime: [Microsoft Visual C++ x64 Redistributable](https://aka.ms/vc14/vc_redist.x64.exe), 14.44.35211.0 or newer. Install separately if needed.

| Asset | Architecture | SHA256 |
| --- | --- | --- |
| [caelestia-windows-0.1.0-preview.2-windows-x64.zip](https://github.com/KldsSeeGhosts/caelestia-windows/releases/download/v0.1.0-preview.2/caelestia-windows-0.1.0-preview.2-windows-x64.zip) | x64 | `b74649cbebd7d3e4d188f9882db8921cda9dd792344a80698969b16d53f91715` |
| [caelestia-windows-0.1.0-preview.2-project-source.zip](https://github.com/KldsSeeGhosts/caelestia-windows/releases/download/v0.1.0-preview.2/caelestia-windows-0.1.0-preview.2-project-source.zip) | source | `6461ea8974f503787a6fcf4701bf06473ed6f81eab04f7a39e6b158b2bea59eb` |
| [caelestia-windows-0.1.0-preview.2-supplier-source.zip](https://github.com/KldsSeeGhosts/caelestia-windows/releases/download/v0.1.0-preview.2/caelestia-windows-0.1.0-preview.2-supplier-source.zip) | source | `9214f9c74be0f0283e3d6d5e9554ab523b81114c526a71e52cacbeb2b00d7f78` |
| [caelestia-windows-0.1.0-preview.2.manifest.sha256](https://github.com/KldsSeeGhosts/caelestia-windows/releases/download/v0.1.0-preview.2/caelestia-windows-0.1.0-preview.2.manifest.sha256) | metadata | `82ddbce81f34b65eb4a213af4364094c136f486972ea3648b67e11857efd9f78` |
| [SHA256SUMS.txt](https://github.com/KldsSeeGhosts/caelestia-windows/releases/download/v0.1.0-preview.2/SHA256SUMS.txt) | metadata | `89c792d7865159149b955c636d50e8bf3cc7a1cc5741a23bb1e33d48b7d41ed2` |

Qualified `release.json` SHA256: `51fd3508d9d38ce9b7e367a7ad1567f6abec76418e68e0dc39c5c6a6a3635b1d`.
Qualified source revision: `699746045da7426c9df3e7baa85dc2d8d90b4f19`.
Checksums detect changes, not publisher identity. No release is signed today.
Manual installation only. Preview 2 has no automatic updater. Preview/stable authenticated promotion is inactive; development publication is separate.
<!-- public-release:end -->

## Maintaining the recommendation

1. Select an already qualified public release, not GitHub's generic latest
   release. Read its notes and retained qualification evidence. Use
   `gh release list` and `gh release view <exact-tag> --json tagName,url,body,assets`.
2. Review the metadata against the release's ZIP, `SHA256SUMS.txt`, manifest
   sidecar and the ZIP's `release.json`. The current public preview predates
   Nexus producer receipts. Its qualified manifest is the receipt available in
   the published application bundle. Do not claim that it has a newer Nexus
   producer receipt or that checksum equality authenticates the publisher.
3. Update the JSON, this table and the site patch together in a small PR.
   Run `python -B windows/tests/TestPublicReleaseMetadata.py`, then its
   `--online` mode. Online mode uses no authentication. It checks GitHub asset
   digests, anonymous availability of every asset, checksum sidecars and the
   downloaded application ZIP's manifest identity, runtime and signing status.
   Source ZIPs get anonymous HEAD and API/sidecar digest checks, not full
   downloads. No payload is extracted or executed.
4. Follow the separate site handoff below. Publishing a recommendation does not
   activate Nexus preview/stable promotion or provide Authenticode signatures.

## Site handoff

The current `gh-pages` page links to the releases index, calls it the latest
release, and omits the version, assets, hashes, runtime prerequisite, signature
status and limitations. It separately says Windows 11 64-bit, optional Python
for wallpaper colours and Windows 11 24H2 for workspace switching.

[gh-pages-release.patch](gh-pages-release.patch) is an explicit diff for
`index.html`. It adds a static metadata-derived download block to both existing
download actions and puts prerequisite installation before running the
installer. No redesign, client-side fetch or automatic updater is required.
The validator checks every byte of this patch against the metadata.

The orchestrator must apply it in a separate `gh-pages` checkout, copy
`public-release.json` beside `index.html`, and run the offline check from the
main checkout with `--site-root <staging-directory>`. First run
`git apply --check <absolute-path-to-patch>`, then `git apply` only if it passes.
If the page has changed, review and regenerate the diff. Never force it.

Before handoff, `--site-ref origin/gh-pages` tests the diff against the already
fetched page in a disposable scratch directory. It does not check out, commit,
push or deploy that branch.

Run `--online --site-root <staging-directory>` before publication. Commit the
HTML and JSON together and deploy that complete artifact atomically. Stop on
any failed check and retain the previous successful deployment. Do not publish
the JSON and HTML separately, fetch mutable release data at page load, or
replace the previous deployment with a partially built artifact.

After publication, run:

```powershell
python -B windows/tests/TestPublicReleaseMetadata.py --online --site-url https://kldsseeghosts.github.io/caelestia-windows/
```

This verifies the served HTML block and metadata copy, live release links and
anonymous asset availability. Wire this command into the site deployment's
post-publication check when applying the handoff. It intentionally does not run
in offline Windows CI. On failure, retain or redeploy the previous complete
artifact and investigate. This PR does not change Pages deployment or releases.
