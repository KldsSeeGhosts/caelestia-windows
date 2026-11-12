# Dependency inventory and advisories

`windows/release/component-inventory.json` records runtime payload, build-only
and optional components. Refresh it with Python 3.11 or newer:

```powershell
python -I -B windows/release/dependencies.py inventory
python -I -B windows/release/dependencies.py inventory --check
```

Versions, pins, Cargo graph edges, hashes, font licences, deployed Qt DLLs and
Actions come from their existing lockfiles and reviewed recipes. Crate licence
expressions come from the checksum-verified corresponding-source inventory.
For new crates, first prepare corresponding sources using
`Prepare-CaelestiaSourceAssets.ps1`, then pass its `component-inventory.json`
with `inventory --supplier-inventory <path>`. Review licence changes, source
pins, notices and the inventory in the same focused dependency-update PR.
Never move a checksum pin merely to make a download pass.

The Cargo graph is conservative. Proc-macro dependencies are build-only.
Other locked crates may contribute statically linked code, but source or
notice inclusion does not establish binary linkage. Qt source-module licence
lists cover conservative source contents. Deployed DLLs have separate entries;
the supplier Qt SBOMs and notices describe their embedded third parties.
Python, scheme packages and Microsoft's system runtime are external or optional.
Their inventory entries do not mean they are installed in a release ZIP.

## Release SBOM

During candidate assembly (`New-NexusCandidate.ps1`), the job generates a
CycloneDX 1.6 JSON (`release.cdx.json`) and a sanitized package-lifecycle
receipt (`package-lifecycle-receipt.json`), includes both in the candidate
asset set so they are sealed, hashed, signed in `release-record.dsse.json`,
privacy-scanned and uploaded as permanent release assets, and also retains the
candidate artifacts (`release-sbom-<run>-<attempt>` and
`package-lifecycle-<run>-<attempt>`). Generating them does not add work to the
required "Windows validation" dependency path. Download the SBOM and receipt
from the release assets or from the candidate run.

```powershell
python -I -B windows/release/dependencies.py sbom `
  --package <assembled.zip> --coverage <candidate-component-inventory.json> `
  --output <release.cdx.json> --receipt-output <release.json>
```

The generator reads the ZIP without extracting or executing it. It checks the
receipt hash, every file hash and size, exact source-coverage ownership, current
native pins and reviewed Qt DLL hashes. Unknown ZIP members, receipt members,
owners and Qt modules fail. The SBOM records the archive, receipt and coverage
hashes and includes every file with an owner dependency. Optional absent
components are omitted. Build-only and conservative Cargo graph records are
labelled separately from direct file evidence.

For a historical release only, use `--allow-historical` with that release's
own corresponding-source coverage inventory. Versions then come from the
historical receipt and coverage, not today's pins. Unknown crate identities
and Qt DLL paths still require review. This option is never used in CI.

## Advisory policy

The read-only "Dependency advisories" workflow runs weekly and when dependency
inputs change. It is path-filtered and is not a required pull request check,
because it does not emit a status on PRs that do not touch dependency inputs.
It installs cargo-audit 0.22.2 from a SHA-256-verified crate,
honours its locked build dependencies, and audits `windows/capture/Cargo.lock`,
writing `cargo-audit.json` and an inventory-bound `advisory-result.json`
receipt to its `dependency-advisories-<run_id>` artifact.
No secrets, write permissions or cache saves are used. A scanner failure,
unavailable or stale advisory database, filtered report, unreviewed finding,
or expired review fails this separate advisory job. The required offline Unit
suite verifies inventory consistency and the fail-closed policy with fixtures.
It does not fetch RustSec data or claim to have run a live security scan.
The online job also requires the scanner to report RUSTSEC-2022-0008 for a
controlled `windows` 0.31.0 lock fixture. That fixture is never a product input.

### Release eligibility and freshness limit

Before publishing a development release or promoting a build to preview or
stable, `nexus_publish.py` checks `verify_current_advisory` against the
completed `Dependency advisories` workflow runs on `main`:

- An advisory result is reusable only when its retained `advisory-result.json`
  and `cargo-audit.json` match the exact `component-inventory.json` digest
  (`inventorySha256`), `windows/capture/Cargo.lock` SHA-256 (`cargoLockSha256`),
  and `windows/release/advisory-exceptions.json` digest (`exceptionsSha256`).
- Freshness limit: **7 days** (`ADVISORY_FRESHNESS_DAYS = 7` from `checkedAt`
  to publication time), and all reviewed entries in `advisory-exceptions.json`
  must still be unexpired.
- Missing, failed, mismatched-inventory or stale advisory results refuse
  publication (`advisory-result-missing` or `advisory-result-stale` /
  `advisory-check-failed`); absence of a run never implies eligibility.
- Ordinary pull-request validation is unaffected so PRs outside dependency
  paths never block on the path-filtered advisory workflow.

Read findings in the retained cargo-audit JSON. Update the affected dependency
and lockfile first. If a finding does not apply or needs temporary acceptance,
add an exact component/version review to `advisory-exceptions.json` with the
advisory ID, applicability, reason, upstream source, owner and revisit date.
Temporary acceptances expire. A "patched" or "absent" review never suppresses
an actual Cargo finding. Re-review entries when their component version changes.

Qt has reviewed applicability entries in that same file, based on
`QT-6.11.3-QUALIFICATION.md` and the linked Qt security advisories. This is a
manual module/API applicability review, not an automated Qt advisory scanner.
The weekly expiry check prompts another review. Check Qt's security advisories
when servicing Qt and record fixed versions and which shipped APIs apply.

A clean result is not proof of application safety. These checks do not replace
targeted code review, runtime tests or live-desktop acceptance.
