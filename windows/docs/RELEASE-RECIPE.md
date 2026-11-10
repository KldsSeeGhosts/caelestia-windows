# Source and notice preparation

The [verified public release table](../release/PUBLIC-RELEASE.md) identifies
the recommended application and complete source assets. This recipe does not
change that recommendation. Only update the reviewed metadata after release
qualification and verification against the published manifest and sidecars.

This recipe prepares source assets and supplemental notices. It does not build,
install, sign or publish the application. Package lifecycle, installed-library
replacement, privacy review, signing and Windows qualification are separate
gates. Existing published source assets remain useful; this recipe preserves
their supplier archives, provenance and build/replacement guidance.

## Public prerequisites and candidate

Use native 64-bit Windows PowerShell 5.1, Git for Windows, Windows `tar.exe` and
`curl.exe`. Application builds additionally need the public prerequisites in
[NATIVE-BUILD.md](../NATIVE-BUILD.md) and `windows/toolchain.json`. No account,
provider configuration, unpublished notice folder or authenticated download is
required. Download origins are restricted to the recorded public HTTPS hosts.
Downloads have connection/total timeouts, no automatic authentication retry,
and mandatory SHA256 verification, including cache hits.

Start from the exact reviewed public candidate with initialized dependencies:

```powershell
git clone --recurse-submodules https://github.com/KldsSeeGhosts/caelestia-windows.git C:\src\caelestia
git -C C:\src\caelestia checkout <full-reviewed-shell-commit>
git -C C:\src\caelestia submodule update --init --recursive
# Self-contained bundles require complete history. The submodule configuration
# may select a shallow checkout; complete only those public dependency clones.
foreach ($dependency in @('windows/deps/quickshell', 'windows/deps/m3shapes')) {
    $dependencyRoot = Join-Path C:\src\caelestia $dependency
    if ((git -C $dependencyRoot rev-parse --is-shallow-repository).Trim() -eq 'true') {
        git -C $dependencyRoot fetch --unshallow origin
        if ($LASTEXITCODE -ne 0) { throw 'Public dependency history fetch failed.' }
    }
}
powershell -NoProfile -File C:\src\caelestia\windows\scripts\Prepare-CaelestiaSourceAssets.ps1 `
    -SourceRoot C:\src\caelestia -SourceRevision <full-reviewed-shell-commit> `
    -OutputDirectory C:\release\source-run-1 -CacheDirectory C:\release\source-cache
```

Output and cache must be outside the checkout, nonoverlapping, and free of
reparse points. Output must not exist. A failure is fatal and retained for
inspection; it is not a distributable result. The recipe reads committed Git
objects, never uncommitted source edits. Source bundles contain only the selected
public candidate and its reachable history, with one `source` branch. Do not run
this against a private-history repository. Unpublished local commits can be
prepared for review, but that does not prove their anonymous availability.

The default transport uses the hash-identified public Preview 2 supplier asset
as a cache of unmodified supplier archives and recorded provenance, and its
application asset as data for previously reviewed derived notices. Two matching
Rust distributions are downloaded separately for original copyright inventories.
`-FetchSuppliersFromOrigin` fetches source archives at their original recorded
URLs instead of seeding them from the public ZIP. Cache hits always rehash.
`-Offline` refuses any missing input. No downloaded application/script is run.

The reference is intentionally bounded, not an automatic dependency resolver.
Candidate Qt, Rust, LLVM and CLI11 versions, every capture registry crate and
checksum, and dependency gitlinks must agree with the reviewed records.
Dependency updates require a reviewed rule/data update. Keep supplier origins,
hashes, notices and their applicability review together.

## Outputs and one inventory

`component-inventory.json` is the authoritative mapping for preparation and,
after coverage verification, for release/SBOM consumers. It records candidate
project commits, supplier URLs/hashes/lengths, license expressions as recorded
data, source-to-notice provenance, all notice hashes, payload rules, optional
absent components and capture layout. Asset `SOURCE-MANIFEST.json` files point to
that inventory by hash; they do not declare a second component list.

Outputs include three self-contained Git bundles in `project-source.zip` for the
current integrated capture layout (four for older pinned capture candidates),
41 supplier source archives in `supplier-source.zip`,
`notices/` for `-SupplementalNoticesRoot`, `SHA256SUMS`, and `execution.json`.
Every bundle passes `git bundle verify` in an empty repository, is fetched there,
and is checked for its declared commit. SHA256 binds the bundle bytes.

The supplier record conservatively includes build/proc-macro crates and source
modules that might not be deployed. Inclusion is not a runtime-shipped claim.
Python, the CLI and optional Python packages are not bundled; the Microsoft
runtime is an external prerequisite, not redistributed. A prepared inventory
has `payloadState: not-supplied`, not a package pass.
Shallow histories are not self-contained bundle inputs. Preparation refuses
incomplete ancestry rather than publishing a bundle with missing prerequisites;
the explicit Git history step above happens before the read-only recipe.

Verbatim notices are extracted from exact hash-verified supplier members, never
guessed from filenames. The few already published derived/index notices are
preserved byte-for-byte as data with their original provenance and derivation.
This includes Qt attribution indexes, Rust HTML-to-text inventories and SQLite
license-comment excerpts. The complete original material remains in its
recorded supplier sources/distributions. No copyright is redacted, license
inferred or new legal certification made.

## Assembly integration and final coverage

The existing application assembler remains authoritative for application
assembly and `release.json`. After a tested public-release build, supply this
recipe's `notices/` to its existing parameter:

```powershell
.\windows\scripts\New-CaelestiaRelease.ps1 -BuildRoot $testedBuild `
    -ReleaseId $id -OutputDirectory $newPackageOutput `
    -SupplementalNoticesRoot C:\release\source-run-1\notices `
    -QtPrefix $matchingQt -VCRuntimeRoot $matchingCrt
```

Then bind the actual bundle to the prepared sources:

```powershell
.\windows\scripts\Prepare-CaelestiaSourceAssets.ps1 `
    -AssetsRoot C:\release\source-run-1 -BundleRoot $extractedBundle `
    -ExpectedInventorySha256 $trustedPreparationInventoryDigest `
    -ExpectedManifestSha256 $trustedManifestDigest `
    -CoverageOutputDirectory C:\release\final-source-coverage
```

This invokes the checkout's existing `Install-CaelestiaRelease.ps1 -VerifyOnly`,
checks source/dependency/Qt identities, all required project and supplier
notices, and maps every manifest file. Unknown additions and changed Qt supplier
bytes fail closed. The exact public-reference payload list is an allowlist for
existing supplier deployment, not a wildcard for new DLLs. New production QML
destinations come from the candidate staging map. The final inventory contains
the application manifest digest and per-file source ownership. Publish/use that
verified final inventory as the release/SBOM mapping, retaining the prepared
inventory as preparation provenance. Never call preparation alone final coverage.
Supply the preparation digest from the trusted preparation result. Coverage also
rehashes the prepared bundles, supplier sources and notices before use.

Integration of these calls into the assembler/CI is a separate release-owner
change. Existing `Test-InstallLicenses.ps1` remains the install/update/uninstall
license gate and must run on the candidate. This recipe does not replace it.
New suppliers, per-embedded-library applicability decisions, optional Python
bundling and changed notice derivations require bounded review by the release
owner. The inventory is a shared input for dependency/SBOM work, not another
independently maintained dependency lock.

For a disposable license install/update/uninstall check without desktop
integration, run the existing test in its explicit isolated mode:

```powershell
.\windows\scripts\Test-InstallLicenses.ps1 -BuildRoot $testedBuild `
    -QtPrefix $matchingQt -VCRuntimeRoot $matchingCrt -NoIntegration
```

This keeps the license, capture provenance, rollback-payload and profile
preservation checks. It does not create shortcuts or autostart entries and
does not launch the payload. The default mode still checks integration.

## Capture migration input forms

For older source candidates, `-CaptureLayout Pinned` reads Glazier's gitlink,
lock and license/notices. The current in-tree source lock automatically selects
the integrated layout. It can also be selected explicitly:

```powershell
.\windows\scripts\Prepare-CaelestiaSourceAssets.ps1 `
    -CaptureLayout Integrated -IntegratedCapturePath windows/capture `
    -OutputDirectory C:\release\integrated-source -CacheDirectory C:\release\source-cache
```

The integrated directory must be a committed tree, not a gitlink. Its
`Cargo.lock`, `LICENSE` and `THIRD_PARTY_NOTICES.md` must exist and pass the same
supplier rules. Capture then resides in the shell bundle, with no invented
separate source revision. The first-party executable and origin notice have
explicit payload ownership rules; legacy Glazier license/notice filenames remain
compatibility aliases. Product identity and native capture acceptance still
require their own reviewed integration and qualification.

## Rebuilding and replacing LGPL libraries

Keep `SUPPLIER-BUILD-AND-REPLACEMENT.md` with both source assets. It preserves the
published supplier build guidance verbatim. Restore a project with, for example,
`git clone shell.bundle C:\src\caelestia`, then restore the pinned dependency
bundles at their lockfile paths and initialize submodules. Read the restored
build instructions and license texts before redistribution.

Build Qt modules from the supplied source archives into a separate compatible
x64 prefix, following each module's own configure/build instructions. Build
qtbase, qtshadertools before qtdeclarative, then the additional modules needed by
the application. Use consistent ABI, build type, feature options, DLLs, plugins
and QML metadata. Use the replacement prefix to rebuild the shell/backend/plugins,
or replace the corresponding installed dynamic libraries in a disposable,
stopped installation and test it. Preserve all applicable notices.

Original-bundle verification protects the installation transaction. It is not a
runtime ban on modified installed libraries and must not be repurposed as one.
Keep the original payload for recovery; modified binaries are not represented
by the original package's hash or qualification.

## Reproducibility evidence

Run preparation twice into distinct directories, then compare `SHA256SUMS`,
bundle hashes, inventory and individual supplier/notice hashes. Record the
exact candidate, Git/PowerShell versions, transport/cache state, commands and
differences. Project records include `core.autocrlf`/`core.eol`: Git archive
text conversion and checkout line endings can affect notice/staging hashes.
Use matching source materialization for assembly; a mismatch fails coverage.
The recipe-rule digest uses UTF-8 with LF newlines. ZIP entries use stable
ordering and a fixed timestamp, but Git pack
ordering/compression, tool versions, application compiler output, generated
supervisor metadata, signing and timestamps can still differ. Matching one pair
of archives is measured agreement, not a general bit-reproducibility guarantee.

Focused disposable tests:

```powershell
powershell -NoProfile -File windows/scripts/Test-SourceAssets.ps1
```
