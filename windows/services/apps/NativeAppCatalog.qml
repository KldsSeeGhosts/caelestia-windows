import QtQuick
import Quickshell

// Thin native wrapper over Quickshell.DesktopEntries.
//
// Loaded by the Apps facade through a Loader that is active only after the
// CAELESTIA_WINDOWS_APPS opt-in. Referencing DesktopEntries constructs the
// shared desktop-entry manager, starts the Windows AppsFolder enumeration on
// the background pool and begins Start menu path monitoring
// (windows/deps/quickshell/src/core/desktopentry.cpp:420-447,
// src/windows/desktopentry_backend.cpp:142-156). It does not launch anything.
//
// The pinned public API has no scan-result flag: `applicationsChanged` fires
// after every completed scan, including one where the native scan returned an
// empty list because COM or the Apps folder failed
// (src/windows/desktopentry_backend.cpp:158-187). `scanCompleted` therefore
// records only that a scan finished; `scanError` stays empty unless a caller
// injects a known failure, because the backend never reports one.
QtObject {
    id: root

    readonly property var applications: DesktopEntries.applications

    property bool scanCompleted: false
    property string scanError: ""

    readonly property Connections scan: Connections {
        target: DesktopEntries
        function onApplicationsChanged(): void {
            root.scanCompleted = true;
        }
    }

    // The only native launch call in this slice. Enumeration/search read
    // `applications` and never reach this function.
    function execute(entry): bool {
        if (!entry || typeof entry.execute !== "function")
            return false;
        entry.execute();
        return true;
    }
}
