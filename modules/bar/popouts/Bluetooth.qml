pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Bluetooth
import Caelestia.Config
import Caelestia.I18n
import qs.components
import qs.components.controls
import qs.services
import qs.utils

ColumnLayout {
    id: root

    required property PopoutState popouts

    // Windows host: explicit control opt-in. Upstream behavior stays enabled by
    // default. A read-only host sets this false so no radio, discovery, connect,
    // pair or forget request can be sent, while the original disabled styling
    // and device list remain unchanged.
    property bool controlsEnabled: true

    // Windows host: pairing kinds that need a PIN or passkey have no shell UI.
    // The host sets this true so the original settings button delegates to the
    // host's explicit Windows Settings action instead of detaching a popout.
    // Upstream keeps the original detach behavior.
    property bool settingsDelegatesToWindows: false

    // Windows host: the bounded settling window can expire while the native
    // device still reports Connecting/Disconnecting. The service supplies the
    // affected device addresses so the original loading spinner stops without
    // cancelling or re-sending a request. Empty by default (upstream).
    property var settlingTimedOut: ({})

    // Windows host: guarded control service. When set, every radio, discovery,
    // connect and forget request is routed through its capability checks
    // instead of writing the native objects directly, and unpaired devices
    // delegate pairing to Windows Settings rather than pairing natively. Null
    // by default (upstream writes the objects directly).
    property var actions: null

    signal settingsRequested()

    // Unpaired devices stay clickable under a host service: the click delegates
    // to Windows Settings, never to native pairing.
    function canActOn(device): bool {
        if (!root.actions)
            return true;
        if (!device || device.paired !== true)
            return true;
        return device.connected ? root.actions.canDisconnect(device) : root.actions.canConnect(device);
    }

    function isSettlingTimedOut(device): bool {
        if (!device || !root.settlingTimedOut)
            return false;
        const key = typeof device.address === "string" ? device.address : "";
        return key !== "" && root.settlingTimedOut[key] === true;
    }

    width: 300
    spacing: Tokens.spacing.small

    StyledText {
        Layout.topMargin: Tokens.padding.medium
        Layout.rightMargin: Tokens.padding.extraSmall
        text: Tr.tr("Bluetooth")
        font: Tokens.font.body.builders.medium.weight(Font.Medium).build()
    }

    Toggle {
        label: Tr.trCtx("Enabled", "toggle label")
        checked: Bluetooth.defaultAdapter?.enabled ?? false
        controlsEnabled: root.controlsEnabled && (!root.actions || root.actions.canToggleRadio)
        toggle.onToggled: {
            if (!root.controlsEnabled)
                return;
            if (root.actions) {
                if (!root.actions.setRadioEnabled(checked))
                    checked = !checked;
                return;
            }
            const adapter = Bluetooth.defaultAdapter;
            if (adapter)
                adapter.enabled = checked;
        }
    }

    Toggle {
        label: Tr.trCtx("Discovering", "bluetooth adapter state")
        checked: Bluetooth.defaultAdapter?.discovering ?? false
        controlsEnabled: root.controlsEnabled && (!root.actions || root.actions.canSetDiscovering)
        toggle.onToggled: {
            if (!root.controlsEnabled)
                return;
            if (root.actions) {
                if (!root.actions.setDiscovering(checked))
                    checked = !checked;
                return;
            }
            const adapter = Bluetooth.defaultAdapter;
            if (adapter)
                adapter.discovering = checked;
        }
    }

    StyledText {
        Layout.topMargin: Tokens.spacing.small
        Layout.rightMargin: Tokens.padding.extraSmall
        text: {
            const devices = Bluetooth.devices.values;
            const connected = devices.reduce((total, d) => total + d.connected, 0);
            if (connected > 0)
                // TRANSLATORS: %n = total paired devices, %1 = how many of them are connected
                return Tr.trN("%n device available (%1 connected)", "%n devices available (%1 connected)", devices.length).arg(connected);
            return Tr.trN("%n device available", "%n devices available", devices.length);
        }
        color: Colours.palette.m3onSurfaceVariant
        font: Tokens.font.body.small
    }

    Repeater {
        model: ScriptModel {
            // Connected/paired devices first, then devices that report their own name, and unnamed ones last
            values: [...Bluetooth.devices.values].sort((a, b) => (b.connected - a.connected) || (b.paired - a.paired) || (!a.deviceName - !b.deviceName) || a.name.localeCompare(b.name)).slice(0, 5)
        }

        RowLayout {
            id: device

            required property BluetoothDevice modelData
            readonly property bool loading: !root.isSettlingTimedOut(modelData)
                && (modelData.state === BluetoothDeviceState.Connecting
                    || modelData.state === BluetoothDeviceState.Disconnecting)

            Layout.fillWidth: true
            Layout.rightMargin: Tokens.padding.extraSmall
            spacing: Tokens.spacing.small

            opacity: 0
            scale: 0.7

            Component.onCompleted: {
                opacity = 1;
                scale = 1;
            }

            Behavior on opacity {
                Anim {
                    type: Anim.DefaultEffects
                }
            }

            Behavior on scale {
                Anim {}
            }

            MaterialIcon {
                text: Icons.getBluetoothIcon(device.modelData.icon)
            }

            StyledText {
                Layout.leftMargin: Tokens.spacing.extraSmall
                Layout.rightMargin: Tokens.spacing.extraSmall
                Layout.fillWidth: true
                text: device.modelData.name
                elide: Text.ElideRight
            }

            MaterialIcon {
                visible: device.modelData.state === BluetoothDeviceState.Connected
                text: device.modelData.batteryAvailable ? Icons.getBatteryIcon(device.modelData.battery) : "battery_alert"
                color: device.modelData.batteryAvailable && device.modelData.battery < 0.2 ? Colours.palette.m3error : Colours.palette.m3onSurfaceVariant
            }

            StyledRect {
                id: connectBtn

                implicitWidth: implicitHeight
                implicitHeight: connectIcon.implicitHeight + Tokens.padding.extraSmall

                radius: Tokens.rounding.full
                color: Qt.alpha(Colours.palette.m3primary, device.modelData.state === BluetoothDeviceState.Connected ? 1 : 0)

                CircularIndicator {
                    anchors.fill: parent
                    running: device.loading
                }

                StateLayer {
                    color: device.modelData.state === BluetoothDeviceState.Connected ? Colours.palette.m3onPrimary : Colours.palette.m3onSurface
                    disabled: device.loading || !root.controlsEnabled || !root.canActOn(device.modelData)
                    onClicked: {
                        if (!root.controlsEnabled)
                            return;
                        if (root.actions) {
                            const target = device.modelData;
                            if (target.paired !== true)
                                root.settingsRequested();
                            else if (target.connected)
                                root.actions.disconnectDevice(target);
                            else
                                root.actions.connectDevice(target);
                            return;
                        }
                        device.modelData.connected = !device.modelData.connected;
                    }
                }

                MaterialIcon {
                    id: connectIcon

                    anchors.centerIn: parent
                    animate: true
                    text: device.modelData.connected ? "link_off" : "link"
                    color: device.modelData.state === BluetoothDeviceState.Connected ? Colours.palette.m3onPrimary : Colours.palette.m3onSurface

                    opacity: device.loading ? 0 : 1

                    Behavior on opacity {
                        Anim {
                            type: Anim.DefaultEffects
                        }
                    }
                }
            }

            Loader {
                visible: status === Loader.Ready
                asynchronous: true
                active: device.modelData.bonded
                sourceComponent: Item {
                    implicitWidth: connectBtn.implicitWidth
                    implicitHeight: connectBtn.implicitHeight

                    StateLayer {
                        radius: Tokens.rounding.full
                        disabled: !root.controlsEnabled || (root.actions !== null && !root.actions.canForget(device.modelData))
                        onClicked: {
                            if (!root.controlsEnabled)
                                return;
                            if (root.actions)
                                root.actions.forgetDevice(device.modelData);
                            else
                                device.modelData.forget();
                        }
                    }

                    MaterialIcon {
                        anchors.centerIn: parent
                        text: "delete"
                    }
                }
            }
        }
    }

    IconTextButton {
        Layout.fillWidth: true
        Layout.topMargin: Tokens.spacing.medium
        inactiveColour: Colours.palette.m3primaryContainer
        inactiveOnColour: Colours.palette.m3onPrimaryContainer
        verticalPadding: Tokens.padding.extraSmall
        text: Tr.tr("Open settings")
        icon: "settings"

        onClicked: {
            if (root.settingsDelegatesToWindows)
                root.settingsRequested();
            else
                root.popouts.detachRequested("bluetooth");
        }
    }

    component Toggle: RowLayout {
        required property string label
        property bool controlsEnabled: true
        property alias checked: toggle.checked
        property alias toggle: toggle

        Layout.fillWidth: true
        Layout.rightMargin: Tokens.padding.extraSmall
        spacing: Tokens.spacing.medium

        StyledText {
            Layout.fillWidth: true
            text: parent.label
        }

        StyledSwitch {
            id: toggle
            disabled: !parent.controlsEnabled
        }
    }
}
