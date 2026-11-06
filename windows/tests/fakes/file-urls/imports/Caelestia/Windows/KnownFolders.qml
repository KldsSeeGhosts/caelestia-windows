pragma Singleton

import QtQuick

QtObject {
    property string pictures: "D:/SyntheticProfile/Pictures"
    property string videos: "D:/SyntheticProfile/Videos"
    signal imagesProbed(string path, bool found)

    function normalizePath(path): string {
        return String(path || "").replace(/\\/g, "/");
    }

    // Paths.qml calls this during startup. The fixture intentionally records no
    // profile paths and does not probe the host filesystem.
    function probeImages(path): void {
        imagesProbed(path, false);
    }
}
