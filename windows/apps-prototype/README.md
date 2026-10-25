# Windows app catalog prototype

ERM-505's bounded M2 app-catalog slice projects the pinned backend's
`Quickshell.DesktopEntries` Windows AppsFolder/Start menu catalog through a
default-off, read-only adapter and loads the **original** Caelestia launcher app
list and search bar in a separate native window. No launcher row, typography or
motion is reimplemented.

## Scope and the original components

The host stages:

- [`modules/launcher/AppList.qml`](../../modules/launcher/AppList.qml) — the
  original result list, including its delegate transitions, state changes and
  highlight motion;
- [`modules/launcher/items/AppItem.qml`](../../modules/launcher/items/AppItem.qml)
  — the original row (icon, name, comment, favourite glyph);
- [`components/controls/SearchBar.qml`](../../components/controls/SearchBar.qml)
  and its existing control closure;
- [`components/containers/StyledListView.qml`](../../components/containers/StyledListView.qml)
  and [`components/controls/StyledScrollBar.qml`](../../components/controls/StyledScrollBar.qml).

The full launcher `Content`/`ContentList`/`Wrapper`, wallpapers, actions,
calculator, schemes, variants, `Apps.qml`'s Upower/AppDb dependencies and every
shell controller stay unloaded. `AppList` gained one localized property,
`appsOnly`, defaulting to `false` for upstream Linux. When true, `stateForText`
always returns `apps` and `resultsForText` always calls `Apps.search`, so the
bounded host never activates the action/calculator/scheme/variant providers.
The original component files for those providers are replaced by inert
adapters under [`adapters/`](adapters) that satisfy the list's static
declarations and start no process.

The window is at most 560x560 logical pixels, inset 80 from the chosen screen.
Escape closes an interactive run. When the catalog is not ready the host shows
the same empty-state row used by the original launcher (`MaterialIcon` +
`StyledText` with `Tokens` spacing/typography) with short state copy: disabled,
scanning, failed and empty. A ready catalog with no matches shows the original
"No results" / "Try searching for something else" wording.

## Service states

[`AppsService.qml`](../services/apps/AppsService.qml) imports no Quickshell,
native `DesktopEntries`, SQLite or Caelestia.Models. It owns five explicit
states:

| state | meaning |
| --- | --- |
| `disabled` | catalog opt-in absent; no native facade or frequency store exists |
| `scanning` | facade present; no completed enumeration reported yet |
| `empty` | enumeration completed with zero valid applications |
| `failed` | reported component/shape/scan error (`lastError` is non-empty) |
| `ready` | one or more named applications (`count`) |

[`NativeAppCatalog.qml`](../services/apps/NativeAppCatalog.qml) is the thin
native wrapper. It exposes `DesktopEntries.applications`, records
`DesktopEntries.applicationsChanged` as `scanCompleted`, and exposes
`execute(entry)` for an explicitly permitted launch. Referencing it starts the
backend's asynchronous AppsFolder scan and Start menu monitoring
(`windows/deps/quickshell/src/core/desktopentry.cpp:420-447`,
`src/windows/desktopentry_backend.cpp:142-156`). Enumeration and search never
call `execute`.

The pinned backend has **no scan-result flag**. `applicationsChanged` fires for
a completed scan even when the native scan returned an empty list because COM
or the Apps folder failed (`desktopentry_backend.cpp:158-187`). A native scan
failure therefore reaches this slice as `empty`, not `failed`; `failed` is
reserved for a component load failure or a reported facade error. This is a
backend gap, recorded below.

Names come from the entry; icons are the backend's `appicon:<id>` values. When
an entry has no icon the original `AppItem` keeps its
`Quickshell.iconPath(icon, "image-missing")` fallback, and the adapter's
`iconName()` reports the same `image-missing` value for hosts and tests.

## Search and frequency store

The original `Apps.search` contract is preserved: `search`, `query`, `list`,
`keys`, `weights`, `useFuzzy`, `selector`, the `@i/@c/@d/@e/@w/@g/@k/@t`
special prefixes, and the terminal filter. The upstream `utils/scripts/fzf.js`
and `fuzzysort.js` libraries are imported unchanged, so ranking is the original
fzf/smart-case (or fuzzysort when configured) behavior. The list order is the
original AppDb order: favourites first, then launch frequency descending, then
name. Frequency also breaks exact relevance ties through that list order.

The prefix key spec and finder are local query values rather than QML property
writes. `search()` no longer rewrites `keys`/`weights` while the original list's
`ScriptModel.values` binding is evaluating; doing so produced binding-loop
diagnostics on this backend. Results are unchanged.

`AppFrequencyStore.qml` replaces the excluded Caelestia.Models/AppDb SQLite
store. It reads and writes a versioned JSON document
(`{"version":1,"frequencies":{...}}`) through an injected storage object, floors
valid non-negative counts and drops invalid ids/counts. A missing file is an
empty store; corrupt JSON or a wrong-shaped document is tolerated (`corrupt`,
`lastError`) and the next permitted launch replaces it. There is no SQLite
dependency and no HOME/XDG fallback.

[`FileAppFrequencyStore.qml`](../services/apps/FileAppFrequencyStore.qml)
supplies the real storage with `Quickshell.Io.FileView`
(`atomicWrites: true`, `printErrors: false`, no watch) at
`$CAELESTIA_STATE_DIR/apps-frequencies.json`. The path is derived only from the
isolated state directory; `AppStoragePath.js` rejects empty, relative, UNC and
traversing roots, so the store stays memory-only rather than writing elsewhere.
Writing happens through `QSaveFile`/rename inside `FileView`
(`windows/deps/quickshell/src/io/fileview.cpp:254,289`).

## Opt-ins and launch policy

Both opt-ins are child-process environment variables; the launcher sets them
explicitly so inherited flags cannot enable the catalog in the M1 profile.

- `CAELESTIA_WINDOWS_APPS=1` enumerates and searches (read-only).
- `CAELESTIA_WINDOWS_APP_LAUNCH=1` additionally permits explicit launches.

`launch(entry)` refuses unless the launch opt-in is set, the catalog is `ready`,
the exact entry is a member of the current list, and the entry is not a terminal
application. Refusals set `lastLaunchError` and never call the native execute.
A permitted launch increments the frequency and calls
`NativeAppCatalog.execute(entry)`, which calls `DesktopEntry.execute()`. The
backend has no per-command result: `launch()` returning true means the request
was dispatched, not that the application started.

Terminal applications are an explicit unsupported launch. Upstream wraps them
in `assets/wrap_term_launch.sh` with `GlobalConfig.general.apps.terminal`; no
such wrapper exists on Windows and `DesktopEntry.execute()` ignores
`runInTerminal`, so `terminalLaunchSupported` is false and a terminal entry is
never started without a terminal. Admin elevation, uninstall and
`Quickshell.Windows.AppActions` are out of scope and unreferenced.

```powershell
$qtPrefix = "$env:LOCALAPPDATA\caelestia-dev\Qt\6.11.2\msvc2022_64"
powershell -NoProfile -File windows/scripts/Start-ShellPrototype.ps1 `
    -QtPrefix $qtPrefix -Apps -AppsMode ReadOnly -Wait
```

`-Apps` selects this entry point. `Disabled` is the default and never loads
`NativeAppCatalog.qml` or `FileAppFrequencyStore.qml`. `ReadOnly` enumerates,
searches and keeps launching disabled. `Interactive` additionally enables the
launch opt-in for explicit user interaction; it is not validated by this slice.
Every `-Smoke` run is read-only and launching-disabled regardless of the
requested mode. The M1 entry point and the audio/battery/media prototypes keep
their own profiles and flags.

## Validation

```powershell
powershell -NoProfile -File windows/scripts/Test-AppsService.ps1 -QtPrefix $qtPrefix
powershell -NoProfile -File windows/scripts/Test-AppsPrototype.ps1 -QtPrefix $qtPrefix
```

`Test-AppsService.ps1` stages only the pure state object, the frequency store,
its path policy, the upstream fzf/fuzzysort libraries and the fixture into Qt's
offscreen `qml.exe`. It rejects Quickshell imports, staging hash mismatches and
QML diagnostics. The 173 injected assertions cover:

- safe disabled construction and the preserved launcher members;
- disabled/scanning/failed/empty/ready transitions, including stale values
  before a completed scan and rejected shape failures;
- hidden-app exact/regex filters, invalid model entries and name/icon reads;
- favourite/frequency/name ordering and reactive frequency changes;
- default and special-prefix search, smart-case, whitespace normalization,
  terminal filtering and the fuzzysort configuration;
- equal-relevance frequency tie-breaking and search/query agreement;
- frequency persistence round trip, corrupt/wrong-shaped documents, invalid
  counts, memory-only operation, failed writes and path confinement;
- launch refusal without the opt-in, no executed entries during
  enumeration/search, explicit launch dispatch, frequency recording, foreign,
  invalid, terminal and removed entries, and disable clearing every projection.

`Test-AppsPrototype.ps1` runs the fixture, then disabled/read-only smoke on
every measured connected screen, then the original M1 bar/session regression.
Each smoke asserts the disabled mode leaves the native catalog facade, original
list and frequency store unconstructed; an enabled run loads the original
`AppList` and asserts read-only policy, a non-empty enumerated catalog or a
truthful empty/failed state, profile-confined frequency path, and consistent
search result counts. The smoke enters one fixed query through the host's own
state (the first letter of the first observed app, overridable with
`-AppsSearchQuery`), never through synthesized OS input, and it never launches
an application. Each run records source and staged hashes, initial/final state,
the search sample, logs and a PNG. Desktop identity (shell PIDs, work areas,
taskbar flags) is compared before and after.

Raw results are under `windows/.local/build/apps-validation-<timestamp>/`.

## Backend gaps

- `desktopentry_backend.cpp:158-187` returns an empty list on
  `CoInitializeEx`/`SHGetKnownFolderItem`/`BindToHandler` failure and logs a
  warning; there is no public scan-failure state. This slice reports such a scan
  as `empty` instead of inventing `failed` or a zero-app Windows install.
- `desktopentry_backend.cpp:334-344` uses only `command.first()` and the
  `shell:AppsFolder\` activation path; `runInTerminal` is ignored by
  `DesktopEntry::execute()` (`desktopentry.cpp:261-263`). Terminal entries are
  therefore unsupported launches here.
- `desktopentry.cpp:546-627` emits `applicationsChanged` for every completed
  scan; a rescan can change the list after launch selection. Membership is
  re-checked on every launch, and a removed entry is refused.
- `DesktopEntry.execute()` returns void and the backend logs failures only
  (`desktopentry_backend.cpp:277-330`), so a dispatched launch is not a
  confirmed start.

## Limits

- No application was launched by this slice's native validation. Launch
  policy, dispatch and frequency writes are fixture-validated only; real
  activation, per-command failure and `Interactive` mode remain untested.
- The fixed smoke query proves ranking and shell-state integration, not
  interactive typing, keyboard navigation or pointer selection.
- Admin/elevation, uninstall, AppActions, terminal launching and launcher
  actions/calculator/schemes/variants/wallpapers are outside this slice.
- No backend source, gitlink or `sources.lock.json` change is part of this
  slice.
