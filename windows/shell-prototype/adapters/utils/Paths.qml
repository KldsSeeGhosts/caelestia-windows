pragma Singleton

import QtQuick
import Quickshell

// Only the disabled session GIF loader references this contract.
QtObject {
    readonly property string home: Quickshell.env("USERPROFILE").replace(/\\/g, "/")

    function absolutePath(path: string): string {
        console.error("M1: Session GIF paths are unavailable; no asset was loaded.");
        return "";
    }
}
