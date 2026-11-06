# Install a Windows release

This is the prebuilt Windows 11 x64 product, not a source archive. The bundle
includes the native shell, Qt DLLs/plugins/QML, M3Shapes, Glazier, fonts,
production shell/services, supervisor and maintenance/recovery scripts, and
third-party notices. Basic use needs no Qt SDK, compiler, Git or Python.
Read the [preview limitations](https://github.com/KldsSeeGhosts/caelestia-windows/blob/main/windows/docs/KNOWN-LIMITATIONS.md)
before installing.

## Trust and unsigned previews

Preview packages are currently unsigned. There is no invented certificate or
publisher signature. SHA256 checks detect damage or changes against a trusted
digest; a manifest stored beside its files does not authenticate its publisher.
Obtain the ZIP and its published SHA256 from the project's actual GitHub release,
not an unrelated mirror. Check the ZIP with `Get-FileHash -Algorithm SHA256`
before executing anything from it. If supplied, keep the separately published
manifest digest for `-ExpectedManifestSha256`.

Windows policy, Smart App Control, antivirus or organizational policy may block
unsigned scripts or executables. Do not disable those protections. A blocked
preview is not supported on that machine until an approved, externally signed
release is available. Packaging does not sign anything or alter machine policy.
Like the existing product launchers, `Install.cmd` uses `-ExecutionPolicy Bypass`
for its own PowerShell process only, to run the unsigned preview bootstrap.
This is not a signature or a trust check. It changes no persistent policy and
does not disable Smart App Control, antivirus or enforced organizational policy.

## Install

Extract the **whole** verified ZIP into a local directory. Do not run from the
ZIP viewer, a network share, a symlink or a junction. Keep `release.json`,
`Install.cmd`, `Install-CaelestiaRelease.ps1`, this guide and `payload` together.
Do not edit or add files inside this directory.

Run `Install.cmd`, or from 64-bit Windows PowerShell in the extracted directory:

```powershell
.\Install-CaelestiaRelease.ps1 -ExpectedManifestSha256 '<published 64-character manifest digest>'
```

The optional digest must come from trusted release metadata, not be calculated
from a possibly modified local manifest. Without it, validation still checks
every listed file, rejects extra/missing files, unsafe paths and reparse points,
but is only a self-consistency check. The bootstrap itself must be trusted by
checking the ZIP before running it.

Installation is per-user and does not need elevation. It does not start the
shell, register autostart, hide the taskbar or enable tiling. A Start-menu
shortcut is created unless `-NoIntegration` is supplied. Defaults:

- Product: `%LOCALAPPDATA%\Programs\caelestia-windows`
- Profile: `%LOCALAPPDATA%\caelestia-windows`

Use `-Prefix` and `-ProfileRoot` for separate local installations. Paths may contain
spaces or non-ASCII characters. Bundle, prefix and profile must not contain each
other. A populated foreign profile or unowned prefix is refused, not adopted.

Start without provisioning any optional Python tools:

```powershell
$prefix = Join-Path $env:LOCALAPPDATA 'Programs\caelestia-windows'
& "$prefix\Start-Caelestia.ps1" -PreparedSchemeRuntime
& "$prefix\Start-Caelestia.ps1" -Command State
```

The prepared-only start uses an already verified optional colour runtime, if
present, otherwise the fixed palette. Normal existing launchers and shortcuts
retain their optional scheme preparation behavior. Initial Python discovery
refuses WindowsApps/reparse aliases, install managers and a launcher configured
to auto-install, without executing them. To avoid all Python discovery or
downloads, use the prepared-only command above.

Optional dynamic wallpaper colours require a supported, already installed
classic CPython launcher, Git and network access for the pinned CLI and hashed wheels.
They are not bundled prerequisites. `-PrepareSchemeRuntime` explicitly attempts
that existing optional provisioner before activation. Failure keeps the fixed
palette; it does not fail the product install. Do not use this opt-in with a
Store/install-manager alias in place of a working Python installation.
Other optional integrations retain their own availability requirements.

## Update and rollback

Download and verify the new release, extract into a **different** directory,
then run its installer against the same stable prefix. The installed profile
is discovered automatically when `-ProfileRoot` is omitted. Existing config,
profile data, migrations and cache ownership are preserved.

```powershell
.\Install-CaelestiaRelease.ps1 -Prefix $prefix
# Only when intentionally replacing a running shell:
.\Install-CaelestiaRelease.ps1 -Prefix $prefix -Restart
```

The installer prepares before stopping this installation. With `-Restart` it
uses the existing per-user scheduled-task/supervisor startup and real IPC
readiness contract. A failed live activation selects and restarts the retained
previous version. Without `-Restart`, quit first; activation does not claim
readiness for a product it has not launched. Never invoke a leftover
`$prefix\qs.exe`: the stable scripts resolve the selected/running version.

Developer-installed versions can be updated this way. The existing stable
maintenance scripts remain authoritative:

```powershell
& "$prefix\Manage-Caelestia.ps1" -Prefix $prefix -Command Status
& "$prefix\Manage-Caelestia.ps1" -Prefix $prefix -Command Rollback -Wait
& "$prefix\Start-Caelestia.ps1" -Prefix $prefix -Command Quit
& "$prefix\Uninstall-Caelestia.ps1" -Prefix $prefix
```

Rollback intentionally starts the retained version and checks readiness.
Uninstall preserves the profile by default. Add `-Purge` only to request deletion
of a profile exclusively owned by this installation. Autostart is opt-in via
`-Autostart` on install/update. `-NoIntegration` skips shortcut and Run entry
writes; it cannot be combined with `-Autostart`. No automatic release downloader
or authenticated update feed is implied by this manual release installer.

## Bundle format and developer packaging

`release.json` schema `caelestia-windows-release`, version 1 records the exact
shell and native-build source revisions, backend/dependency revisions, Qt
version, read-only native input digests, and size/SHA256 for every shipped file
except the manifest itself. It contains no raw build/install record or machine
paths. Its external digest covers the manifest. The ZIP digest covers the
entire deliverable, including bootstrap and manifest.

Only the three exact profile-directory pragmas in `shell/shell.qml` are
relocatable. Their placeholder hashes are verified before relocation. The
installed payload retains `release-manifest.json`; local `install.json` records
its digest and the destination QML/staging-record hashes. The production source
hashes remain unchanged. The original bundle manifest is not falsely presented
as a hash list of the relocated installation.

From a clean, committed candidate checkout with clean initialized dependencies,
use **its** packaging script and the exact matching read-only production build
made with `Build-Prototype.ps1 -PublicRelease`:

```powershell
.\windows\scripts\New-CaelestiaRelease.ps1 `
    -BuildRoot $testedBuildRoot -ReleaseId $previewId `
    -OutputDirectory $newOutputDirectory -SupplementalNoticesRoot $verifiedNoticesRoot `
    -QtPrefix $matchingQtPrefix `
    -VCRuntimeRoot $matchingX64CrtDirectory
```

The packager reuses `Install-Caelestia.ps1 -NoIntegration -SkipSchemeRuntime` in
an owned temporary prefix. It does not build native inputs or modify the
supplied build. A descendant packaging/QML-only candidate can reuse the native
build only if native inputs and dependency pins still match. Qt deployment and
supervisor compilation are packaging-time work, not user prerequisites.
The supplemental notice tree must contain the reviewed supplier license,
copyright, NOTICE and provenance texts for the exact linked dependencies,
including Qt's embedded third parties, CLI11, Rust and the locked Rust crates.
It is copied without overwriting existing notices, checked by SHA-256, included
in the release manifest and scanned by the same privacy guard. Corresponding
source archives are separate release assets, not files to put in that tree.

Output contains one extracted bundle, one ZIP, a ZIP SHA256 file and an external
manifest SHA256 file. Output must not already exist. A failed assembly leaves
output for inspection and must never be published as a release.

Privacy scanning checks every packaged file's UTF-8/UTF-16 strings for source,
build, SDK, temporary and user roots, private key/token patterns and absolute
PDB paths, plus drive-rooted paths in native binaries. It reports relative
candidate names only and fails closed. The committed
`windows/release/vendor-privacy-review.json` identifies reviewed Qt and Microsoft
runtime and public Qt SBOM bytes by exact payload path and SHA256. Only generic path findings in
those files can be excepted, and only when the deployed file still matches both
the review and its SDK origin. Project binaries, personal build roots and
credential matches are never excepted. PEM format headers alone are not key
material; the scanner requires following key data or an encrypted-key preamble.
Native path candidates must be readable strings or structured paths, not just
drive-like bytes followed by undecodable instructions. A dependency update requires a new
review; the manifest records the review file's digest. PDB files
and the local install record are omitted before hashing. No binary, font,
license, copyright notice or SBOM is patched to hide a finding. A finding may
require a clean, reproducible native build before publication. This is a
candidate scanner, not proof that arbitrary binary data contains no identity;
independent privacy review and exact-payload Windows validation remain gates.

Signing, tag naming, source/license distribution obligations, publication and
release acceptance remain external release-owner responsibilities. Nothing in
this script changes current licensing declarations or starts CI.
