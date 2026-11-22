# Caelestia for Windows releases

[Download Caelestia](https://kldsseeghosts.github.io/caelestia-windows/#install)
or check in **Nexus > Settings > Updates**. Both use the same published
Windows x64 ZIP. Every GitHub release includes the application and its
corresponding project and supplier sources. The version users see is plain
SemVer; `-development` is part of the immutable GitHub tag only.

The website uses the release pointer to select an exact GitHub asset and
display its SHA-256. The website does not verify signatures. Nexus authenticates
the pointer and checks the ZIP and manifest before installation. For a manual
download with the same authentication, use the
[bootstrap helper](../../UPDATES.md#one-time-bootstrap) from a reviewed checkout.
The Windows package itself is unsigned.

## Historical preview

The table below records the original manual preview. It is kept for people
who need to reproduce or verify that older download. It is not the current
download recommendation.

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

[public-release.json](public-release.json) and
[gh-pages-release.patch](gh-pages-release.patch) are historical records.
`python -B windows/tests/TestPublicReleaseMetadata.py --online` still checks
the archived preview. Do not apply the historical patch to the current site.

## Updating GitHub Pages

In a separate checkout of `gh-pages`, apply
[gh-pages-single-release.patch](gh-pages-single-release.patch) after
`git apply --check` succeeds. Copy [release-download.js](release-download.js)
beside `index.html`. The page reads the same pointer that Nexus uses, so
subsequent releases don't require a Pages commit. If the pointer is unavailable,
the button links to the releases list without choosing a version.

Run `node --test windows/tests/PublicDownload.test.js` from the main checkout.
Publish the two Pages files in one commit. Verify that the live page shows the
pointer's version, ZIP URL and hash. Do not change the Pages source, the metrics
publisher or the release signing settings for this update.
