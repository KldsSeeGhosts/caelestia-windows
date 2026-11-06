# Staged service model regressions

This is a focused addition to the existing public Unit and service fixtures,
not a replacement for them or a qualification of a Windows desktop.
Everything imports or loads production code. No private history or user data
is required.

## Run

From a public checkout with Node.js 22 or newer:

```powershell
.\windows\scripts\Test-StagedServiceModels.ps1 -PureOnly
```

For the QML lane, also provide a developer Qt 6.11.2 MSVC x64 prefix containing
`bin\qml.exe`, `bin\qtpaths.exe`, the QtQuick QML modules and
`plugins\platforms\qoffscreen.dll`:

```powershell
.\windows\scripts\Test-StagedServiceModels.ps1 `
    -QtPrefix C:\Qt\6.11.2\msvc2022_64 `
    -OutputRoot C:\validation\staged-service-models `
    -MutationControls
```

The script does not download, build, install or modify Qt or a shared build.
It does not require a native shell build or an installed release. Public
dependencies must already be checked out so their revisions can be recorded.
Output must be outside the source checkout. If omitted, it uses a new temporary
results directory. The script throws on a failure, timeout, empty/missing count,
missing case, unexpected diagnostic or a mutation that fails for the wrong reason.

Every QML process has `QT_QPA_PLATFORM=offscreen` set before launch, software
rendering, fake-only application module imports, a synthetic profile and a
20-second deadline. The runner kills only its own timed-out helper. It cleans
its uniquely named temporary stage/profile after checking the absolute cleanup
target. It never invokes GUI-linked `qml.exe` help/version probes. Qt identity
comes from console `qtpaths.exe --qt-version`.

`summary.json` records the source revision/dirty state, all three dependency
revisions, Qt version, runner/source hashes, case/assertion/test counts,
durations, failures, mutation outcomes and named skipped scopes. Raw per-process
stdout/stderr logs are local diagnostics and can contain temporary absolute
paths. Do not automatically publish those logs as sanitized CI artifacts.

## Coverage and traceability

Production QML is copied byte-for-byte to its `windows/shell/sources.json`
destination, preserving relative imports and Loader URLs. Only dependency
providers and small module descriptors are synthetic. The clipboard JavaScript
is evaluated unchanged under Node's VM. No production function body is copied
into a fixture.

| Case | Production implementation | Invariant beyond the existing scaffolds |
| --- | --- | --- |
| `apps-same-id-refresh` | `NativeAppCatalog.qml`, `AppsService.qml` | A refreshed catalog replaces an entry with a different object having the same ID. The old selection cannot execute or increment frequency; the current object and ID lookup remain usable. |
| `app-file-adapter-write-failure-recovery` | `FileAppFrequencyStore.qml`, `AppFrequencyStore.qml` | Real FileView adapter reads the injected document. Queuing is not a confirmed save. `saveFailed` clears pending accounting without claiming persistence or discarding memory; a later `saved` signal confirms recovery. |
| `notification-facade-read-failure-races` | `Notifs.qml`, `NativeNotificationBackend.qml`, `NotificationsService.qml`, `NotifData.qml` | Unreadable history survives an actual wrapper-delivered arrival and the facade's save-timer handler. Successful reload merges the live record. A missing-file queued write rechecks a later read-failure latch. |
| `notification-wrapper-ownership-revocation` | `NativeNotificationBackend.qml`, `NotificationsService.qml` | Real wrapper forwards observation tokens to a synthetic process-lifetime provider. A predecessor release cannot stop its replacement. Provider signals revoke mirroring/banner eligibility, retain consent observation, and regrant without prompting. Destroying the current service releases observation. |
| `clipboard-loader-delayed-results` | `ClipboardHistory.qml`, `NativeClipboardBackend.qml` | Disabled state constructs no worker. Snapshot and result signals traverse the real wrapper and facade. Unload requests shutdown exactly once. Synthetic queued items/paste/preview results are cancelled before a new generation, whose fresh results still work. |
| JavaScript selection/snapshot cases | `ClipboardHistory.js` | Stable-ID selection survives insertion, reorder and replaced snapshot objects; removal/filter/empty fallback is bounded; QVariantList-like input is accepted; malformed rows are dropped; search scans full text while display is capped without mutating input. |

The existing `AppsServiceTest.qml` covers removed entries, broad search and pure
frequency-store errors. `NotificationsServiceTest.qml` covers pure observation,
revocation and history failure logic. The new QML cases exercise their previously
uncovered wrapper/facade/FileView wiring, not a second copy of those broad tests.

Expected focused counts: 5 Node tests (including one mutation control), 5 QML
scenarios and 36 QML assertions. With `-PureOnly`, QML is explicitly not run.
With `-MutationControls`, five additional QML processes must each exit nonzero
at their named invariant, without a load/type diagnostic:

| Temporary staged behavior mutation | Required failing assertion |
| --- | --- |
| Compare app IDs instead of catalog object identity | `apps.same-id-stale` |
| Drop the native observation token | `notifications.wrapper-token` |
| Disconnect FileView's save-failure handler | `persistence.adapter-write-failure` |
| Remove the history read-failure save gate | `persistence.unreadable-preserved` |
| Omit the clipboard wrapper shutdown request | `clipboard.shutdown-on-unload` |

The Node control removes stable-ID lookup in memory and verifies the same
selection assertion fails. These are behavior mutations, not claims to have
reproduced a historical defect. Production files and shared builds are never
mutated. A passing unmodified baseline is required before QML controls run.

## Integration dependencies and limits

URL conversion and failed-close regressions have separate owners and fixtures.
This runner does not recreate or run them. The aggregate gate must consume
those results, including the confirmed URL defect's old-code-fail/corrected-pass
evidence. This contribution alone does not satisfy that historical-defect
acceptance or establish that every staged-shell regression is covered.

The Unit gate discovers the five JavaScript tests. The Services aggregate runs
the QML lane with its Qt prefix and all five mutation controls. The Shell aggregate
also runs the separate URL boundary suite. Existing relevant-change CI invokes
these aggregates and uploads their sanitized summaries, not raw fixture logs.
Independent review and hosted results are still required; a local fixture receipt
does not establish a CI pass.
`-PureOnly` requires no initialized native dependency checkouts and records an
empty dependency map because that lane does not load them. Full runs record the
actual checked-out dependency revisions.

The summary explicitly classifies these scopes as skipped, with reasons:

| Native-only scope | Required separate evidence |
| --- | --- |
| Windows app catalog and launch | AppsFolder/COM enumeration, native launch and observed window outcome. |
| Windows notification consent and bus | Real WinRT access denial/regrant, bus mutex ownership, system toasts, banner helper and fullscreen policy on a desktop. |
| Filesystem durability | Real access-denied/disk-full failures, QSaveFile atomicity, physical persistence and crash recovery. |
| Windows clipboard worker | The active `Caelestia.Windows.WindowsClipboard` native worker, Windows history/privacy markers, cancellation/generations, preview bytes and paste input. The synthetic worker proves QML shutdown/forwarding wiring only. Dormant legacy `Quickshell.Windows` clipboard APIs are not tested. |
| Clipboard picker desktop | Rendered overlay selection, focus return, keyboard, mixed DPI and actual delayed OS results. The pure selection model is not a rendered picker test. |

No real clipboard, notification content, personal profile, device, network,
external process action, credential, live installation or desktop input is used
by these fixtures.
