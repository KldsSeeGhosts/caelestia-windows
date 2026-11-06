# Uninstall transaction regression fixture (ERM-629)

Run in 64-bit Windows PowerShell 5.1 on Windows 11 x64, from the repository root:

```powershell
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File windows/scripts/Test-UninstallTransaction.ps1 -OutputRoot D:\Caelestia\validation-erm629
```

The output directory must be absent or carry this fixture's exact ownership
marker. Each invocation retains its own `run-<guid>` directory and sanitized
`receipt.json`, worker results, boundary traces and stdout/stderr. It does not
recursively clean old runs. Do not point it at an existing installation.

Policy: uninstall uses the same nonblocking prefix lock as installation and
rollback. Contention returns `An installation, rollback or uninstall is already
in progress.` before reading the mutable manifest/profile or stopping anything.
There is no wait/retry policy and no additional mutex.

## What executes

The controller creates disposable, separate prefix, owned profile, unrelated
profile, fake integration and synthetic release directories. Independently
controlled hidden Windows PowerShell processes run copies of the actual
`Install-CaelestiaRelease.ps1`, `Manage-Caelestia.ps1 -Command Rollback -Wait`,
and `Uninstall-Caelestia.ps1` entrypoints. Common and version helpers are copied
unchanged. Release file enumeration, hashes, relocation, staging, publication,
selector writes, rollback, tombstone removal and purge run their actual bodies.
Checks assert the install publishes a new payload and rollback selects `v1`.
This is not a standalone mutex reacquisition test.

Test copies have exact-match, fail-closed injections only:

* Immediately after importing common helpers, load the fixture's external
  process, task, scheme-provisioning and integration boundaries.
* Replace the release's machine VC runtime probe call with success. All other
  release validation runs against the synthetic manifest and file hashes.
* Redirect uninstall's literal live HKCU Run path to the case's fake integration
  directory. Fixture `Get-ItemProperty`/`Remove-ItemProperty` refuse any other
  path/name and operate on a plain file. Shortcut discovery returns another
  case-owned file, not the user's Start menu.
* Synthetic launchers accept only this prefix's `Quit` and record that boundary.
  Payload EXE/DLL files are never executed. No real shell, Glazier, supervisor,
  task, desktop, registry value, menu, authentication or ACL is changed.

Install pauses in its process preflight after acquisition; rollback pauses in
its scheme-selection boundary after acquisition; uninstall pauses in integration
discovery after acquisition and identity validation. The controller releases
each explicitly. Each boundary and worker has a bounded timeout.

## Scenarios and assertions

The default run has 18 scenarios, currently 270 controller assertions, plus
fail-closed boundary checks:

* Install-held and rollback-held versus uninstall, normal and purge. Busy
  uninstall preserves every prefix/profile/integration/unrelated-profile byte.
  Alternate case/slash/dot/trailing-separator spellings use the installers'
  existing `Resolve-CaelestiaDirectory` identity, not a fixture-specific key.
* Uninstall-held versus real install and rollback, normal and purge.
* Terminated install, rollback and uninstall owners, normal and purge. Observer
  handles keep **both existing shared mutex objects** alive after the owner is
  killed, so recovery exercises abandoned ownership rather than a new mutex.
* Successful uninstall and injected pre-mutation exception release. Another
  real operation succeeds while the first worker process remains alive, proving
  `finally` release rather than release caused by process exit.
* Busy uninstall with a temporarily malformed mutable manifest returns busy
  without reading it. The controller restores the manifest before releasing
  the installer; the resulting installed selector/payload remains coherent.
* Foreign profile ownership refuses purge with all managed bytes unchanged.
* Tombstones are removed, purge removes only the owned profile, ordinary
  uninstall preserves config, and the unrelated profile sentinel survives.

**Known acceptance limit:** the current, unmodified `Manage-Caelestia -Wait`
writes `profile/state/update-operation.json` with `failed` on a busy refusal.
Reverse rollback contention checks all other directories/files byte-for-byte
and explicitly asserts that journal behavior. Reverse install contention has no
exception. This fixture does not claim literal unchanged-profile acceptance for
the reverse rollback case. `fullAcceptanceComplete` stays false in the receipt.
Changing Manage is outside ERM-629's assigned file lease; the coordinator must
review/disposition that criterion separately.

## Negative control and evidence

Read the pre-fix uninstall into the sandbox without changing the checkout:

```powershell
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File windows/scripts/Test-UninstallTransaction.ps1 -OutputRoot D:\Caelestia\validation-erm629 -UninstallSourceRevision 2bda261d5c467a5e4c71b85fdfd12aff7717a2a7
```

Expected failure on the first assertion: `Expected Busy, got Success`.
The old uninstall actually removes the disposable prefix while the real
installer is paused holding the shared lock. This is a controlled synthetic
Windows race result, not a claim of observed production data loss.

Initial implementation validation on Windows build 26300.9711, AMD64, Windows
PowerShell 5.1.26100.9711: 18/18 scenarios and 270 assertions passed. The negative
control failed as expected at assertion 1. Earlier fixture-development failures
(missing worker-scope diagnostic helper, then PowerShell process-handle exit-code
collection) remain in their separate sanitized local run receipts.

The receipt records the exact checked-out source and dependency heads and the
current production uninstall file digest. For negative controls,
`negativeControlRevision` identifies the uninstall read from Git instead.

This is component/fixture evidence only. It does not execute the source-build
installer, native payloads, real process shutdown/integration, a packaged release
or an interactive desktop. Independent review, integration, disposition of the
busy rollback journal criterion and exact-release qualification remain external
gates. Do not mark the issue Done from this receipt alone.
