# Qt 6.11.3 qualification

Part of [shell issue 17](https://github.com/KldsSeeGhosts/caelestia-windows/issues/17).

## Reviewed inputs

On 2026-11-10 the official online repository's `Updates.xml` advertised
`6.11.3-0-202610220312` for `win64_msvc2022_64`. All six selected binary
archives downloaded through the pinned aqt installer and passed both its
upstream checksum checks and the committed SHA-256 pins. The corresponding
six official source tarballs also downloaded and matched their published
`.sha256` files. No hash was inferred from a version string.

The binary repository is
`https://download.qt.io/online/qtsdkrepository/windows_x86/desktop/qt6_6113/qt6_6113_msvc2022_64`.
Source origins, lengths and hashes are in `windows/release/source-assets.json`
and its checksum-bound `qt-source-notices.json`.

`Prepare-Toolchain.ps1` installed a separate
`%LOCALAPPDATA%\caelestia-dev-qt6113` root. The existing developer SDK and the
installed shell were not modified. Qt's compiler/linker metadata still matches
the existing MSVC supplier pins.

The local native build used shell base
`035f8ecbcbbbab63680a7b1f780164bf920f0b0e` with the dependency-update diff,
backend `1ea37421c335d41847a0b5f273b2d384212e8847`,
M3Shapes `32ad9ce328bb77ed349b40a3be10ee9ea610b8ab` and Qt 6.11.3.
`Build-Prototype.ps1 -PluginTests -Tests` rebuilt the backend, standalone
backend fixtures, native plugins and bundled capture tool. This dirty-worktree
build is local compatibility evidence, not an exact-commit release receipt.

## Advisory applicability

[CVE-2026-95620](https://www.qt.io/blog/security-advisory-cve-2026-95620)
and [CVE-2026-96432](https://www.qt.io/blog/security-advisory-cve-2026-96432)
describe availability failures in Qt Network's HTTP/2 client through the prior
patch. Both advisories identify Qt 6.11.3 as fixed.

The shipped `Qt6Network.dll` provides `QNetworkAccessManager`. Caelestia's
Requests implementation uses it, including staged weather requests. Optional
quota requests use Qt QML's `XMLHttpRequest`, whose networking also uses Qt
Network. These API paths justify servicing the dependency. They do not prove
HTTP/2 negotiation, vulnerable-branch reachability or an application exploit.
No remote-code-execution claim follows from this qualification.

The original C++ lyrics service is absent from the portable Windows build.
Qt source and notice inclusion is conservative. It does not establish that
optional Qt modules or every embedded third party ships in the product.

## Source, notice and payload review

`windows/toolchain/review_qt_sources.py` reproduces the bounded review data
from the two hash-pinned public reference ZIPs, the six pinned source tarballs,
and the SDK prepared by `Prepare-Toolchain.ps1`. Supply `--reference-directory`
with `supplier.zip`, `application.zip` and those six tarballs, `--qt-prefix`
with the new SDK and `--output` with a disposable comparison file.

The review retains the existing source-member and payload allowlists. It
refreshes 508 Qt notices and two explanatory notices, with hashes for every
source member used. Attribution indexes contain the supplier's current Name,
LicenseId and Copyright fields. SQLite notices retain its verbatim blessing
instead of copying the implementation as a notice. Other supplier notices
remain tied to the existing public reference. Updated Qt source members include
PCRE2, SQLite, FreeType, HarfBuzz, libpng, md4c and libwebp attribution metadata.

The source preparation script verifies the committed review checksum, six
source archive pins, source-member hashes and final notice hashes. It replaces
the old Qt payload hashes with 1,475 reviewed SDK payload hashes. Unknown files
and changed supplier bytes remain fatal. The separate vendor privacy allowlist
also pins the new Qt binary and SBOM bytes. License expressions and conservative
source inclusion do not claim legal certification.

CI toolchain and object cache identities already hash `windows/toolchain.json`.
The dependency change therefore selects new cache identities without changing
the workflow or weakening trusted-main-only cache writes.

## Remaining old-version references

A repository-wide search, including hidden files and excluding `windows/deps`,
found no underscore-form version references. Operational documentation, test
receipts, defaults, toolchain/package pins and privacy-review entries now name
the new patch. The remaining references to the prior patch are intentional:

- `source-assets.json` records the historical public reference version that the
  reviewed Qt replacement must match.
- `SCREEN-HOTPLUG.md` links the historical screen-manager source analysis.
- `CAPTURE-COLOR.md` describes the prior implementation's native texture behavior.
- `decisions/capture-host-lifecycle.md` records an already completed test run.
- `CaptureLogic.test.js` and `CaptureLogic.js` cite the historical `QRectF::toRect`
  rule. The new SDK still has that rule. No UI code changed.

## Acceptance limits

All Qt test processes use `QT_QPA_PLATFORM=offscreen`. Local builds and model
tests do not validate D3D11 rendering, real plugin presentation, capture/device
recovery or representative live weather/quota network requests. Those remain
the owner's trusted Windows checks, together with hosted Windows validation,
staged smoke, exact-package lifecycle gates and source/notice coverage of the
final package. Passing a smoke test alone does not establish compatibility.

The retained-version install/rollback workflow is unchanged. Do not promote
the new dependency pair until the required gates and owner checks pass.
