pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Caelestia.Components
import Caelestia.Config
import Caelestia.I18n
import qs.components
import qs.components.controls
import qs.services
import qs.utils
import qs.modules.nexus.common

// Windows adaptation of modules/nexus/pages/bluetooth/BtDeviceInfo.qml.
//
// The layout, motion and battery/address rows are upstream. Quickshell.Bluetooth
// is unavailable on the pinned Windows backend, so the device comes from the
// staged WindowsBluetooth facade and connect/disconnect/forget go through its
// gated helpers. Upstream also exposes Trusted, Blocked and Wake allowed; the
// WinRT device object has no such setters (the facade's setTrusted/setBlocked/
// setWakeAllowed always refuse), so those switches stay visible but disabled
// with the reason instead of pretending to write.
PageBase {
    id: root

    readonly property var device: nState.selectedBtDevice
    readonly property bool connected: device?.connected === true
    readonly property bool loading: device?.state === WindowsBluetooth.deviceConnecting || device?.state === WindowsBluetooth.deviceDisconnecting

    readonly property string statusText: {
        if (!device)
            return "";
        if (connected && device.batteryAvailable)
            // TRANSLATORS: %1 = battery level, already formatted as a percentage
            return Tr.trCtx("Connected • %1", "bluetooth device state with battery").arg(Strings.percentOne(device.battery));
        if (connected)
            return Tr.trCtx("Connected", "bluetooth device state");
        return device.bonded ? Tr.trCtx("Paired", "bluetooth device state") : Tr.trCtx("Not paired", "bluetooth device state");
    }

    onDeviceChanged: {
        // Auto close when device lost
        if (!device)
            nState.closeSubPage();
    }

    title: device?.name ?? Tr.trCtx("Device", "unnamed bluetooth device")
    isSubPage: true

    ColumnLayout {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        width: root.cappedWidth
        spacing: Tokens.spacing.extraSmall / 2

        // Big buttons
        ButtonRow {
            Layout.bottomMargin: Tokens.spacing.large - parent.spacing
            Layout.alignment: Qt.AlignHCenter
            Layout.minimumWidth: Math.round(root.cappedWidth * 0.7)
            spacing: Tokens.spacing.small

            ButtonBase {
                id: forgetBtn

                fillWidth: true
                shapeMorph: true
                isRound: true

                inactiveColour: Colours.palette.m3errorContainer
                inactiveOnColour: Colours.palette.m3onErrorContainer

                implicitWidth: forgetBtnLayout.implicitWidth + Tokens.padding.extraLarge * 2
                implicitHeight: forgetBtnLayout.implicitHeight + Tokens.padding.medium * 2

                stateLayer.disabled: !WindowsBluetooth.canForget(root.device)

                onClicked: {
                    WindowsBluetooth.forgetDevice(root.device);
                    root.nState.closeSubPage();
                }

                ColumnLayout {
                    id: forgetBtnLayout

                    anchors.centerIn: parent
                    spacing: 0

                    MaterialIcon {
                        Layout.alignment: Qt.AlignHCenter
                        text: "delete"
                        color: forgetBtn.onColour
                        fontStyle: Tokens.font.icon.medium
                    }

                    StyledText {
                        Layout.alignment: Qt.AlignHCenter
                        text: Tr.trCtx("Forget", "button")
                        color: forgetBtn.onColour
                    }
                }
            }

            ButtonBase {
                id: connectBtn

                fillWidth: true
                shapeMorph: true
                isRound: true

                inactiveColour: Colours.palette.m3primaryContainer
                inactiveOnColour: Colours.palette.m3onPrimaryContainer
                stateLayer.disabled: root.loading || (root.connected ? !WindowsBluetooth.canDisconnect(root.device) : !WindowsBluetooth.canConnect(root.device))

                implicitWidth: connectBtnContent.implicitWidth + Tokens.padding.extraLarge * 2
                implicitHeight: connectBtnContent.implicitHeight + Tokens.padding.medium * 2

                onClicked: {
                    if (root.connected)
                        WindowsBluetooth.disconnectDevice(root.device);
                    else
                        WindowsBluetooth.connectDevice(root.device);
                }

                AnimLoader {
                    id: connectBtnContent

                    anchors.centerIn: parent
                    sourceComp: root.loading ? loadingComp : textComp
                    outAnimType: Anim.SlowEffects
                    inAnimType: Anim.SlowEffects
                }

                Component {
                    id: loadingComp

                    LoadingIndicator {
                        implicitSize: connectBtn.height - Tokens.padding.large * 2
                    }
                }

                Component {
                    id: textComp

                    ColumnLayout {
                        spacing: 0

                        MaterialIcon {
                            Layout.alignment: Qt.AlignHCenter
                            text: root.connected ? "close" : "add"
                            color: connectBtn.inactiveOnColour
                            fontStyle: Tokens.font.icon.medium
                            animate: true
                        }

                        StyledText {
                            Layout.alignment: Qt.AlignHCenter
                            text: root.connected ? Tr.trCtx("Disconnect", "button") : Tr.trCtx("Connect", "button")
                            color: connectBtn.inactiveOnColour
                            animate: true
                        }
                    }
                }
            }
        }

        // Connection group
        ToggleRow {
            verticalPadding: Tokens.padding.large
            first: true
            text: Tr.trCtx("Trusted", "bluetooth device state")
            subtext: Tr.tr("Windows manages automatic connection for paired devices")
            checked: false
            enabled: false
        }

        ToggleRow {
            verticalPadding: Tokens.padding.large
            text: Tr.trCtx("Blocked", "bluetooth device state")
            subtext: Tr.tr("Windows Settings manages blocked devices")
            checked: false
            enabled: false
        }

        ToggleRow {
            verticalPadding: Tokens.padding.large
            last: true
            text: Tr.tr("Wake allowed")
            subtext: Tr.tr("Windows manages device wake permissions")
            checked: false
            enabled: false
        }

        // Information
        ConnectedRect {
            Layout.topMargin: Tokens.spacing.large - parent.spacing
            Layout.fillWidth: true
            implicitHeight: batteryLayout.implicitHeight + Tokens.padding.large * 2
            first: true

            ColumnLayout {
                id: batteryLayout

                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.margins: Tokens.padding.large
                spacing: Tokens.spacing.small

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Tokens.spacing.medium

                    StyledText {
                        Layout.fillWidth: true
                        text: Tr.tr("Battery")
                    }

                    StyledText {
                        text: root.device?.batteryAvailable ? Strings.percentOne(root.device.battery) : Tr.trCtx("Unavailable", "bluetooth device state")
                        color: Colours.palette.m3outline
                        font: Tokens.font.body.small
                    }
                }

                Loader {
                    Layout.fillWidth: true
                    active: root.device?.batteryAvailable ?? false
                    visible: active
                    asynchronous: true

                    sourceComponent: StyledProgressBar {
                        implicitHeight: Tokens.padding.medium
                        value: root.device.battery
                    }
                }
            }
        }

        ConnectedRect {
            Layout.fillWidth: true
            implicitHeight: addrLayout.implicitHeight + Tokens.padding.large * 2
            last: true

            RowLayout {
                id: addrLayout

                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.margins: Tokens.padding.large
                spacing: Tokens.spacing.medium

                StyledText {
                    Layout.fillWidth: true
                    text: Tr.trCtx("Address", "bluetooth MAC address")
                }

                StyledText {
                    text: root.device?.address ?? ""
                    color: Colours.palette.m3outline
                    font: Tokens.font.body.small
                }
            }
        }
    }
}
