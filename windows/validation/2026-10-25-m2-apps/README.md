# M2 app catalog and search prototype, 2026-10-25

This archive records ERM-505's bounded, default-off app catalog/search slice on
`t3/windows-app-catalog-search`. It enumerates the real Windows AppsFolder
catalog, renders the original Caelestia launcher app list and search bar, and
keeps every launch behind a separate opt-in. **No application was launched** by
this validation. ERM-505 remains **In Progress**.

## Sources and runtime

- Clean root `7ae03d7106e9b0fc144ee9e51ebdf4d45db7db1d` (`sourceDirty=false`
  in every recorded run).
- Backend `1401042969e4b7ab3cfb314fc76945ab081db3de`; gitlink and
  `windows/sources.lock.json` agree. This slice changes no backend source,
  gitlink or pin.
- Windows 11 `10.0.26300.0`, Qt 6.11.2, clang-cl 20.1.8. The shared incremental
  native build record is
  `3FA201EE45FC755B663FF122090B617D222BBFD99352B18F490B003F0C14FED1`
  (`windows/.local/build/logs/build.json`, source `d9cdcf9a`, backend
  `14010429`). This slice adds QML/scripts only, so no native rebuild was done.
- Primary `\\.\DISPLAY1` at native 150%, 3840x2160, origin 0,0. Secondary
  `\\.\DISPLAY2` at native 175%, 3840x2160, origin -3840,0.
- Prototype executable SHA-256
  `22B69FFE0523F8FFDB86C22E1669A36B2C8DCAEA97B19754000EC7455345AF22`;
  profile config SHA-256
  `6FC8F8B80AF9D45A49A4737AF51B8C43A11B97E1B59A82468F31AB4C779C6F65`.

## Delivered scope

[`AppsService.qml`](../../services/apps/AppsService.qml) is a pure QtObject with
no Quickshell import. It separates `disabled`, `scanning`, `empty`, `failed` and
`ready` states, preserves the original `search`/`query`/`list`/`keys`/`weights`
contract and the `@i/@c/@d/@e/@w/@g/@k/@t` prefixes, and orders results with
the upstream fzf/smart-case (or fuzzysort) libraries, favourites, frequency and
name. [`NativeAppCatalog.qml`](../../services/apps/NativeAppCatalog.qml) wraps
`DesktopEntries`; the native AppsFolder scan starts only after
`CAELESTIA_WINDOWS_APPS=1`.

[`AppFrequencyStore.qml`](../../services/apps/AppFrequencyStore.qml) replaces the
excluded AppDb/SQLite store with a versioned JSON document. The real
[`FileAppFrequencyStore.qml`](../../services/apps/FileAppFrequencyStore.qml)
writes it through `FileView`'s atomic `QSaveFile` path at
`$CAELESTIA_STATE_DIR/apps-frequencies.json`; path policy
([`AppStoragePath.js`](../../services/apps/AppStoragePath.js)) rejects empty,
relative, UNC and traversing roots, with no HOME/XDG fallback.

The bounded [host](../../apps-prototype/README.md) stages the original
`AppList.qml`, `AppItem.qml` and `SearchBar.qml` plus their original control
closure. `AppList` gained one Windows-localized `appsOnly` property (default
`false`) so the host never activates the action/calculator/scheme/variant
providers; inert adapters satisfy the list's static declarations and start no
process. The full launcher, wallpapers, `Apps.qml`'s AppDb dependency and every
shell controller stay unloaded.

Launching requires the separate `CAELESTIA_WINDOWS_APP_LAUNCH=1`; smoke always
forces it off. Terminal entries are an explicit unsupported launch because the
Linux `wrap_term_launch.sh` wrapper does not exist and `DesktopEntry.execute()`
ignores `runInTerminal`. Enumeration and search never launch. The backend exposes
no scan result or per-command outcome
([gaps](../../audits/M2-APPS-BACKEND-GAPS.md)), so a native scan failure reads as
`empty`, and a permitted launch is a dispatched request, not a confirmed start.

## Results

| Check | Observed result | Evidence |
| --- | --- | --- |
| Offscreen app adapter | 173 assertions, 0 diagnostics, 0 native imports | [result](fixture/result.json), [staged fixture](fixture/AppsServiceTest.qml) |
| Disabled at 150% (primary) | Pass; no native facade, store or original list; 0 apps | [result](apps-disabled-screen0/result.json), [capture](apps-disabled-screen0/capture.png) |
| Read-only at 150% (primary) | Pass; `ready`, 153 applications, query `A` → 19 results, list count 19 | [result](apps-readonly-screen0/result.json), [capture](apps-readonly-screen0/capture.png) |
| Disabled at 175% (secondary) | Pass; no native facade, store or original list; 0 apps | [result](apps-disabled-screen1/result.json), [capture](apps-disabled-screen1/capture.png) |
| Read-only at 175% (secondary) | Pass; `ready`, 153 applications, query `A` → 19 results, list count 19 | [result](apps-readonly-screen1/result.json), [capture](apps-readonly-screen1/capture.png) |
| Profile frequency read | Pass; harness document for `{1ac14e77-…}\appverif.exe` (count 99) put that entry first while the other 152 remained | [result](apps-frequency-read/result.json) |
| Corrupt frequency document | Pass; `{ not json` was ignored and the catalog stayed `ready` with 153 applications | [result](apps-corrupt-frequency/result.json) |
| Original M1 regression | Pass | [result](m1-regression/result.json), [capture](m1-regression/capture.png) |
| Media service fixtures | Pass; 148 assertions | [console output](shared-regressions/media-service.json) |
| Battery service fixtures | Pass; 128 assertions | [console output](shared-regressions/battery-service.json) |

The first six applications in the 150% read-only run were Application Verifier
(WOW), Application Verifier (X64), Bloodborne, BlueBubbles, Calculator and
Camera. The fixed smoke query is the first letter of the first observed
application (`A`), entered through the host's own search-bar state, never through
synthesized OS input. Search results for `A` began NVIDIA App, Quick Assist,
Power Automate, MSI Afterburner, Sample UWP Apps and Tools for UWP Apps; every
recorded icon was a non-empty `appicon:` value. The six primary results and the
initial/final snapshots are in the [matrix](matrix.json) and each `result.json`.

Each run asserted: launch disabled, zero launch requests, zero dispatched
launches, no launch-refusal record, terminal launch unsupported, a persistent
frequency store whose path is inside the isolated profile's `state` directory,
and consistency between the original list's `count` and the search result count.
Every app run recorded exactly one initial and one final snapshot plus one search
sample. `CAELESTIA_APPS_SCREEN/INITIAL/SEARCH/FINAL/CAPTURE/PASS` markers, source
and staged hashes, staged source manifests and logs are archived per run.

## Preserved state

[Desktop before](desktop-before.json) and [after](desktop-after.json) preserve
Explorer PID 9252, KSG Shell PID 24108, both physical monitor/work rectangles,
the taskbar state (`stateFlags=1`, auto-hide, not always-on-top) and the existing
foreground state. A `qs` process from another agent's concurrent smoke was
present in the after snapshot; the harness compares Explorer/KSG, work areas and
taskbar flags and waits for its own child to exit instead of killing or claiming
another agent's process. No taskbar, tiling, autostart, power, credential or
security setting changed.

No pointer or keyboard input was synthesized. No application was launched, and
the frequency file was written only by the harness (then removed) to prove the
read path; the prototype itself only read it. Tray, notifications, network,
Bluetooth, brightness, media transport, session actions and shell controllers
remained unconstructed. The backend retains ordinary instance bookkeeping,
own-window desktop support and stale-AppBar startup cleanup as documented for
M1.

## Commands

Native PowerShell from the repository root:

```powershell
$devRoot = Join-Path $env:LOCALAPPDATA 'caelestia-dev'
$qtPrefix = "$devRoot\Qt\6.11.2\msvc2022_64"
$buildRoot = 'D:\AiStack\caelestia-windows\windows\.local\build'
powershell -NoProfile -File windows/scripts/Test-AppsService.ps1 `
    -QtPrefix $qtPrefix -BuildRoot $buildRoot
powershell -NoProfile -File windows/scripts/Test-AppsPrototype.ps1 `
    -QtPrefix $qtPrefix -BuildRoot $buildRoot
powershell -NoProfile -File windows/scripts/Test-MediaService.ps1 `
    -QtPrefix $qtPrefix -BuildRoot $buildRoot
powershell -NoProfile -File windows/scripts/Test-BatteryService.ps1 `
    -QtPrefix $qtPrefix -BuildRoot $buildRoot
```

The shared native build was reused as-is; nothing in it was rebuilt or deleted.
Raw results are under
`windows/.local/build/apps-validation-20261025-180648-838/` and the per-test
logs under `windows/.local/build/logs/`. [archive.ps1](archive.ps1) copies the
artifacts referenced by the validation result without rewriting them;

[artifacts.sha256.json](artifacts.sha256.json) identifies the 49 archived files.

## Remaining acceptance

- **No native launch.** Explicit dispatch, app activation, focus, failure and
  recovery are fixture-validated only. The backend returns no per-command
  result, so even a permitted request cannot be called a successful start.
- **Interactive mode** (`-AppsMode Interactive`) is an unvalidated opt-in. It
  sets the launch opt-in; none of its typing/pointer/keyboard navigation or
  launch paths were exercised here.
- **Terminal entries** remain unsupported launches. No Windows terminal policy
  exists in this slice.
- **Native scan failure** surfaces as `empty` because the pinned backend has no
  scan-result API; a real denied/failed AppsFolder enumeration was not
  observed.
- The smoke query is fixed and applied through shell state, so interactive
  search latency, scrolling, selection and Enter dispatch are untested.
- Admin/elevation, uninstall, `AppActions`, launcher actions/calculator/schemes/
  variants/wallpapers and a full launcher window are out of scope.
- M1 checks here are smoke regressions, not renewed input/transparency
  acceptance. No Linux build, full-shell release or remote CI pass is claimed.

## Review addendum

An independent review of `bb93a9f0` found two defects, fixed in the follow-up
commit:

1. The original `AppItem` sets `screenState.launcher = false` on every click,
   including a refused ReadOnly launch. The bounded host stayed visible, but
   `AppList` stopped syncing its model, so later typing showed stale results.
   The host now applies the original dismiss/reopen lifecycle immediately:
   it clears the query and reopens the launcher state.
2. `FileAppFrequencyStore` reported success as soon as `FileView.setText()`
   returned, although the atomic write completes asynchronously. Asynchronous
   storage now counts a write only after `saved`; `saveFailed` sets
   `lastError`. The fixture covers this through a fake asynchronous storage;
   a real unwritable-file failure on the native `FileView` remains untested.

Results on the dirty follow-up tree: 177 fixture assertions;
`Test-AppsPrototype.ps1` passed all eight records
(`apps-validation-20261025-181856-935`). No application was launched.
