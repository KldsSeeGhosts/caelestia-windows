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

    function completeScan(values): void {
        applications = {
            values: values
        };
    }
}
