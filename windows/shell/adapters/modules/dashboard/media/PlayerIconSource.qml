import QtQuick
import qs.utils

// The Windows media backend resolves each player's desktopEntry at runtime:
// a lowercased AUMID for packaged apps, an executable path for desktop apps,
// or the raw id when neither resolves (#254, backend PR #59). Resolving that
// key through the app-icon path keeps the key on a heuristic miss, so a
// desktop player's executable reaches Quickshell's direct-path icon provider.
QtObject {
    id: root

    property var player: null

    readonly property string desktopEntry: {
        const entry = root.player?.desktopEntry;
        return typeof entry === "string" ? entry : "";
    }
    readonly property string source: Icons.getAppIcon(root.desktopEntry, "image-missing")
}
