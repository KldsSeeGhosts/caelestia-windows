pragma Singleton

import QtQuick

// Fake Quickshell.DesktopEntries for the apps fixture. applicationsChanged is
// the applications property's own change signal, exactly the signal the native
// backend emits after every AppsFolder scan, including one that returned an
// empty list (src/windows/desktopentry_backend.cpp:158-187). The desktop-entry
// manager outlives a QML engine, so a replacement catalog can be constructed
// while the singleton already holds the previous scan's applications.
QtObject {
    id: root

    property var applications: ({
        values: []
    })
    // The catalog's exact id matching, including the backend alias index.
    // `aliases` maps a window's app id/AUMID to the installed entry id. An
    // ambiguous executable basename is absent from it, exactly as the backend
    // publishes it after the scan.
    property var aliases: ({})
    property int byIdCalls: 0
    property string lastById: ""

    function byId(id): var {
        byIdCalls++;
        lastById = id;
        if (typeof id !== "string" || id.length === 0)
            return null;
        const key = id.toLowerCase();
        const target = String(aliases[key] ?? key).toLowerCase();
        for (const entry of applications.values ?? []) {
            if (entry && typeof entry.id === "string" && entry.id.toLowerCase() === target)
                return entry;
        }
        return null;
    }

    function completeScan(values): void {
        applications = {
            values: values
        };
    }
}
