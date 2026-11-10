# Upstream sync

This record compares the two upstreams the port builds on, at exact revisions.
A branch name is a query, not a baseline. A classification is a review result,
not an adoption decision: an adopted change still needs its own pull request and
checks.

## Upstreams

| Layer | Repository | Branch compared | Pin |
| --- | --- | --- | --- |
| Shell interface | [caelestia-dots/shell](https://github.com/caelestia-dots/shell) | `main` | `caelestia` in [sources.lock.json](../sources.lock.json) |
| Windows backend | [nunreasonable/quickshell](https://github.com/nunreasonable/quickshell) | `windows` | `quickshell` in [sources.lock.json](../sources.lock.json) and the `windows/deps/quickshell` gitlink |
| Quickshell base | [outfoxxed/quickshell](https://git.outfoxxed.me/quickshell/quickshell) | `master` | Provenance only; the Windows backend preserves it |

`nunreasonable/quickshell` keeps `master` as its default branch, but its
Windows work is on `windows`. The original Quickshell `master` is a different
release line; this record notes its revision without treating it as a candidate
for the Windows pin.

## Classification

- Already adopted: the change is in the pinned tree.
- Compatible: the change can be applied as it is to a file the Windows staging
  keeps.
- Needs Windows adaptation: the change touches a file a Windows adapter
  replaces, a fork-modified backend file, or a path with no Windows equivalent.
  It must be re-applied or guarded.
- Intentionally deferred: the change only affects code the Windows staging or
  backend does not ship, such as Linux and Hyprland services, the lock screen,
  upstream CI and Nix inputs, or another release line.

## Staging and adaptation boundary

[`windows/shell/sources.json`](../shell/sources.json) is the only production
staging map; each key is a path in this repository and each value is the path it
is copied to in the installed tree. 118 files under
[`windows/shell/adapters/`](../shell/adapters/) are staged at those destinations,
so an adapter replaces an upstream file or adds a Windows-only one, and an
upstream edit to a replaced path never reaches the staged tree on its own. Port
such a change into the adapter and check the staged tree; a change to a copied
file is restaged with its local Windows edits.

## Review cadence

Review monthly, in the first working week. The repository maintainer owns the
review and the record. A review that finds no change still gets a dated section,
so a missing month is visible.

Resolve each moving branch immediately after fetching it:

```powershell
git ls-remote https://github.com/caelestia-dots/shell.git refs/heads/main
git ls-remote https://github.com/nunreasonable/quickshell.git refs/heads/windows
git ls-remote https://git.outfoxxed.me/quickshell/quickshell refs/heads/master

git fetch https://github.com/caelestia-dots/shell.git main
$shellHead = $(git rev-parse FETCH_HEAD)
git log --oneline <last recorded shell baseline>..$shellHead

git fetch https://github.com/nunreasonable/quickshell.git windows
$backendHead = $(git rev-parse FETCH_HEAD)
git log --oneline <last recorded backend baseline>..$backendHead

git merge-base --is-ancestor <last recorded baseline> <head>
```

An upstream commit counts as adopted only when its change is in the pinned
tree. A clean patch or an unchanged file path does not prove adoption.

Record each comparison by appending a new `## Comparison YYYY-MM-DD` section
below the last one. Do not rewrite an earlier section. Write the exact SHA of
every compared revision, including the downstream shell, the downstream backend
pin, each upstream head and each adopted baseline. A branch name may appear in
a fetch command but never as the compared revision. The baseline for the next
review is the adopted pin recorded in the last section, not the upstream head.

## Comparison 2026-11-10

Checked on 2026-11-10. The revisions were resolved with `git ls-remote` and
`gh api`, and the commit lists with `git fetch` into a scratch worktree.

| Item | Revision |
| --- | --- |
| Downstream shell, `origin/main` | `035f8ecbcbbbab63680a7b1f780164bf920f0b0e` |
| Shell upstream `main` | `fd630ffedd45eb31817e9a1726a0f567e79f65e2` |
| Shell adopted baseline | `4b1dae84b1b3b28bf486776ba30c1c1ec74fb64d` |
| Downstream backend pin | `1ea37421c335d41847a0b5f273b2d384212e8847` |
| Backend upstream `windows` | `282480c9ace42672c7c84e0f527568e5083b2ea9` |
| Backend adopted baseline | `e8ae0ef124b1c14b547c80d00422d2ffbd423d81` |
| Quickshell base `master` | `9b0f339b19057f4731bf3b48293307d7ef241671` |
| Quickshell base split point, v0.3.2 | `4f508be500dea6e5732cc3d50382a0048b17e7b1` |

The earlier audit baseline at preview.2 was shell
`699746045da7426c9df3e7baa85dc2d8d90b4f19` and backend
`747817bdfab55ff118af0550802e9528ee79eefd`. It is historical. This comparison
supersedes it and is not a release acceptance result.

Adoption was checked by hashing each changed file in the pinned tree against the
upstream parent and child blobs. No change in either range is already adopted.
The classes below are source-level only: no build, package or live desktop was
run for this record.

### Shell changes since 4b1dae84

12 commits on `caelestia-dots/shell` `main`.

| Revision | Change | Class | Note |
| --- | --- | --- | --- |
| `48b323fa` | Clear the lock password with Ctrl+U | Intentionally deferred | `modules/lock/` is not in the staging map; Windows uses the system lock screen. |
| `b9a15ba9` | Make GameMode options configurable | Intentionally deferred | The config node compiles, but the GameMode daemon that reads it applies Hyprland options and is not staged. |
| `bcbb5d51` | Match the drawer border radius to game mode | Needs Windows adaptation | Adds a `GameMode` import and lookup to the staged `ContentWindow.qml`; it needs the gameMode config property and a guard because the daemon is not staged. |
| `72f60b1d` | Sort unnamed Bluetooth devices last in the bar popout | Compatible | One comparator line in the file staged as `BluetoothContent.qml`; the adapter wrapper is unchanged. |
| `cb43fc71` | Sort unnamed Bluetooth devices last in Nexus pairing | Needs Windows adaptation | The upstream file is replaced by `windows/shell/adapters/modules/nexus/pages/bluetooth/BluetoothPairing.qml`; apply the order in the adapter. |
| `5cbf60e7` | Use absolute module imports | Compatible | Six staged files take the import edit; seven adapter-replaced files and two lock files need no change. |
| `80bd0021` | Fully qualify QML exposed types | Compatible | The plugin headers compile on Windows; reapply the edit to the locally modified headers and build the plugin. |
| `fd630ffe` | Clamp the dashboard tab index when the tab count changes | Compatible | `modules/dashboard/Content.qml` is staged unchanged and still matches the parent revision. |
| `b51fdb35`, `3628f561`, `8ba51e4b`, `f80a9807` | Upstream CI and Nix updates | Intentionally deferred | These touch upstream workflows and `flake.lock`, which this port does not use. |

### Backend changes since e8ae0ef

9 commits on `nunreasonable/quickshell` `windows`.

| Revision | Change | Class | Note |
| --- | --- | --- | --- |
| `7b33c8db` | Leave focus alone on an empty desktop and let windows draw their own title bar | Needs Windows adaptation | Adds `window_frame` and changes `window_manager.cpp`; the fork has no `window_frame` helper and keeps the `GetShellWindow` fallback in `repairFocus`. |
| `f264e6bf` | Add a DWM window thumbnail item | Compatible | New self-contained files; `src/windows/wayland/CMakeLists.txt` is unchanged from the parent. A build check still applies. |
| `16c799b0` | Walk scrolling columns with Super and the wheel | Needs Windows adaptation | Touches fork-modified keyboard, super-drag and tiling files; the fork has no wheel path. |
| `2974bdee` | Make popup windows frameless on Windows | Needs Windows adaptation | The fork sets `NoDropShadowWindowHint` in `popupwindow.cpp` but not `FramelessWindowHint`; add the guard beside it. |
| `07b161db` | Take scrolling width presets from the config | Needs Windows adaptation | The fork still uses the fixed `ScrollingLayout::presets()` list. |
| `6377e580` | Treat screenshot destinations that differ only by case as one file | Needs Windows adaptation | The fork's `screenshot_jobs.cpp` still keys on the absolute path; apply case folding to its removal map. |
| `a492a071` | Let the clipboard take a file | Needs Windows adaptation | The fork replaces the upstream clipboard with a history store and has no `copyFile`; add CF_HDROP support there. |
| `809540a6` | Build and test the Windows port on every push | Intentionally deferred | Upstream workflow only; this repository runs its own CI. |
| `282480c9` | List VPN connections through the RAS API | Needs Windows adaptation | New service plus CMake changes; the staged network page hands VPN management to Windows Settings, so a consumer would have to be staged first. |

### Quickshell base changes

The Windows backend splits from the original Quickshell at v0.3.2, commit
`4f508be500dea6e5732cc3d50382a0048b17e7b1`. The original `master` has 11
commits after that point. None is in the Windows branch, and all are
intentionally deferred: they belong to the 0.4 line or to Linux and Wayland
paths the Windows branch does not carry.

| Revision | Change |
| --- | --- |
| `9b0f339b` | Set the desktop file name before constructing the app |
| `3c5323bc` | Forward Wayland activation tokens on primary tray clicks |
| `5c4f4c71` | Discard greetd responses to cancelled sessions |
| `1039e2b9` | Call `pw_loop_enter` and `pw_loop_leave` on the SPA event loop |
| `2b4501a2` | Expose dependency metatypes in the light dependency target |
| `95a1f911` | Avoid a crash when screencopy captures a null screen |
| `18c95fae` | Emit `lockStateChanged` on unlock |
| `1c1cc915` | Include type namespaces in MOC'd members |
| `30a5d60a` | Trim lines in desktop entries when parsing |
| `4befab5b` | Follow workspace id changes in the Hyprland IPC |
| `d7ee6d12` | Emit row updates for rows changed only by identity in `ScriptModel` |

## Batch adoption 2026-11-10

Adopted in the #33 upstream batch pull request
(`feat/33-upstream-batch-1`): `fd630ffe`, `72f60b1d`, `cb43fc71` and
`80bd0021`.

`6377e580` is not adopted here. Its screenshot removal-map change is in the
pinned backend submodule, and the batch pull request does not move the backend
pin; `screenshot_jobs.cpp` at the pinned revision still keys removals on the
absolute path.
