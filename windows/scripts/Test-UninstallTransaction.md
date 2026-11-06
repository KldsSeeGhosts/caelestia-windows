# Uninstall transaction regression fixture (ERM-629)

Run in 64-bit Windows PowerShell 5.1 on Windows 11 x64, from the repository root:

```powershell
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File windows/scripts/Test-UninstallTransaction.ps1 -OutputRoot D:\Caelestia\validation-erm629
```

The output directory must be absent or carry this fixture's exact ownership
marker. Each invocation retains its own `run-<guid>` directory and sanitized
`receipt.json`, worker results, boundary traces and stdout/stderr. It does not
recursively clean old runs. Do not point it at an existing installation.

Policy: uninstall and every non-Status maintenance path use the same nonblocking
prefix lock as installation. Contention returns a clear busy error before
reading the mutable manifest/profile, creating directories or writing journals.
Direct `Rollback -Wait` never creates or writes an operation journal, even on
failure. No additional mutex is introduced.

Queued setup takes that lock too. It registers the existing watchdog before
accepting the operation and starts the worker only after releasing the lock.
A busy tracked worker does not overwrite `queued` or unregister the watchdog.
The watchdog uses the same lock, never creates missing profiles/journals, and
has three one-minute Task Scheduler failure retries (30-second execution limit
per attempt). Successful/failed tracked work records a terminal phase before
removing its reporting task. Journal writes include prefix/install identity.

Uninstall cancels only maintenance tasks whose action proves the same prefix,
including a watchdog registered before an interrupted queue could write its
journal. Other-prefix task actions are left alone. An owned queued/working
journal is marked failed under the lock; purge then deletes only the owned
profile.

## What executes

The controller creates disposable, separate prefix, owned profile, unrelated
profile, fake integration and synthetic release directories. Independently
controlled hidden Windows PowerShell processes run copies of the actual
`Install-CaelestiaRelease.ps1`, the direct/queued/tracked/watch paths of
`Manage-Caelestia.ps1`, and `Uninstall-Caelestia.ps1` entrypoints. The real source
installer's preflight and shared-lock path also execute against data-only
prerequisites: it either refuses busy or throws at its first post-lock process
boundary, before assembly/deployment/compilation. Common and version helpers
are copied unchanged. Release file enumeration, hashes, relocation, staging, publication,
selector writes, rollback, tombstone removal and purge run their actual bodies.
Checks assert the install publishes a new payload and rollback selects `v1`.
This is not a standalone mutex reacquisition test.

Test copies have exact-match, fail-closed injections only:

* Immediately after importing common helpers, load the fixture's external
  process, task, scheme-provisioning and integration boundaries. Maintenance
  copies also expose entry and actual-manifest-read barriers for the stale-read
  race. No production transaction body is replaced.
* Replace the release's machine VC runtime probe call with success. All other
  release validation runs against the synthetic manifest and file hashes.
* Redirect uninstall's literal live HKCU Run path to the case's fake integration
  directory. Fixture `Get-ItemProperty`/`Remove-ItemProperty` refuse any other
  path/name and operate on a plain file. Shortcut discovery returns another
  case-owned file, not the user's Start menu.
* Synthetic launchers accept only this prefix's `Quit` and record that boundary.
  Payload EXE/DLL files are never executed. No real shell, Glazier, supervisor,
  task, desktop, registry value, menu, authentication or ACL is changed.
* Task registration/discovery/start/stop/removal operate on case-owned JSON
  records. The controller invokes the real scheduled entrypoints explicitly.
  Tests validate retry settings; they do not claim to qualify Task Scheduler.

Install pauses in its process preflight after acquisition; rollback pauses in
its scheme-selection boundary after acquisition; uninstall pauses in integration
discovery after manifest read and prefix/profile separation checks, but BEFORE
purge ownership validation or tombstone rename. Additional barriers cover
queued task registration/start, the actual manifest read, and post-rename
integration removal. The controller releases each explicitly. Each boundary
and worker has a bounded timeout.

## Scenarios and assertions

The receipt records the scenario/assertion counts, plus fail-closed boundary
checks. The extended run requires 38 scenarios and 665 controller
assertions. Coverage includes:

* Install-held and rollback-held versus uninstall, normal and purge. Busy
  uninstall preserves every prefix/profile/integration/unrelated-profile byte.
  Alternate case/slash/dot/trailing-separator spellings use the installers'
  existing `Resolve-CaelestiaDirectory` identity, not a fixture-specific key.
* Uninstall-held versus release install, source-install preflight, direct
  rollback and GUI queue setup, normal and purge. Every busy snapshot is
  byte-identical, including the journal, task records and staging/tombstone
  siblings. There is no journal exclusion.
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
* Direct rollback success and injected exception both preserve an existing
  journal, or leave an absent state directory absent.
* Purge versus a paused real rollback manifest read; purge completed before a
  late direct/queued/tracked/watch action enters. No profile resurrection.
* Tracked contention leaves both queued bytes and reporting tasks untouched;
  the watchdog records failure after lock release. Late tracked work cannot
  overwrite that terminal result. Tracked success/exception results are also
  checked independently.
* Queue start happens after lock release; a separately controlled source
  installer can reach its real post-lock boundary during the queued start.
* Queued tasks are cancelled by normal/purge uninstall; late watchdogs do not
  recreate state. An interrupted pre-journal queue leaves an orphan watchdog
  which prefix-verified uninstall discovers and removes. A foreign-prefix
  action is preserved.
* Post-rename injected exception and terminated owner, with busy direct/source
  install/watch contenders while the prefix is absent. Existing production
  behavior retains the owned tombstone, integration and profile at this early
  cleanup boundary. The fixture verifies those remnants, validates the exact
  tombstone path/product/install identity and reparse safety, moves it back,
  then retries the real uninstall. This is explicit fixture recovery, NOT
  automatic production crash recovery or partial-purge recovery.

## Negative control and evidence

Read the pre-fix uninstall into the sandbox without changing the checkout:

```powershell
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File windows/scripts/Test-UninstallTransaction.ps1 -OutputRoot D:\Caelestia\validation-erm629 -UninstallSourceRevision 2bda261d5c467a5e4c71b85fdfd12aff7717a2a7
```

Expected failure on the first assertion: `Expected Busy, got Success`.
The old uninstall actually removes the disposable prefix while the real
installer is paused holding the shared lock. This is a controlled synthetic
Windows race result, not a claim of observed production data loss.

Two additional negative controls use the original Manage implementation:

```powershell
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File windows/scripts/Test-UninstallTransaction.ps1 -OutputRoot D:\Caelestia\validation-erm629 -ManageSourceRevision b1e63431da54ffeb6e6c9904328b54b294c7e28a
powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File windows/scripts/Test-UninstallTransaction.ps1 -OutputRoot D:\Caelestia\validation-erm629 -ManageSourceRevision b1e63431da54ffeb6e6c9904328b54b294c7e28a -StaleReadOnly
```

The strict busy test fails because old Manage mutates the operation journal.
The stale-read test completes the controlled race and fails with
`Stale-read race: purge returned Success; profile recreated=True`.
`-StaleReadOnly` without a revision runs just the two corrected stale/purged
profile cases.

Initial implementation validation on Windows build 26300.9711, AMD64, Windows
PowerShell 5.1.26100.9711: 18/18 scenarios and 270 assertions passed. The negative
control failed as expected at assertion 1. Earlier fixture-development failures
(missing worker-scope diagnostic helper, then PowerShell process-handle exit-code
collection) remain in their separate sanitized local run receipts.

The receipt records the exact checked-out source and dependency heads and
production uninstall/Manage digests. For negative controls, the corresponding
revision field identifies source read from Git instead. Prior receipts and
failure logs are retained, not overwritten.

## Consumer deadline and evidence boundaries

`UpdateManager.qml` independently bounds queue startup and journal waiting to
ten minutes. If no terminal result is confirmed, it stops the busy indication
and reports **unconfirmed**, not a fabricated failure. It keeps the operation
identity and file watcher, refuses duplicate requests, and accepts a late
matching terminal result. Queued/working or foreign journals cannot reset the
deadline. No timeout writes into the profile or cancels another lock owner.

Run the actual singleton with recording process/file boundaries:

```powershell
windows/scripts/Test-UpdateManager.ps1 -QtPrefix <Qt-prefix> -BuildRoot <native-build-root>
```

The fixture exercises real timer expiry both before and after acknowledgement,
duplicate refusal, wrong/missing acknowledgements, smoke gating, foreign/stale
journals, late terminal results and terminal-state preservation. It neither
starts a real process nor writes a journal. The transaction and consumer
fixtures also run in the Packaging and Shell aggregate lanes respectively.
Default transaction output uses a unique temporary directory; explicit output
roots require the fixture ownership marker before reuse.

This is component/fixture evidence only. Native payloads, actual task execution,
real process shutdown/integration, source assembly/compilation, an exact packaged
release and an interactive desktop were not qualified. Independent review,
integration and exact-release qualification
remain external gates. Do not mark the issue Done from this receipt alone.
