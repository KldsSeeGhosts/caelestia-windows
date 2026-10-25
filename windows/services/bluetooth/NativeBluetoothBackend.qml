import QtQuick
import Quickshell.Bluetooth

// Loaded by URL only after Bluetooth.enabled. Referencing the
// Quickshell.Bluetooth singleton constructs the native WinRT backend: its worker
// thread starts after the first frame, watches the default adapter and paired
// devices and polls connected-device batteries. Construction sends no radio,
// discovery, pairing or connection command.
//
// The singleton does not publish the worker's initial adapter-scan completion
// (WinBluetooth::isScanned/scanned stay in C++), so this facade reports only
// construction. BluetoothService applies a bounded first-adapter observation and
// never labels a null adapter as a completed scan.
QtObject {
    id: root

    // Completing construction means the native facade exists; it does not mean
    // the worker finished its first adapter lookup.
    readonly property bool ready: true

    readonly property var adapter: Bluetooth.defaultAdapter
    readonly property var adapters: Bluetooth.adapters
    readonly property var devices: Bluetooth.devices
}
