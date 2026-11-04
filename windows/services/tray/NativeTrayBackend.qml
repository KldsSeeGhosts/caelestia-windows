import QtQuick
import Quickshell.Services.SystemTray

// Loaded only after the observation opt-in. Hook health is independent of the
// seeded item model and comes from the native host.
QtObject {
    id: root

    readonly property var items: SystemTray.items
    readonly property var hookCapability: SystemTray.hookCapability
}
