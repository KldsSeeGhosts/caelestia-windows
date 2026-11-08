# SignPath artifact configuration (draft)

This directory holds a draft artifact configuration for the intended stable
release. It is not registered with SignPath, no signing job consumes it, and no
release is signed. The policy is in
[CODE-SIGNING-POLICY.md](../docs/CODE-SIGNING-POLICY.md); the work a real
pipeline still needs is in [SIGNING-ROADMAP.md](../docs/SIGNING-ROADMAP.md).

SignPath's GitHub action takes an artifact configuration slug, not a file path,
so the eventual pipeline cannot read this file at run time. The repository copy
is the reviewed source of truth for a registered copy:

- [caelestia-windows-stable.xml](caelestia-windows-stable.xml) is the draft.
- A future SignPath project would hold the registered copy. Registering or
  changing it is an owner action in the SignPath web interface; CI never writes
  it.

Keep the two identical if registration ever happens. Any change here is a
release-policy change and needs review like a workflow.

## Intended signed set

The uploaded artifact would be the release ZIP, uploaded with `archive: false`,
so the configuration root is `<zip-file>`. Inside the version-specific bundle
directory it signs:

| Set | Paths | Notes |
| --- | --- | --- |
| PE | `payload/caelestia-capture.exe`, `payload/DesktopTakeover.dll`, `payload/caelestia-*.dll`, `payload/qml/Caelestia/**/caelestia-*.dll` | First-party binaries built from this repository |
| PowerShell | `Install-CaelestiaRelease.ps1`, `payload/*.ps1` | The bundle bootstrap and the 17 payload maintenance scripts |

The reviewed file list is
[windows/release/signing-inventory.json](../release/signing-inventory.json).
The verifier fails if the bundle is missing one of those files or contains an
unlisted first-party file.

It does not sign `payload/qs.exe` (an upstream-derived Quickshell build),
`payload/m3shapes.dll` or `payload/qml/M3Shapes/**` (soramanew/m3shapes, Apache-2.0),
Qt's DLLs, plugins and QML modules (they keep Qt's signature), `Install.cmd` (a
batch file), or the ZIP itself. See the policy for the reasoning.

The depth-limited `qml/Caelestia` patterns exist because a SignPath wildcard
cannot express zero-or-more directory segments unambiguously. A first-party DLL
deeper than three module levels would stay unsigned, and
[Test-AuthenticodeSignatures.ps1](../scripts/Test-AuthenticodeSignatures.ps1)
fails the release rather than letting that pass.

## Metadata restrictions

`product-name` and `product-version` are SignPath Foundation's required
metadata restrictions. They require the signed PE files to carry a `VERSIONINFO`
resource whose product name is `Caelestia Windows` and whose product version is
the reviewed core version. The current build does not emit that resource, so a
signing request would fail closed until the resource is added to the capture
host, the desktop supervisor and the Caelestia QML modules. Do not remove the
restrictions to make a request pass.

## Registering it later

1. Finish the stable assembly contract in [SIGNING-ROADMAP.md](../docs/SIGNING-ROADMAP.md).
2. In the SignPath project, create the artifact configuration from this file.
3. Record the resulting slug for the signing job.
4. Compare the registered copy with this file after any edit.
