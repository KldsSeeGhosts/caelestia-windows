# Install a Windows release

Use the [verified public release table](../release/PUBLIC-RELEASE.md) for the
recommended version, exact Windows x64 download, SHA256 checksums and manifest
digest. Source ZIPs are not installable application bundles. Preview 2 has no
automatic updater. The guide below also describes current source installer
capabilities; it does not add those capabilities to an older downloaded ZIP.

This is the prebuilt Windows 11 x64 product, not a source archive. The bundle
includes the native shell, Qt DLLs/plugins/QML, M3Shapes, Glazier, fonts,
production shell/services, supervisor and maintenance/recovery scripts, and
third-party notices. Basic use needs no Qt SDK, compiler, Git or Python.
Read the [preview limitations](https://github.com/KldsSeeGhosts/caelestia-windows/blob/main/windows/docs/KNOWN-LIMITATIONS.md)
before installing.

## Microsoft runtime prerequisite

The installer requires Microsoft's free **Visual C++ x64 Redistributable**,
version **14.44.35211.0 or newer**:

https://aka.ms/vc14/vc_redist.x64.exe

This is Microsoft's official download, not a bundled or third-party installer.
Visual Studio and developer tools are not required. The runtime installer may
request administrator approval; Caelestia's own installation stays per-user.
The release installer checks the x64 runtime registration and system DLL
versions before changing an installation. If the runtime is missing, outdated
or incomplete, the current installer asks permission to download and install it.
Declining leaves the Caelestia installation unchanged. Older ZIPs may instead
require you to install or repair it yourself and rerun `Install.cmd`.

The installer downloads only the manifest's official URL above into a fresh
temporary directory. It requires a valid Authenticode signature from Microsoft
Corporation and a trusted Microsoft root certificate chain before execution.
It then requests administrator approval once and runs `/install /quiet /norestart`.
Exit codes 0, 3010 and 1638 are accepted, but the runtime must pass detection
again before any Caelestia installation or profile files are written. Code 3010
prints a reboot notice. Network, signature, UAC or installation failures stop
installation with instructions for manual repair. The temporary download is
deleted on success or failure. The runtime is installed system-wide, never app-local.

For automation, use `-NonInteractive -InstallPrerequisites` to consent without
a question. UAC approval may still be required. `-NonInteractive` alone refuses
if the prerequisite is not met. Redirected input and PowerShell's
`-NonInteractive` mode also refuse without explicit `-InstallPrerequisites`.
Bundle verification with `-VerifyOnly` never downloads, launches or elevates
anything and does not require the runtime.

Microsoft runtime DLLs are deliberately not bundled. The shared runtime can
receive Microsoft servicing independently of Caelestia. See
[Microsoft's deployment guidance](https://learn.microsoft.com/en-us/cpp/windows/deployment-in-visual-cpp?view=msvc-170#central-deployment).
Qt and the project's own DLLs remain included.

Crash handling is static code in `qs.exe` and uses Windows' inbox `dbghelp.dll`.
There is no separate crash-reporter executable or additional DLL to package.
Do not add a copy of the system `dbghelp.dll` to the release payload. Diagnostic
files are runtime user data, not release payload or support-bundle attachments.
See [Crash diagnostics and privacy](SUPPORT-BUNDLE.md#crash-diagnostics-and-privacy).

## Trust, signing and unsigned previews

The [code signing policy](CODE-SIGNING-POLICY.md) describes the intended stable
behaviour. Development (`v*-dev.*`) and preview (`v*-preview.*`, `v*-rc.*`)
packages are unsigned: there is no invented certificate or publisher signature,
and their first-party executables and scripts carry no Authenticode signature.
Deployed Qt DLLs keep Qt's signature in every channel.

The owner's decision is that stable releases
(`vMAJOR.MINOR.PATCH`, 1.0.0 or newer) will be signed through SignPath Foundation
once a signing pipeline exists. No release is signed today. The intended signed
set is the first-party executables and PowerShell scripts in the ZIP. Qt's DLLs
keep Qt's own signature, the M3Shapes DLL and `qs.exe` are not signed by this
project, `Install.cmd` is a batch file that cannot be signed, and the ZIP itself
is not signed. [SIGNING-ROADMAP.md](SIGNING-ROADMAP.md) lists the pipeline work
that must land before this changes.

SHA256 checks detect damage or changes against a trusted digest; a manifest
stored beside its files does not authenticate its publisher. Obtain the ZIP and
its published SHA256 from the project's actual GitHub release, not an unrelated
mirror. Check the ZIP with `Get-FileHash -Algorithm SHA256` before executing
anything from it. If supplied, keep the separately published manifest digest for
`-ExpectedManifestSha256`.

When a signed stable release exists, you will be able to check the publisher
yourself:

```powershell
Get-AuthenticodeSignature .\payload\caelestia-capture.exe | Format-List Status, SignerCertificate, TimeStamperCertificate
```

`Status` must be `Valid`, the signer must be the exact recorded SignPath
Foundation subject, and a timestamp must be present. For the whole bundle, run
`windows\scripts\Test-AuthenticodeSignatures.ps1 -BundleRoot <extracted> -Channel stable -ExpectedSignerSubject '<exact subject>'`
from a reviewed checkout. It first checks the reviewed file inventory and the
bundle manifest, then confirms that every Qt DLL kept its Qt signature and that
no third-party file was re-signed with the project certificate. A stable release
would fail this check if any reviewed first-party file is missing, has no
timestamp, or names another publisher. The verifier is standalone; no CI job
runs it. Do not install a package that claims to be signed but fails it.

Windows policy, Smart App Control, antivirus or organizational policy may block
unsigned scripts or executables, and may still block a signed stable release:
Smart App Control weighs its own reputation data, and `qs.exe` is not signed by
this project. Do not disable those protections. A blocked preview is not
supported on that machine until an approved, externally signed release is
available. Packaging does not sign anything today and never alters machine
policy.
Like the existing product launchers, `Install.cmd` uses `-ExecutionPolicy Bypass`
for its own PowerShell process only, to run the unsigned preview bootstrap.
This is not a signature or a trust check. It changes no persistent policy and
does not disable Smart App Control, antivirus or enforced organizational policy.

The generated Start-menu and Settings entries start `conhost.exe --headless`
with Windows PowerShell. `conhost` and PowerShell are signed Windows components,
and `--headless` keeps the console window from appearing. The installed `.ps1`
files are unsigned data for those hosts. That is not a trust exemption: under
App Control or Smart App Control, Windows may block the unsigned launcher and
action scripts until [issue #20](https://github.com/KldsSeeGhosts/caelestia-windows/issues/20)
provides publisher signing. Smart App Control and SmartScreen also judge
Caelestia's own unsigned native files (`qs.exe`, `caelestia-capture.exe`), which
are the other signing targets for #20. The entries use `-ExecutionPolicy Bypass`
only for that single PowerShell process; they change no machine or user policy
and add no trust decision of their own. If policy blocks the unsigned scripts,
the entries fail closed. The PowerShell commands in this guide run the same
unsigned scripts, so they work only where that policy allows them; they are an
alternative to the entries, not a way around a block. A signed launcher EXE
(#20) replaces the conhost command in one helper
(`Get-CaelestiaLaunchCommand`) and removes the unsigned script from the launch
path.

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

After the runtime prerequisite is met, installation is per-user and does not need elevation. It does not start the
shell, register autostart, hide the taskbar or enable tiling. Unless
`-NoIntegration` is supplied, it creates two Start-menu entries and a per-user
Settings > Apps uninstall entry. `-DesktopShortcut` adds an optional desktop
shortcut. Defaults:

- Product: `%LOCALAPPDATA%\Programs\caelestia-windows`
- Profile: `%LOCALAPPDATA%\caelestia-windows`

Use `-Prefix` and `-ProfileRoot` for separate local installations. Paths may contain
spaces or non-ASCII characters. Bundle, prefix and profile must not contain each
other. A populated foreign profile or unowned prefix is refused, not adopted.

## Start, switch back and uninstall without a terminal

Three generated entries cover the whole lifecycle. They never open a
PowerShell window and never change your execution policy.

- Start menu > **Caelestia Windows** starts the installed shell through
  `Start-Caelestia.ps1`.
- Start menu > **Caelestia - Switch back to Windows** quits this installation,
  restores the native taskbar and desktop, and offers to turn autostart off.
  It calls the stable-root `Start-Caelestia.ps1 -Command Quit` entry, the
  same path the shell uses; that entry stops the shell or supervisor and
  restores the native desktop, so it still works when the shell is hung. Start
  the shell again with the launch entry.
- Settings > Apps > Installed apps > **Caelestia for Windows** > Uninstall runs
  the installed `Uninstall-Caelestia.ps1`. It asks whether to also delete
  settings and profile data; the default keeps them.

> Screenshot placeholder: Start menu with "Caelestia Windows" and
> "Caelestia - Switch back to Windows". Added after live desktop acceptance.

> Screenshot placeholder: Settings > Apps > Installed apps showing Caelestia for
> Windows and its uninstall action. Added after live desktop acceptance.

The uninstall dialog explains that Windows update trust data in
`%LOCALAPPDATA%\caelestia-update-trust` is kept. That record is deliberately
outside the installation and profile: the client stores the newest signed update
metadata it has accepted there so a rollback or a reinstall cannot roll update
security back to older metadata. Uninstall therefore never deletes it, even with
`-Purge`; remove it manually only if you understand that consequence.

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

The recommended Preview 2's Settings > Updates links to manual downloads.
Use the [verified public release table](../release/PUBLIC-RELEASE.md) to select
the intended public preview. Preview 2 reads installed and retained versions,
not the latest online release, so the latest public version is shown as unknown.
Preview 2 has no automatic updater. Current-source authenticated development
publication is separate, as described in [UPDATES.md](../../UPDATES.md).
Preview/stable promotion stays inactive. A manual download link
does not mean a newer version is available for your installation.

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
The Settings entry follows the selected version: update and rollback rewrite
`DisplayVersion`, the entry icon and the shortcut icons, so no stale version or
dangling shortcut is left behind. Uninstall preserves the profile by default.
Add `-Purge` only to request deletion of a profile exclusively owned by this
installation. Autostart is opt-in via `-Autostart` on install/update.
`-NoIntegration` skips every per-user entry (Start menu, switch-back, desktop
and the Settings uninstall entry) and cannot be combined with `-Autostart` or
`-DesktopShortcut`. No automatic release downloader or authenticated update feed
is implied by this manual release installer.

## Bundle format and developer packaging

`release.json` schema `caelestia-windows-release`, version 1 records the exact
shell and native-build source revisions, backend/dependency revisions, Qt
version, the system Visual C++ runtime prerequisite, read-only native input
digests, and size/SHA256 for every shipped file
except the manifest itself. It contains no raw build/install record or machine
paths. Its external digest covers the manifest. The ZIP digest covers the
entire deliverable, including bootstrap and manifest. `signing` is
`unsigned-preview` for every current package. A future signed release needs a
reviewed manifest and receipt contract first; see
[SIGNING-ROADMAP.md](SIGNING-ROADMAP.md). Never edit the manifest of a signed
bundle: the signatures cover the files, not the manifest.

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
`VCRuntimeRoot` supplies only the existing developer assembler's temporary local
installation. Those Microsoft DLLs are removed from the copied public payload
before hashing. The release verifier refuses runtime DLLs or redistributable
installers anywhere in the bundle.
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
`windows/release/vendor-privacy-review.json` identifies reviewed Qt and public
Qt SBOM bytes by exact payload path and SHA256. Microsoft runtime files must
be absent and have no privacy exceptions. Only generic path findings in
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
this script changes current licensing declarations or starts CI. This packager
does not sign and has no signing hook. The standalone verifier and the draft
artifact configuration are not a signing pipeline;
[CODE-SIGNING-POLICY.md](CODE-SIGNING-POLICY.md) states the intended policy and
[SIGNING-ROADMAP.md](SIGNING-ROADMAP.md) lists the pipeline work that must land
before any signed stable release.

## Package lifecycle regressions

Run the ZIP test with 64-bit Windows PowerShell. It needs no developer build
or Qt SDK. Use a reviewed release ZIP, not an arbitrary untrusted download.

```powershell
.\windows\scripts\Test-PackageLifecycle.ps1 `
    -Package C:\downloads\caelestia-windows-VERSION-windows-x64.zip `
    -OutputRoot "$env:TEMP\package-lifecycle-results"
```

The results directory must not exist. `results.json` records each case's
outcome, exact ZIP SHA-256, manifest SHA-256 and bundled toolchain receipt.
The test validates archive paths before extraction, then uses the checkout's
data-only manifest verifier before executing any package script. Manifest
integrity is not publisher authentication. Obtain the ZIP digest through
trusted release metadata when qualifying a release.

The test uses a unique disposable TEMP root for the extracted ZIP, installation
prefix and profile. It redirects shortcuts and registry entries through
`CAELESTIA_TEST_INTEGRATION_ROOT`, then removes only those test locations.
It does not request autostart, start the shell, download optional Python
dependencies, or stop a user's shell. Rollback calls the packaged
`Switch-CaelestiaVersion` under the lifecycle lock without `-Restart`.
The manager's `Rollback -Wait` command requests a restart and is unsuitable
for this stopped test.

Covered cases include complete manifest verification, unsafe paths, reparse
points, changed/missing/extra files, missing/outdated runtime probe fixtures,
clean install, profile pragma relocation, update, configuration preservation,
stopped rollback, denied selector writes, failed process-stop injection,
concurrent lifecycle locking, failed shortcut writes with prior selector and
integration recovery, uninstall that preserves configuration, foreign-owner
purge refusal, and exclusive-owner purge.

Pass `-PreviousPackage <zip>` to use a separately verified historical ZIP.
Both packages must support disposable integration redirection. Without it,
the test installs the exact current payload and changes only its installed
version metadata to `0.0.0` before updating. Every result identifies this
synthesized older baseline. It is not historical binary compatibility evidence.
`previous-package.txt` also describes the baseline.

Failure injection lives only in the test's in-memory script blocks. The
missing/outdated probes feed deterministic registration and DLL versions into
the packaged runtime predicate. The denied-write case holds the selector open
for reading without write/delete sharing. Process-stop failure replaces the
packaged stop function with a throwing test function. It neither starts nor
kills a real process, so actual Windows process termination remains separate
acceptance. A second runspace holds the real lifecycle lock for contention.
No production installer bypass or test switch is added.

CI runs the test after ZIP assembly in the candidate job and retains
`package-lifecycle-*` evidence. It adds no work to the required "Windows
validation" job. Windows Server 2022 uses `-ServerTransactionFixture`, which
removes only the Windows 11 build-floor check in memory and labels every
result as a fixture. The real system runtime probe still runs for successful
installs. This does not qualify Server as a supported installation platform.

### Separate clean-environment acceptance

Issue #16 remains subject to a real clean Windows 11 x64 VM or hosted-runner
check. Start with a snapshot without Git, a compiler, Qt SDK, or VC++ x64
runtime. Record OS version, PATH, ZIP digest, manifest digest and toolchain
receipt. Use disposable prefix/profile paths and the test integration
redirection. Run the unmodified packaged bootstrap and confirm that its real
runtime probe refuses installation before creating either directory.
Repeat from an image with a genuinely outdated VC++ runtime. Do not uninstall
or downgrade the runtime on a contributor's workstation to manufacture this
state.

Install the supported Microsoft runtime in the disposable VM, then run this
test without `-ServerTransactionFixture`. A release owner must separately
verify actual shell launch/readiness and scoped process termination there.
Record those results against the same ZIP digest. The offscreen transaction
suite does not replace that check, live-desktop acceptance, or physical
graphics and hardware qualification.

## Nexus bootstrap status

Preview 2 has no updater. Source merges do not update it. The new client
ships configured development root trust. Development publication requires owner
setup; preview/stable promotion remains inactive.
Do not replace the existing install during source validation. See
[UPDATES.md](https://github.com/KldsSeeGhosts/caelestia-windows/blob/main/UPDATES.md)
for owner-only bootstrap and remaining gates.
