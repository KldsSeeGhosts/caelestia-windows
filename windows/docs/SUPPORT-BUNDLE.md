# Sanitized support export

Run this only when you want a local support report. It does not upload anything,
start or restart the shell, request permissions, change settings, or contact a
network service. No SDK, Git, Node, administrator access or development checkout
is needed by the installed command. Windows PowerShell 5.1 and the two packaged
support scripts are required.

```powershell
& 'D:\Apps\Caelestia\versions\<selected-version>\Export-CaelestiaSupport.ps1' `
    -Prefix 'D:\Apps\Caelestia' -OutputPath 'D:\Reports\caelestia-support.json'
```

Use the actual selected payload's script location. The stable prefix can also
be a legacy non-versioned payload. The output's parent directory must exist.
Choose a new file outside the installation. Existing output is never replaced.
Only absolute paths on fixed local drives are accepted; network/device paths,
alternate streams and reparse-point ancestors are refused. Do not point the
command at an unrelated application or personal profile.

## Data boundary and bounds

The bundle is a single UTF-8 JSON document, at most 64 KiB. It is constructed
field by field, not by scrubbing arbitrary text. There are no path, log,
exception-message, arbitrary string, environment-map or content fields.

Only these files are read automatically: the explicit prefix's `install.json`,
the selected version's `install.json` if needed, and that payload's
`release-manifest.json`. Install records are limited to 64 KiB each; the release
manifest to 4 MiB. The optional offline snapshot is limited to 64 KiB.
JSON nesting is limited to 24. Files are not recursively enumerated.

The hidden collection worker has one deadline including startup and every read:
5 seconds by default, configurable with `-TimeoutMilliseconds` from 1 to 15000.
On timeout it is terminated, with at most a further 1-second exit wait. A small
schema-valid `unavailable/timeout` bundle is written instead. Process startup,
local path validation and the final filesystem write depend on Windows and are
not hard real-time guarantees. Ordinary partial failures retain other available
fields. A refused output path, write failure or worker termination failure
returns an error without printing underlying exception text. Preserve any
partial output locally, but do not share it as a completed bundle.

The exporter does not read a profile, log tail, clipboard, notifications,
window titles, SSIDs, credentials, screenshots, recordings or memory dumps.
Even a sanitized raw log is not an allowed input. Windows version and one
allowlisted architecture environment token are read locally. No driver/device
enumeration, WMI, network access or permission prompt runs automatically.
Display-driver version is unavailable unless supplied in the offline snapshot.

## Version 1 schema

The normative field shape is
[`support-bundle.schema.json`](../support/support-bundle.schema.json).
Every object, including nested error records, has `additionalProperties: false`.
[`support-bundle.example.json`](../support/support-bundle.example.json) is
entirely synthetic, not evidence of a release or hardware qualification.

`collection` describes collection itself, not provider health. `sources` reports
install/release/snapshot availability with stable reasons. Missing, invalid,
oversized, refused and timed-out inputs are never copied as arbitrary errors.
Individual absent or invalid scalar values become `null`; a readable source
does not imply every optional field exists or is valid.

`identity` includes validated release/source/native/dependency identities and
declared executable/manifest hashes. Release names must have the conservative
form `v1.2.3`, `1.2.3`, or a numbered `preview`, `alpha`, `beta` or `rc` suffix.
Other valid installation identifiers remain usable for selection but are not
exported. Revisions are exactly 40 lowercase hex characters; SHA-256 values
exactly 64 hex characters. Module versions are numeric, two to four components,
each at most five digits. No version banner or manifest text is copied.
`modules` selects Qt, materialyoucolor and Pillow versions from release metadata.
Other tool/module versions are not collected by version 1.

Identities have trust `declared-unverified`: this is not a package verifier or
publisher-authentication mechanism. Source consistency is checked when reading
a selected version and release manifest, but binary hashes are not recomputed.
Use the existing exact-package verifier for integrity qualification.

`providers` always contains 15 fixed IDs: `shell`, `tiling`, `audio`, `battery`,
`bluetooth`, `brightness`, `network`, `media`, `notifications`, `desktop`,
`capture`, `idleInhibit`, `keyboard`, `tray`, `wallpaper`. A row never proves an
unqueried provider healthy. Categories are deliberately separate from readiness
and asynchronous command progress:

| Category | Meaning |
| --- | --- |
| `supported` | The supplied observation identifies the supported route, not command completion. |
| `unsupported` | The supplied observation says the route/operation is not implemented on this configuration. |
| `denied` | Access was explicitly refused. |
| `unavailable` | Missing, failed-to-read or uncollected observation; not an empty healthy model. |
| `transient` | The supplied observation says a temporary/recovering condition. |
| `failed` | An observed operation failed. |
| `empty` | Successful observation with no items; can have `ready: true`. |

`ready`, `requested`, `accepted`, `completed` are boolean or `null` (unknown).
Acceptance never implies completion. A completion value is retained only when
both requested and accepted are explicitly true. These normalized fields do
not rename the existing native capability or command-result APIs. In particular
`initialized` is not inferred as ready, and native `accepted` is not `observed`.

Counters `failures`, `recentFailures`, `samples` are integers from 0 through
1,000,000,000 or null. Timing values are supplied integer milliseconds:
`lastDurationMs` at most 600,000; `totalDurationMs` at most 86,400,000.
At most four recent categorized error records per provider (60 total) are
retained, each with only category, allowlisted reason and bounded count.
Unknown categories become unavailable/invalid; unknown reasons become
provider-unavailable (or none for healthy supported/empty observations).
There are no exception messages, HRESULT strings or raw trace tails.

## Optional offline observations

The default report deliberately does not call a live provider. To add observations,
pass `-SnapshotPath 'D:\Reports\offline-status.json'`. This is a caller-selected
JSON file, never a command, scriptblock, DLL or provider executable. Its root must
have `schema: "caelestia-support-input"` and numeric `version: 1`. Unknown keys are
discarded, including unknown nested fields. Review it locally; never upload the
input itself.

```json
{
  "schema": "caelestia-support-input",
  "version": 1,
  "shellState": { "lifecycle": { "ready": true } },
  "tilingState": { "backendLoaded": true, "failedCount": 2, "recentFailureCount": 1 },
  "displayDriverVersion": "32.0.15.0001",
  "providers": {
    "audio": {
      "category": "failed", "reason": "operation-failed", "ready": false,
      "requested": true, "accepted": true, "completed": false,
      "errors": [{ "category": "failed", "reason": "operation-failed", "count": 1 }]
    }
  }
}
```

`shellState` accepts only `lifecycle.ready` from the existing shell `state` IPC
result. That endpoint's other fields include personal paths and labels, so the
whole response is never exported. `tilingState` accepts only `backendLoaded`,
`failedCount` and `recentFailureCount` from the existing content-free endpoint.
These endpoint projections take precedence over corresponding generic rows.
The existing manager `Status` identity fields already come from the same
installed metadata; the exporter reads those files directly, without executing
installed management code. Generic provider rows are supplied observations, not
a new live endpoint and not a claim that every provider currently exposes them.
No snapshot is automatically discovered or generated. A missing or bad snapshot
does not invalidate usable build identity.

## Inspecting and reporting

Open the output in a local text editor before sharing. Check the release and
source identity, unavailable reasons and relevant provider outcomes. You can
delete the local report at any time. Sharing is a separate manual action.

For a public report, use the public repository's issue form and include a short
reproduction, expected/observed behavior, and the inspected support JSON if you
choose. Do not attach source snapshots, profiles, raw logs, screenshots or dumps
by default. Do not put credentials or private material in a public issue; follow
the repository's private security-reporting instructions when appropriate.

## Build identity and symbols

Use `releaseId` plus `releaseManifestSha256` to locate the exact release record.
Use `sourceRevision` for shell sources and `nativeSourceRevision` for the native
binary build, which can legitimately differ after packaging-only commits.
Use dependency revisions and the declared executable hash to disambiguate builds.

The release owner must retain a private symbol index keyed by the exact release
manifest digest and executable hashes, recording the native source/dependency
revisions and matching PDB GUID/age. Resolve a report through that index and
verify the debugger's binary/PDB match, not just a filename or source SHA.
This exporter does not create an index, retain symbols, promise historical
symbol availability, download symbols or collect dumps. A missing index/PDB is
an explicit support limitation, not permission to substitute another build.
Symbol retention and release-workflow integration belong to the release owner.

## Fixture and package integration

```powershell
.\windows\scripts\Test-SupportBundle.ps1 -OutputDirectory 'D:\Caelestia\validation-support'
```

The focused runner requires Node for tests only. It creates synthetic prefixes,
logs and canaries under the explicit output directory, invokes the real exporter
and retains failure/timeout evidence without touching a real profile.

Package integration must include `Export-CaelestiaSupport.ps1` and
`Caelestia-Support.ps1` together in each installed payload, and distribute this
document, schema and sanitized example as inspectable support material. Preserve
`docs/SUPPORT-BUNDLE.md` and `support/*.json` in the payload to keep relative
documentation links working without installing test fixtures. A stable-prefix
shortcut/router is optional; do not imply it exists until wired by packaging.
The aggregate validation owner must register the focused runner with an
explicit isolated output. Exact-package acceptance remains open: qualify the
assembled bytes in a disposable install without a checkout, SDK or Node, from
both legacy and versioned layouts, including missing provider metadata and a
deadline. Source fixtures do not close that installed-package gate.
