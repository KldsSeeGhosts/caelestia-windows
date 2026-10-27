pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Caelestia.Config
import Caelestia.I18n
import qs.components
import qs.components.controls
import qs.services
import qs.utils
import qs.modules.nexus.common

// Windows adaptation of modules/nexus/pages/BluetoothPage.qml.
//
// Upstream reads Bluetooth.defaultAdapter/Bluetooth.devices and writes
// adapter.enabled, adapter.discoverable and adapter.pairable. The pinned
// Windows backend builds no Quickshell.Bluetooth module, and its WinRT
// adapter/device objects do not expose discoverable, pairable, trusted,
// blocked or wake settings (the native setters warn and change nothing), so
// those four upstream toggles would silently do nothing. This page keeps the
// upstream layout for the radio, the paired-device list and the pair action,
// and replaces the unsupported toggles with one honest row that opens the
// Windows Bluetooth settings page, which owns discoverability and PIN pairing.
// Radio and connection requests still require the service's own control
// opt-in, so a read-only run exposes no writes.
PageBase {
    id: root

    readonly property bool radioOn: WindowsBluetooth.radioEnabled
    readonly property var savedDevices: [...WindowsBluetooth.devices].filter(device => device && device.bonded === true).sort((a, b) => (b.connected - a.connected) || (a.name ?? "").localeCompare(b.name ?? ""))

    title: Tr.tr("Connected devices")

    Component.onCompleted: if (root.visible)
        WindowsBluetooth.startDiscovery()
    Component.onDestruction: WindowsBluetooth.stopDiscovery()
    onVisibleChanged: {
        if (root.visible && WindowsBluetooth.canSetDiscovering)
            WindowsBluetooth.startDiscovery();
        else if (!root.visible)
            WindowsBluetooth.stopDiscovery();
    }

    ColumnLayout {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        width: root.cappedWidth
        spacing: Tokens.spacing.extraSmall / 2

        ToggleRow {
            first: true
            text: Tr.tr("Bluetooth")
            font: Tokens.font.body.medium
            horizontalPadding: Tokens.padding.largeIncreased
            checked: root.radioOn
            enabled: WindowsBluetooth.canToggleRadio
            onToggled: WindowsBluetooth.setRadioEnabled(checked)
        }

        // The facade's reason is a full sentence, so it wraps in a note block
        // instead of eliding inside a row.
        ConnectedRect {
            Layout.fillWidth: true
            implicitHeight: root.radioOn || WindowsBluetooth.ready ? 0 : radioNote.implicitHeight + Tokens.padding.large * 2
            visible: implicitHeight > 0
            first: true
            last: true

            StyledText {
                id: radioNote

                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.margins: Tokens.padding.large
                visible: parent.visible

                text: WindowsBluetooth.reason
                color: Colours.palette.m3onSurfaceVariant
                font: Tokens.font.body.small
                wrapMode: Text.WordWrap
            }
        }

        ItemList {
            id: savedList

            showList: root.radioOn
            placeholderIcon: root.radioOn ? "devices_other" : "bluetooth_disabled"
            placeholderText: root.radioOn ? Tr.tr("No saved devices") : Tr.tr("Bluetooth disabled")

            model: ScriptModel {
                values: root.savedDevices
            }

            delegate: StyledRect {
                id: device

                required property var modelData
                readonly property bool connected: modelData?.connected === true
                readonly property bool loading: modelData?.state === WindowsBluetooth.deviceConnecting || modelData?.state === WindowsBluetooth.deviceDisconnecting
                property real textOpacity: loading ? 0.5 : 1

                anchors.left: savedList.list.contentItem.left
                anchors.right: savedList.list.contentItem.right
                implicitHeight: deviceLayout.implicitHeight + deviceLayout.anchors.margins * 2
                radius: Tokens.rounding.extraSmall
                color: "transparent"

                Behavior on textOpacity {
                    Anim {
                        type: Anim.DefaultEffects
                    }
                }

                StateLayer {
                    disabled: device.loading || (device.connected ? !WindowsBluetooth.canDisconnect(device.modelData) : !WindowsBluetooth.canConnect(device.modelData))
                    onClicked: {
                        if (!device.modelData || device.loading)
                            return;
                        if (device.connected)
                            WindowsBluetooth.disconnectDevice(device.modelData);
                        else
                            WindowsBluetooth.connectDevice(device.modelData);
                    }
                }

                RowLayout {
                    id: deviceLayout

                    anchors.fill: parent
                    anchors.margins: Tokens.padding.medium
                    anchors.leftMargin: Tokens.padding.largeIncreased
                    anchors.rightMargin: Tokens.padding.largeIncreased
                    spacing: Tokens.spacing.medium

                    StyledRect {
                        implicitWidth: implicitHeight
                        implicitHeight: deviceIcon.implicitHeight + Tokens.padding.small * 2
                        radius: Tokens.rounding.full
                        color: device.connected ? Colours.palette.m3primary : Colours.palette.m3secondaryContainer

                        MaterialIcon {
                            id: deviceIcon

                            anchors.centerIn: parent
                            text: Icons.getBluetoothIcon(device.modelData?.icon ?? "")
                            color: device.connected ? Colours.palette.m3onPrimary : Colours.palette.m3onSecondaryContainer
                            fontStyle: Tokens.font.icon.medium
                            fill: device.connected ? 1 : 0
                            opacity: device.textOpacity

                            Behavior on fill {
                                Anim {}
                            }
                        }
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 0
                        opacity: device.textOpacity

                        StyledText {
                            Layout.fillWidth: true
                            text: device.modelData?.name ?? Tr.trCtx("Unknown", "unknown bluetooth device")
                            font: Tokens.font.body.small
                            elide: Text.ElideRight
                        }

                        StyledText {
                            Layout.fillWidth: true
                            text: {
                                if (!device.connected)
                                    return Tr.trCtx("Saved", "bluetooth device state");
                                if (device.modelData?.batteryAvailable)
                                    // TRANSLATORS: %1 = battery level, already formatted as a percentage
                                    return Tr.trCtx("Connected • %1", "bluetooth device state with battery").arg(Strings.percentOne(device.modelData.battery));
                                return Tr.trCtx("Connected", "bluetooth device state");
                            }
                            color: Colours.palette.m3outline
                            font: Tokens.font.label.small
                            elide: Text.ElideRight
                            animate: true
                        }
                    }

                    Item {
                        Layout.fillHeight: true
                        implicitWidth: height

                        AnimLoader {
                            anchors.centerIn: parent
                            sourceComp: device.loading ? loadingComp : btnComp

                            Component {
                                id: btnComp

                                IconButton {
                                    icon: "settings"
                                    type: IconButton.Text
                                    padding: Tokens.padding.small
                                    inactiveOnColour: device.connected ? Colours.palette.m3primary : Colours.palette.m3onSurfaceVariant
                                    label.fill: 0

                                    onClicked: {
                                        root.nState.selectedBtDevice = device.modelData;
                                        root.nState.openSubPage(1); // Per device info page
                                    }
                                }
                            }

                            Component {
                                id: loadingComp

                                LoadingIndicator {
                                    implicitSize: Math.round(Tokens.font.icon.medium.pointSize * 1.3)
                                }
                            }
                        }
                    }
                }
            }
        }

        RowButton {
            last: true
            icon: "add"
            text: Tr.tr("Pair new device")
            disabled: !root.radioOn
            onClicked: root.nState.openSubPage(2)
        }

        // Upstream exposes Discoverable and Pairable here. Plaform note: the
        // pinned Windows backend has no adapter setter for either, so the page
        // would render two switches that never change anything. Windows
        // Settings owns them instead.
        NavRow {
            Layout.topMargin: Tokens.spacing.large - parent.spacing
            first: true
            last: true
            icon: "settings_bluetooth"
            text: Tr.tr("Windows Bluetooth settings")
            subtext: Tr.tr("Discoverability, PIN pairing and device removal")
            onClicked: Qt.openUrlExternally("ms-settings:bluetooth")
        }
    }
}
