pragma Singleton

import QtQuick
import Quickshell

// Only disabled image/asset loaders reference this contract. The ordinary M1
// session GIF and the notification empty-state picture are unavailable; return
// an empty path without logging an error so a bounded host can render its own
// empty state through the original component.
QtObject {
    readonly property string home: Quickshell.env("USERPROFILE").replace(/\\/g, "/")

    function absolutePath(path: string): string {
        return "";
    }
}
