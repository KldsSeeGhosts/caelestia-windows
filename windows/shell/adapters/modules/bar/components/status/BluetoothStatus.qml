pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Caelestia.Config
import qs.components
import qs.services
import qs.utils

// Windows status icon wiring. Upstream modules/bar/components/status/
// BluetoothStatus.qml reads Quickshell.Bluetooth directly, which constructs the
// native WinRT watcher even when no observation opt-in is set. Read the gated
// WindowsBluetooth facade instead: its native loader stays inactive unless
// CAELESTIA_WINDOWS_BLUETOOTH=1, so disabled production and smoke profiles never
// enumerate an adapter or paired devices.
Item {
    id: root

    required property color colour

    implicitWidth: layout.implicitWidth
    implicitHeight: layout.implicitHeight

    Behavior on implicitHeight {
        Anim {
            type: Anim.DefaultEffects
        }
    }

    ColumnLayout {
        id: layout

        spacing: Tokens.spacing.medium / 2

        // Bluetooth icon
        MaterialIcon {
            animate: true
            text: {
                if (!WindowsBluetooth.radioEnabled)
                    return "bluetooth_disabled";
                if (WindowsBluetooth.devices.some(d => d.connected))
                    return "bluetooth_connected";
                return "bluetooth";
            }
            color: root.colour
        }

        // Connected bluetooth devices
        Repeater {
            model: ScriptModel {
                values: WindowsBluetooth.devices.filter(d => d.state !== WindowsBluetooth.deviceDisconnected)
            }

            MaterialIcon {
                id: device

                required property var modelData

                animate: true
                text: Icons.getBluetoothIcon(modelData?.icon)
                color: root.colour
                fill: 1

                SequentialAnimation on opacity {
                    running: device.modelData?.state !== WindowsBluetooth.deviceConnected
                    alwaysRunToEnd: true
                    loops: Animation.Infinite

                    Anim {
                        from: 1
                        to: 0
                        duration: Tokens.anim.durations.large
                        easing: Tokens.anim.standardAccel
                    }

                    Anim {
                        from: 0
                        to: 1
                        duration: Tokens.anim.durations.large
                        easing: Tokens.anim.standardDecel
                    }
                }
            }
        }
    }
}
