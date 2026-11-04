pragma Singleton

import QtQuick

// Minimal config shape for Icons.qml's import. The fixture calls only the
// app-icon path, which reads no configuration.
QtObject {
    property var bar: ({
            tray: {
                iconSubs: {
                    values: []
                }
            },
            workspaces: {
                windowIcons: {
                    values: []
                }
            }
        })
}
