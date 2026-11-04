pragma Singleton

import QtQuick

// Records the key the production code requests from Quickshell's icon
// provider, without loading an image provider offscreen. An unresolved key is
// served by the fallback, as the real provider does.
QtObject {
    function iconPath(icon, fallback) {
        if (icon === undefined || icon === "")
            return "image://icon/" + fallback;
        return "image://icon/" + icon + "?fallback=" + fallback;
    }
}
