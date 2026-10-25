import QtQuick
import Quickshell.Services.SystemTray

// Loaded by URL only after Tray.enabled. Referencing the SystemTray singleton
// constructs the native tray host: TrayHost::instance() starts its prune timer
// immediately (host.cpp lines 139-147). After the first frame it starts
// Explorer interception, the toolbars/snapshot path and its timers unless
// QS_WINDOWS_TRAY_HOOK=0 (lines 172-201); this slice's launcher always sets that
// variable to 0, so interception does not run and no Explorer snapshot is
// scheduled. The 10-second prune timer still runs.
//
// The pinned SystemTray exposes items only (qml.hpp lines 16-18). There is no
// readiness, snapshot-complete, Explorer-generation or error property, so this
// facade adds no invented status: TrayService derives the state from the model
// it receives. Reading items never sends an activation, menu or scroll request.
QtObject {
    id: root

    readonly property var items: SystemTray.items
}
