import QtQuick
import qs.services

// Windows combined host wiring for the original bluetooth popout, matching the
// bounded bluetooth prototype host. The facade singleton is staged as
// WindowsBluetooth so its name never shadows this Bluetooth component type
// that the original popouts Content instantiates directly (the status icon
// keeps using the native Quickshell.Bluetooth singleton, as upstream).
// Controls follow the facade's control opt-in (off in the combined launcher),
// and the original settings button delegates to the Windows settings page
// exactly as reviewed in that slice.
BluetoothContent {
    controlsEnabled: WindowsBluetooth.controlsEnabled
    settingsDelegatesToWindows: true
    actions: WindowsBluetooth
    settlingTimedOut: WindowsBluetooth.timedOutDevices
    onSettingsRequested: Qt.openUrlExternally(WindowsBluetooth.settingsUri)
}
