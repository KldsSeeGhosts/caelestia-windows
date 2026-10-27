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

// Windows adaptation of modules/nexus/pages/bluetooth/BluetoothPairing.qml.
//
// Upstream pairs through BlueZ, which reports a device in pairing state and
// completes without user input. Windows raises its own PIN/passkey prompt for
// most devices; this shell cannot answer it, and the pinned backend only
// publishes pair/cancelPair with no prompt hook. This page therefore keeps the
// upstream device-list layout, offers the pair request only through the
// facade's gated helper, and tells the user that a Windows prompt must be
// completed in Windows Settings. No PIN or passkey is ever collected here.
PageBase {
    id: root

    readonly property var newDevices: [...WindowsBluetooth.devices].filter(device => device && device.bonded !== true).sort((a, b) => (b.pairing - a.pairing) || (a.name ?? "").localeCompare(b.name ?? ""))

    function setScan(on: bool): void {
        if (on)
            WindowsBluetooth.startDiscovery();
        else
            WindowsBluetooth.stopDiscovery();
    }

    title: Tr.tr("Pair new device")
    isSubPage: true

    Component.onCompleted: setScan(true)
    Component.onDestruction: setScan(false)
    onVisibleChanged: setScan(visible)

    ColumnLayout {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        width: root.cappedWidth
        spacing: Tokens.spacing.extraSmall / 2

        ConnectedRect {
            Layout.fillWidth: true
            implicitHeight: headerText.implicitHeight + Tokens.padding.medium * 2
            first: true

            StyledText {
                id: headerText

                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Tokens.padding.large
                anchors.rightMargin: Tokens.padding.large
                anchors.verticalCenterOffset: Math.round(fontInfo.pointSize * 0.2)

                text: WindowsBluetooth.pairingNeedsWindowsSettings ? Tr.tr("Complete the PIN or passkey prompt in Windows") : Tr.tr("Available devices")
                color: WindowsBluetooth.pairingNeedsWindowsSettings ? Colours.palette.m3primary : Colours.palette.m3onSurfaceVariant
                font: Tokens.font.body.small
                wrapMode: Text.WordWrap
            }
        }

        ItemList {
            id: deviceList

            Layout.fillWidth: true
            showList: true
            extraHeight: scanIndicator.implicitHeight
            last: true
            placeholderIcon: "bluetooth_searching"
            placeholderText: WindowsBluetooth.canSetDiscovering ? Tr.tr("Searching for devices…") : Tr.tr("Bluetooth is not ready")
            list.anchors.top: scanIndicator.bottom

            model: ScriptModel {
                values: root.newDevices
            }

            delegate: Item {
                id: newDevice

                required property var modelData
                required property int index
                property real textOpacity: modelData?.pairing ? 0.5 : 1

                anchors.left: deviceList.list.contentItem.left
                anchors.right: deviceList.list.contentItem.right
                implicitHeight: newLayout.implicitHeight + newLayout.anchors.margins * 2

                Behavior on textOpacity {
                    Anim {
                        type: Anim.DefaultEffects
                    }
                }

                StateLayer {
                    radius: Tokens.rounding.extraSmall
                    bottomLeftRadius: newDevice.index === deviceList?.list.count - 1 ? Tokens.rounding.extraLarge : radius
                    bottomRightRadius: newDevice.index === deviceList?.list.count - 1 ? Tokens.rounding.extraLarge : radius
                    // The pinned facade reports no pairing prompt and cancels a
                    // request whose window expires; the explicit action is the
                    // only way to ask Windows to pair, and it is gated.
                    disabled: !WindowsBluetooth.canPair(newDevice.modelData)

                    onClicked: WindowsBluetooth.pairDevice(newDevice.modelData)
                }

                RowLayout {
                    id: newLayout

                    anchors.fill: parent
                    anchors.margins: Tokens.padding.medium
                    anchors.leftMargin: Tokens.padding.largeIncreased
                    anchors.rightMargin: Tokens.padding.largeIncreased
                    spacing: Tokens.spacing.medium

                    MaterialIcon {
                        text: Icons.getBluetoothIcon(newDevice.modelData?.icon ?? "")
                        color: Colours.palette.m3onSurfaceVariant
                        fontStyle: Tokens.font.icon.medium
                        opacity: newDevice.textOpacity
                    }

                    ColumnLayout {
                        Layout.fillWidth: true
                        spacing: 0
                        opacity: newDevice.textOpacity

                        StyledText {
                            Layout.fillWidth: true
                            text: newDevice.modelData?.name || Tr.tr("Unknown device")
                            font: Tokens.font.body.small
                            elide: Text.ElideRight
                        }

                        StyledText {
                            Layout.fillWidth: true
                            text: newDevice.modelData?.pairing ? Tr.tr("Pairing...") : (newDevice.modelData?.address ?? "")
                            color: Colours.palette.m3outline
                            font: Tokens.font.label.small
                            elide: Text.ElideRight
                            animate: true
                        }
                    }

                    Loader {
                        asynchronous: true
                        active: opacity > 0
                        opacity: newDevice.modelData?.pairing ? 1 : 0

                        sourceComponent: LoadingIndicator {
                            implicitSize: Math.round(Tokens.font.icon.medium.pointSize * 1.3)
                        }

                        Behavior on opacity {
                            Anim {
                                type: Anim.DefaultEffects
                            }
                        }
                    }
                }
            }

            StyledProgressBar {
                id: scanIndicator

                anchors.left: parent.left
                anchors.right: parent.right
                anchors.top: parent.top
                anchors.margins: 1
                implicitHeight: WindowsBluetooth.discovering ? Tokens.rounding.extraSmall : 0
                indeterminate: true

                Behavior on implicitHeight {
                    Anim {
                        type: Anim.DefaultEffects
                    }
                }
            }
        }

        NavRow {
            Layout.topMargin: Tokens.spacing.large - parent.spacing
            first: true
            last: true
            icon: "settings_bluetooth"
            text: Tr.tr("Windows Bluetooth settings")
            subtext: Tr.tr("Finish a pairing that needs a PIN or passkey")
            onClicked: Qt.openUrlExternally("ms-settings:bluetooth")
        }
    }
}
