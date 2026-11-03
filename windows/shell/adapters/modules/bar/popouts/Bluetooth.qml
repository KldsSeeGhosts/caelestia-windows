import QtQuick
import qs.services

// Windows combined host wiring for the original bluetooth popout, matching the
// bounded bluetooth prototype host. The facade singleton is staged as
// WindowsBluetooth so its name never shadows this Bluetooth component type
// that the original popouts Content instantiates directly.
//
// The upstream content imports Quickshell.Bluetooth and reads the native
// singleton. Keep it behind a Loader gated by the facade's observation opt-in,
// so a disabled profile never constructs the WinRT adapter/device watchers even
// if the popout is opened. Controls follow the facade's control opt-in (off in
// the combined launcher), and the original settings button delegates to the
// Windows settings page exactly as reviewed in that slice.
Item {
    id: root

    required property PopoutState popouts

    // The Loader's implicit size follows the loaded item's actual size, which keeps
    // the upstream content's explicit `width: 300` (its implicitWidth would not).
    implicitWidth: loader.implicitWidth
    implicitHeight: loader.implicitHeight

    Loader {
        id: loader

        active: WindowsBluetooth.enabled
        sourceComponent: Component {
            BluetoothContent {
                popouts: root.popouts
                controlsEnabled: WindowsBluetooth.controlsEnabled
                settingsDelegatesToWindows: true
                actions: WindowsBluetooth
                settlingTimedOut: WindowsBluetooth.timedOutDevices
                onSettingsRequested: Qt.openUrlExternally(WindowsBluetooth.settingsUri)
            }
        }
    }
}
