# M2 app catalog backend gaps (ERM-505)

Task-owned audit of `Quickshell.DesktopEntries` in the pinned Windows backend,
recorded 2026-10-25 on the app catalog branch. Source paths are relative to
`windows/deps/quickshell/`. This is a source audit plus fixture evidence, not a
claim about every Windows profile. This branch modified no backend source,
gitlink, or `sources.lock.json`.

## Catalog API observed at `14010429`

`DesktopEntries`
([`desktopentry.hpp`](../deps/quickshell/src/core/desktopentry.hpp), lines
312-337) exposes `applications` (an `ObjectModel<DesktopEntry>*`) and static
`byId`/`heuristicLookup`. `DesktopEntry` (lines 63-186) exposes `id`, `name`,
`genericName`, `startupClass`, `noDisplay`, `comment`, `icon`, `execString`,
`command`, `workingDirectory`, `runInTerminal`, `categories`, `keywords`,
`actions` and `execute()`.

The Windows backend is installed during plugin startup and:

- scans `FOLDERID_AppsFolder` through COM
  ([`desktopentry_backend.cpp`](../deps/quickshell/src/windows/desktopentry_backend.cpp),
  lines 158-273);
- watches the machine and user Start Menu program directories (lines 142-156);
- builds `packaged = fsPath.isEmpty()` categories `PackagedApp`/`Application`
  (lines 218-246);
- sets `icon = "appicon:" + id` (line 240), served by the Windows icon provider
  ([`appicon.cpp`](../deps/quickshell/src/windows/appicon.cpp), lines 134, 357);
- launches through `IApplicationActivationManager::ActivateApplication` with a
  `ShellExecuteExW` fallback on a `shell:AppsFolder\` token (lines 277-352).

Referencing the singleton constructs the entry manager and starts an
asynchronous scan plus path monitoring
([`desktopentry.cpp`](../deps/quickshell/src/core/desktopentry.cpp), lines
420-447; `desktopentry_backend.cpp:142-156`). Enumeration itself launches
nothing.

## Gap: no scan result

`WindowsDesktopEntryBackend::scan()` returns an empty list when
`CoInitializeEx`, `SHGetKnownFolderItem(FOLDERID_AppsFolder)`,
`BindToHandler(BHID_EnumItems)` or per-item display-name reads fail
(`desktopentry_backend.cpp`, lines 161-187, 199-201). Failures are logged with
`qCWarning`/`qCDebug` only.

`DesktopEntryManager::onScanCompleted()` then applies the (possibly empty)
result and emits `applicationsChanged`
(`desktopentry.cpp`, lines 546-630), which `DesktopEntries` forwards. There is
no `scanFailed`, `ready`, or error property, and the QML API cannot distinguish:

- a completed scan of a machine with no applications;
- a denied/failed AppsFolder enumeration;
- a scan still in progress (no signal until it completes).

The adapter therefore reports the first completed scan as `scanning` →
`ready`/`empty` and reserves `failed` for a QML component load failure or a
shape error. A native scan failure is shown as `empty`, not as a proven
zero-application Windows install, and never as a successful non-empty catalog.
A truthful `failed` state needs a backend scan-result API in a later pin.

## Gap: ignored terminal and command fields

`DesktopEntryBackend::execute` receives `command` and `workingDirectory` and the
Windows implementation uses only `command.first()` as the activation token
(`desktopentry_backend.cpp`, lines 334-344). `DesktopEntry::execute()` also
documents and implements no `runInTerminal` handling
([`desktopentry.cpp`](../deps/quickshell/src/core/desktopentry.cpp), lines
261-263; `desktopentry.hpp`, lines 110-121). The Windows scan never sets
`terminal = true`, so `runInTerminal` is false on this backend today.

Upstream `Apps.launch` wraps terminal entries in
`assets/wrap_term_launch.sh` with `GlobalConfig.general.apps.terminal`; that
Linux wrapper does not exist on Windows. This slice declares
`terminalLaunchSupported = false` and refuses terminal entries rather than
silently starting them without a terminal. If a future scan reports
`runInTerminal`, it stays an unsupported launch until a Windows terminal policy
exists.

## Gap: no per-command result

`DesktopEntry.execute()` and `DesktopAction.execute()` return void and dispatch
through `DesktopEntry::doExec`
(`desktopentry.cpp`, lines 339-353). The Windows backend's activation and
`ShellExecuteExW` failures are logged only (`desktopentry_backend.cpp`, lines
288-316). No signal, property or HRESULT reaches QML.

`AppsService.launch()` therefore returns true only when the request was
permitted and dispatched, never as confirmation that the application started or
focused. The original launcher has the same limitation; this slice does not add
retries, elevation, or `AppActions`.

## Reliance in this slice

- `applications.values` is read only while enabled and only after the first
  completed scan; hidden-app filters and invalid objects are applied in QML.
- `name`/`icon` come from the native entry. A missing icon keeps the original
  `AppItem` `Quickshell.iconPath(icon, "image-missing")` fallback.
- All launch policy (separate opt-in, membership, terminal refusal) lives in
  the pure adapter before calling the wrapper's single `execute(entry)`.
- The frequency store is a profile-local JSON file, not SQLite and not the
  upstream `${Paths.state}/apps.sqlite`; no HOME/XDG fallback is used.
- Admin/elevation, uninstall and `Quickshell.Windows.AppActions`
  ([`app_actions.hpp`](../deps/quickshell/src/windows/system/app_actions.hpp),
  lines 31-35) are never referenced.

## Residual limits

- Fixture coverage cannot establish real activation. This slice's native
  validation never launches an application.
- The AppsFolder enumeration is COM/shell dependent; failure mapping stays
  unavailable until the backend exposes a result.
- `Interactive` mode, terminal launching, admin actions and per-command results
  remain unvalidated.
