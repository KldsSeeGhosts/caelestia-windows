# Upstream source

The clipboard overlay's presentation and the display-row model are adapted
from Omarchy's `quattro` clipboard:

- Repository: https://github.com/omacom/omarchy
- QML: `shell/plugins/clipboard/Clipboard.qml`
- History model: `shell/plugins/clipboard/ClipboardHistory.js`
- Retrieved by the user's Linux overlay on 2026-08-30; recorded here from
  https://github.com/KldsSeeGhosts/caelestia-hypr-dotfiles
  (`overlay/quickshell/modules/clipboard/`).

Omarchy is MIT-licensed. The copyright notice is retained in
[`LICENSE-MIT.txt`](LICENSE-MIT.txt).

The Caelestia presentation (search, preview card, footer shortcuts, clear
confirmation, motion) came from the user's Linux overlay. This Windows port
changes the following:

- History and capture are Windows' native clipboard history
  (`Windows.ApplicationModel.DataTransfer.Clipboard`) rather than a JSON file
  plus `wl-paste` watchers. There is no separate capture store.
- Paste, copy and open dispatch to `Caelestia.Windows.WindowsClipboard`
  instead of `modules/clipboard/scripts/entry-action.sh`. The overlay keeps no
  shell scripts.
- `ClipboardHistory.js` keeps the display-row classification and the bounded
  preview, but reads the native item shape (id, kind, text, image URL,
  timestamp) and adds Windows path and file-URL handling.
- The card is hosted in a `PanelWindow` overlay on the selected screen rather
  than a Wayland layer-shell window. The panel is hidden while the picker is
  closed, so it has no native window then.
