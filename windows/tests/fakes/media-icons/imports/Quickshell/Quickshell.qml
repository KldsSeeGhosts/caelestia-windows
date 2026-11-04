pragma Singleton

import QtQuick

// Records the key and fallback the production code would request from
// Quickshell's icon provider, without loading an image provider offscreen.
QtObject {
    function iconPath(icon, fallback) {
        return "image://icon/" + icon + (fallback === undefined || fallback === "" ? "" : "?fallback=" + fallback);
    }
}
