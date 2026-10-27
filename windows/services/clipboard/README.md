# Clipboard history

`caelestia:clipboard` opens Caelestia's Material 3 clipboard history picker over
Windows' own clipboard history. There is **no parallel capture store**: the
history, its ordering, password-manager exclusions, pinned items, size limits
and sync are Windows' clipboard history
(`Windows.ApplicationModel.DataTransfer.Clipboard`). If you clear or pin an item
in Win+V, the Caelestia picker sees the same state.

The default profile has the feature enabled but **no key bound**, so it does
nothing until you add a bind. Bind `Super+V` yourself; that replaces Windows'
own Win+V panel for that chord. See
[KEYBINDS.md](../../docs/KEYBINDS.md#shipped-default-keys).

```json
{
    "extends": "defaults",
    "binds": [
        {
            "keys": "Super+V",
            "action": "global",
            "name": "caelestia:clipboard",
            "description": "Open clipboard history"
        }
    ]
}
```

## Configuration

`windows.clipboard.enabled` in `config/shell.json` gates the feature (default
`true`). Unknown fields in `windows.clipboard` are ignored. Disabling it does
not construct the native type, does not read the history, and leaves the global
shortcut a no-op. The native instance is loader-owned and not a singleton:
disabling the feature explicitly shuts the backend down and then destroys it,
which stops the worker thread, cancels the in-flight read and any pending
paste, unsubscribes both WinRT events and drops all retained history and
preview ownership.

```json
{ "windows": { "clipboard": { "enabled": false } } }
```

Caelestia never enables Windows clipboard history itself. When Windows has it
off, the picker shows an empty state with a button that opens
`ms-settings:clipboard`.

## Where the code is

| Path | Role |
| --- | --- |
| `plugin/src/Caelestia/Windows/Clipboard/windowsclipboard.{hpp,cpp}` | QML facade (`Caelestia.Windows.WindowsClipboard`): presentation list, paste choreography, focus sampling, marked key injection |
| `plugin/src/Caelestia/Windows/Clipboard/windowsclipboardworker.{hpp,cpp}` | Dedicated MTA worker: every WinRT clipboard history call, static event handling, preview files |
| `windows/services/clipboard/ClipboardHistory.qml` | Gated `qs.services` facade staged as `services/ClipboardHistory.qml` |
| `windows/services/clipboard/NativeClipboardBackend.qml` | Loader-only wrapper that owns the native instance and binds the Quickshell cache directory as `cacheRoot` |
| `windows/services/clipboard/ClipboardOverlay.qml` | Ported picker, staged as `modules/clipboard/ClipboardOverlay.qml` |
| `windows/services/clipboard/ClipboardHistory.js` | Display-row classification and bounded preview |
| `windows/services/clipboard/ClipboardHistorySmoke.qml` | Light native smoke (model and gate only) |

## Backend contract

Native `WindowsClipboard` exposes:

- `items`: list of `{ id, kind ("text" | "image" | "other"), text, imageUrl,
  timestamp, timestampLabel, formats }`, newest first.
- `historyEnabled`, `status` (`initializing`, `loading`, `ready`, `disabled`,
  `denied`, `error`), `lastError`, `cacheRoot`.
- `refresh()`, `setActive(bool)`, `copy(id)`, `paste(id)`, `remove(id)`,
  `clear()`, `openItem(id)`, `requestImage(id)`, `openSettings()`.
- Signals: `itemsChanged`, `historyEnabledChanged`, `statusChanged`,
  `lastErrorChanged`, `imageReady(id, url)`, `pasteReady(id)`,
  `pasteDeferred(message)`, `operationFailed(operation, message)`,
  `openUrl(url)`.

`ClipboardHistory` (staged in `qs.services`) forwards these, adds the
`windows.clipboard.enabled` gate, and forwards `openUrl` to
`Qt.openUrlExternally`.

History is read only when the picker opens (`setActive(true)` plus
`refresh()`). While it is open, `Clipboard.HistoryChanged` and
`Clipboard.HistoryEnabledChanged` are coalesced into one refresh every 150 ms.
Closing the picker stops and invalidates the coalescing timer, so a scheduled
read cannot run while nothing is on screen; an asynchronous result that arrives
after close (or after a newer read) is dropped by its generation. A closed
picker reads nothing in the background. Every WinRT call runs on a dedicated
MTA worker thread, so the GUI thread never blocks on `GetHistoryItemsAsync`,
`GetTextAsync` or bitmap reads. The history read itself is asynchronous: its
operation handle is cancelled on shutdown and results for a superseded
generation are never published. Per-item `GetTextAsync`, bitmap and storage-item
reads are awaited in short slices on the worker thread and cancelled when the
picker closes, a newer refresh supersedes them, shutdown starts, or a 3 s bound
expires, so one stuck provider cannot hang the worker or a bounded GUI
shutdown. The worker's two event subscriptions are revoked independently and
only through a shared lifetime bridge, so a callback already in flight during
teardown cannot reach a destroyed worker.

The picker session is a shared atomic `{active, generation, stopping}` state.
The GUI updates it immediately on open, close and deactivation, not through the
queued `setActive`; the worker re-checks it between per-item reads and
again right before publishing. `snapshotReady` also carries the generation the
worker read, and the GUI applies the snapshot only when that generation is still
the current open session and `stopping` is false. A snapshot queued before a
close, or from a previous session before a reopen, is therefore dropped on the
GUI side as well. Every WinRT result used for
the snapshot (`Status()`, enumeration, item ids, timestamps, format and content
reads) is wrapped in `catch (hresult_error)` plus `catch (...)`; a failure
becomes the error snapshot or an `other` entry, and no exception crosses a Qt
slot or queued-call boundary.

Teardown is non-blocking on the GUI side. `shutdown()` sets the shared stopping
flag, queues the worker's WinRT `Cancel()`/release onto the worker thread and
then waits at most 2.5 s in total. Worker and thread cleanup is connected once,
before `start()`: `QThread::finished` runs `end()` and then deletes both with
`deleteLater`. If the bounded wait expires the GUI simply returns; the thread
finishes and self-deletes, and the already-detached bridge plus stopping flag
prevent late callbacks or publications.

`paste(id)` sets the item as clipboard content with
`SetHistoryItemAsContent` and requires the returned
`SetHistoryItemAsContentStatus::Success`; `AccessDenied` or `ItemDeleted` is
reported as a failure and never followed by an injection. The picker closes,
then after 240 ms (the 100 ms close animation and the focus guard's 75 ms focus
return) a synthetic Ctrl+V marked with the backend's `0x5153484B` injection
marker (`KeyboardHook::INJECTION_MARKER` in `windows/deps/quickshell/src/
windows/keyboard_hook.hpp`) is sent. The shell's low-level keyboard hook
ignores events that carry the marker, so the paste cannot re-enter Caelestia's
own hotkey or taskbar-suppression hooks.

The paste destination is an immutable `HWND`/process/thread identity captured
when the picker opens (before its panel takes focus), not a background sample
and not the foreground at paste time. Before injecting, the native type
verifies that the destination is still valid and still the verified foreground
window; if the shell process still holds focus it makes one bounded
`SetForegroundWindow` request, and if the destination did not regain focus, or
another application is foreground, the paste is cancelled with no injection.
Injecting is also delayed, with a bound, until all physical modifier keys are
released: a held Super would turn the chord into Win+Ctrl+V, and the injected
Ctrl-up must not release the user's own Ctrl. Because the item is already on
the clipboard after a successful `SetHistoryItemAsContent`, these cancellations
are not copy failures: the shell shows a Caelestia toast ("Copied. Press Ctrl+V
to paste") instead of cancelling silently. Copy, paste, delete and clear
failures that arrive after the picker closed are surfaced as error toasts on
the same `Toaster` surface the tiling service uses.

The picker opens on the Hypr-observed focused monitor when
`CAELESTIA_WINDOWS_HYPR=1` has resolved a focused monitor, and falls back to the
first Qt screen otherwise. It is one full-screen panel that follows the
selected screen; while the picker is closed its window is hidden and therefore
has no native window.

`copy(id)` restores its content without closing the picker (the UI closes it
for you). `remove(id)` calls `DeleteItemFromHistory`, `clear()` calls
`ClearHistory`, and both report failure when Windows returns `false` instead of
pretending the history changed. Windows decides what pinned items do in both
cases and whether the history is available at all, including password-manager
exclusions (`ExcludeClipboardContentFromMonitorProcessing`,
`CanIncludeInClipboardHistory`) and the 25-item history limit.

The public WinRT history item exposes only `Id`, `Timestamp` and `Content`.
There is no pin flag or pin operation, so the picker cannot show or change
pins; the item list is whatever Windows returns, and pinned items are kept by
Windows' own rules.

`openItem(id)` opens HTTP(S) URLs, single `file://` references and image
previews directly. Other text is written as `clipboard-<hash>.txt` inside this
instance's cache directory and opened with the default application. Opened text
files stay until the instance shuts down; an in-session prune never deletes
them.

## Images and cleanup

Each `WindowsClipboard` instance owns exactly one directory,
`<cacheRoot>/clipboard/<pid>-<random>`, created only after a valid fully
qualified local `cacheRoot` is known. Drive-relative (`C:relative`), bare drive
roots (`C:\`), UNC, `\\?\`, `\\.\` and relative roots are refused. The directory
holds both previews and explicitly opened text files; there are no shared
`preview/` or `open/` directories, and shutdown does not depend on a per-file
ownership set. Image previews are lazy: nothing is read until the open picker
lists an image item. The worker reads the bitmap, writes it into the instance
directory with a content-hash name, and exposes a `file://` URL. Previews
survive a refresh only while their item is still in the history; `remove()` and
a failed/empty refresh delete them. Previews larger than 64 MiB are not
materialized; copy/paste of that item still works.

Every create and write first verifies that the instance directory, the
`clipboard` parent and the cache root are real directories without
`FILE_ATTRIBUTE_REPARSE_POINT`. A junction, symlink or replaced path at any
level is a no-op with a fixed log message and no clipboard-derived path.
Deletion keeps the directory identity instead of trusting a validated path: it
opens the cache root, the `clipboard` parent and the candidate with
`FILE_FLAG_OPEN_REPARSE_POINT`, rejects reparse points through
`GetFileInformationByHandleEx(FileAttributeTagInfo)`, verifies each child
against its parent's own volume serial and 128-bit file ID, and deletes the
held directory and its verified direct children by handle
(`SetFileInformationByHandle` with `FileDispositionInfoEx` POSIX semantics,
falling back to `FileDispositionInfo`). A directory or ancestor swapped for a
junction between validation and deletion therefore cannot redirect it; on any
identity doubt the entry is skipped. Cleanup never recurses: the cache is flat,
so it enumerates only the direct files of the held instance directory, deletes
only regular files without a reparse point, and skips every other entry.
`QFileInfo::isSymLink()` is not the safety check: Qt does not report NTFS
junctions as symlinks. At startup the new instance applies the same layout
and flat-delete rules to sibling `<pid>-*` directories, only when that pid is
not a running process; a live sibling or any junction is never touched. A
crashed session is therefore collected by the next start, while an orderly
shutdown leaves nothing behind.

Clipboard contents are never logged. WinRT `hresult_error::message()` is never
logged or shown in a toast: failures use fixed operation copy plus the numeric
HRESULT, for example `Couldn't read clipboard history (0x80070005)`. The only
text this feature writes to disk is an explicit "open as text file" action and
the image preview files above.

## Attribution

The presentation and display-row model are adapted from Omarchy's `quattro`
clipboard (MIT, David Heinemeier Hansson) via the user's Linux Caelestia
overlay. See [upstream/SOURCE.md](upstream/SOURCE.md) and
[upstream/LICENSE-MIT.txt](upstream/LICENSE-MIT.txt).

## Test

`windows/scripts/Test-ClipboardHistory.ps1` stages the installed shell graph in
a temporary profile and runs `ClipboardHistorySmoke.qml` with the built
`qs.exe`. It checks the display-row model (search past the bounded preview,
filtered ids, output limits, entry classification, selection preservation by
item id), the `windows.clipboard.enabled` gate, that disabling the option emits
the native `aboutToShutdown` reset (cancelling the worker, events and pending
paste), and that the native C++ instance itself is destroyed rather than
outliving the loader (the runner asserts the destructor's marker line). The
script also runs the small `clipboard-logic-tests` executable built with the
plugin, which covers the `SetHistoryItemAsContent` status decision, the shared
session state (immediate deactivation, stale-read rejection, reopen and newer
read invalidation) and the GUI snapshot gate: a snapshot queued while active is
dropped when the picker closes before it is processed, reopening does not revive
it, and a current-generation snapshot still applies. It also covers strict cache
roots (`C:relative`, bare drives, UNC, device and relative paths are refused)
and the per-instance cache boundary with real `mklink /J` junctions: an
instance-directory junction, a nested junction inside the instance directory and
a junction replacing the `clipboard` parent all leave outside sentinel files
untouched, while ordinary flat files are still deleted. The held-handle
transaction is covered separately: a junction swapped in after validation is
not followed, the validated directory object is deleted by handle instead of
the junction target, and a same-named decoy in the target is refused because
its file identity does not match. Shutdown before a cache
root is set leaves sentinel files in the working directory and a temp directory
untouched; cleanup removes only the configured instance directory, and a live
sibling's directory survives while a dead sibling's is collected. The logic
test runs with its disposable run directory as the working directory, never the
repository, worktree, install prefix or user profile. It never opens the
picker, so it does not read, clear or modify the real clipboard history; the
enabled case can construct the native type, whose only WinRT call in that state
is a read-only `Clipboard.IsHistoryEnabled()`.

## Live verification still needed

- Whether this unpackaged process receives `GetHistoryItemsAsync` results or
  `AccessDenied` on the target Windows build. The UI reports `denied` honestly
  instead of showing an empty list as success.
- Whether `Clipboard.HistoryChanged` / `HistoryEnabledChanged` fire for an
  unpackaged desktop process and update an open picker.
- Paste behaviour into a focused application, including focus return after the
  close animation, the marked Ctrl+V against the shell and supervisor hooks,
  and the "Copied. Press Ctrl+V to paste" toast when a modifier is still held
  or the destination loses focus.
- The Windows off/on empty state against a real `ms-settings:clipboard` toggle,
  and whether `ClearHistory` leaves pinned items.
- Image previews for a real screenshot, and the cache cleanup on removal.
