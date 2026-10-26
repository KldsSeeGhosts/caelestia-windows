import QtQuick
import Quickshell
import qs.services

// Windows combined host wiring for the original bar tray, matching the bounded
// tray prototype host. The facade singleton is staged as WindowsTray so its
// name never shadows this Tray component type that the original Bar
// instantiates directly. The delegate list comes from the read-only facade
// instead of the native SystemTray model, item interactions follow the
// activation opt-in (off in the combined launcher) and a menu request routes
// through the facade, which refuses it while activation is disabled. The
// original geometry, spacing, expand behavior and ColouredIcon tinting are
// untouched in TrayContent.qml.
TrayContent {
    id: root

    sourceItems: WindowsTray.list
    itemInteractionsEnabled: WindowsTray.activationEnabled
    itemNativeMenuMode: WindowsTray.activationEnabled
    onItemMenuRequested: (item, x, y) => WindowsTray.openMenu(item, QsWindow.window, x, y)
}
