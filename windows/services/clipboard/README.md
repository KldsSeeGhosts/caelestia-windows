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
shortcut a no-op.

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
| `windows/services/clipboard/NativeClipboardBackend.qml` | Loader-only wrapper that constructs the native singleton and binds the profile cache directory |
| `windows/services/clipboard/ClipboardOverlay.qml` | Ported picker, staged as `modules/clipboard/ClipboardOverlay.qml` |
| `windows/services/clipboard/ClipboardHistory.js` | Display-row classification and bounded preview |
| `windows/services/clipboard/ClipboardHistorySmoke.qml` | Light native smoke (model and gate only) |

## Backend contract

Native `WindowsClipboard` exposes:

- `items`: list of `{ id, kind ("text" | "image" | "other"), text, imageUrl,
  timestamp, timestampLabel, formats }`, newest first.
- `historyEnabled`, `status` (`initializing`, `loading`, `ready`, `disabled`,
  `denied`, `error`), `lastError`, `cacheDirectory`.
- `refresh()`, `setActive(bool)`, `copy(id)`, `paste(id)`, `remove(id)`,
  `clear()`, `openItem(id)`, `requestImage(id)`, `openSettings()`.
- Signals: `itemsChanged`, `historyEnabledChanged`, `statusChanged`,
  `lastErrorChanged`, `imageReady(id, url)`, `pasteReady(id)`,
  `operationFailed(operation, message)`, `openUrl(url)`.

`ClipboardHistory` (staged in `qs.services`) forwards these, adds the
`windows.clipboard.enabled` gate, and forwards `openUrl` to
`Qt.openUrlExternally`.

History is read only when the picker opens (`setActive(true)` plus
`refresh()`). While it is open, `Clipboard.HistoryChanged` and
`Clipboard.HistoryEnabledChanged` are coalesced into one refresh every 150 ms.
A closed picker reads nothing in the background. Every WinRT call runs on a
dedicated MTA worker thread, so the GUI thread never blocks on
`GetHistoryItemsAsync`, `GetTextAsync` or bitmap reads.

The picker opens on the Hypr-observed focused monitor when
`CAELESTIA_WINDOWS_HYPR=1` has resolved a focused monitor, and falls back to the
first Qt screen otherwise. It is one full-screen panel that follows the
selected screen; while the picker is closed its window is hidden and therefore
has no native window.

`paste(id)` sets the item as clipboard content with
`SetHistoryItemAsContent`, tells the picker to close, waits 240 ms for the
100 ms close animation and the focus guard's 75 ms focus return, then sends a
synthetic Ctrl+V marked with the backend's `0x5153484B` injection marker
(`KeyboardHook::INJECTION_MARKER` in `windows/deps/quickshell/src/windows/
keyboard_hook.hpp`). The shell's low-level keyboard hook ignores events that
carry the marker, so the paste cannot re-enter Caelestia's own hotkey or
taskbar-suppression hooks. If Windows still holds the shell process foreground,
the native type makes one bounded `SetForegroundWindow` attempt to the last
external window before injecting.

`copy(id)` restores its content without closing the picker (the UI closes it
for you). `remove(id)` calls `DeleteItemFromHistory`, `clear()` calls
`ClearHistory`. Windows decides what pinned items do in both cases and whether
the history is available at all, including password-manager exclusions
(`ExcludeClipboardContentFromMonitorProcessing`,
`CanIncludeInClipboardHistory`) and the 25-item history limit.

The public WinRT history item exposes only `Id`, `Timestamp` and `Content`.
There is no pin flag or pin operation, so the picker cannot show or change
pins; the item list is whatever Windows returns, and pinned items are kept by
Windows' own rules.

`openItem(id)` opens HTTP(S) URLs, single `file://` references and image
previews directly. Other text is written to `clipboard/open/` under the profile
cache and opened with the default application; that directory keeps only the
most recently opened text file.

## Images and cleanup

Image previews are lazy: nothing is read until the open picker lists an image
item. The worker reads the bitmap, writes it under
`<Quickshell.cacheDir>/clipboard/preview/` (the profile cache) with a
content-hash name, and exposes a `file://` URL. Previews survive a refresh only
while their item is still in the history; `remove()` and a failed/empty refresh
delete them, and files older than a day are pruned at worker start and when the
cache directory changes. Previews larger than 64 MiB are not materialized;
copy/paste of that item still works.

Clipboard contents are never logged. The only text this feature writes to disk
is an explicit "open as text file" action and the image preview files above.

## Attribution

The presentation and display-row model are adapted from Omarchy's `quattro`
clipboard (MIT, David Heinemeier Hansson) via the user's Linux Caelestia
overlay. See [upstream/SOURCE.md](upstream/SOURCE.md) and
[upstream/LICENSE-MIT.txt](upstream/LICENSE-MIT.txt).

## Test

`windows/scripts/Test-ClipboardHistory.ps1` stages the installed shell graph in
a temporary profile and runs `ClipboardHistorySmoke.qml` with the built
`qs.exe`. It checks the display-row model (search past the bounded preview,
filtered ids, output limits, entry classification) and the
`windows.clipboard.enabled` gate, including that disabling the option unloads
the native type. It never opens the picker, so it does not read, clear or
modify the real clipboard history; the enabled case can construct the native
type, whose only WinRT call in that state is a read-only
`Clipboard.IsHistoryEnabled()`.

## Live verification still needed

- Whether this unpackaged process receives `GetHistoryItemsAsync` results or
  `AccessDenied` on the target Windows build. The UI reports `denied` honestly
  instead of showing an empty list as success.
- Whether `Clipboard.HistoryChanged` / `HistoryEnabledChanged` fire for an
  unpackaged desktop process and update an open picker.
- Paste behaviour into a focused application, including focus return after the
  close animation, and the marked Ctrl+V against the shell and supervisor
  hooks.
- The Windows off/on empty state against a real `ms-settings:clipboard` toggle,
  and whether `ClearHistory` leaves pinned items.
- Image previews for a real screenshot, and the cache cleanup on removal.
