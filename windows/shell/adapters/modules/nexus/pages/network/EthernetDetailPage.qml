pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Caelestia.Config
import Caelestia.I18n
import qs.components
import qs.components.controls
import qs.services
import qs.modules.nexus.common

// Windows adaptation of modules/nexus/pages/network/EthernetDetailPage.qml.
//
// Upstream shows link speed, IPv4 address/gateway/DNS, data usage and IPv4
// configuration for a NetworkManager wired connection. The pinned Windows
// backend reduces Ethernet to one connected flag (network.hpp keeps two
// booleans), so every one of those getters returns an empty value and the
// connect/disconnect/Ethernet control requests are explicitly unsupported. The
// page reports the observed link state and defers configuration to Windows
// rather than rendering a form that cannot write.
PageBase {
    id: root

    readonly property bool connected: Nmcli.hasAvailableEthernet

    title: Tr.trCtx("Ethernet", "wired network")
    isSubPage: true

    ColumnLayout {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        width: root.cappedWidth
        spacing: Tokens.spacing.extraSmall / 2

        SectionHeader {
            first: true
            text: Tr.tr("Link")
        }

        InfoRow {
            first: true
            last: true
            icon: "settings_ethernet"
            iconColour: root.connected ? Colours.palette.m3primary : Colours.palette.m3outline
            label: Tr.trCtx("Status", "network connection state")
            value: root.connected ? Tr.trCtx("Connected", "ethernet link state") : Tr.trCtx("Not connected", "ethernet link state")
        }

        ConnectedRect {
            Layout.topMargin: Tokens.spacing.small
            Layout.fillWidth: true
            implicitHeight: explain.implicitHeight + Tokens.padding.large * 2
            first: true
            last: true

            StyledText {
                id: explain

                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.margins: Tokens.padding.large

                text: Tr.tr("The Windows backend reports whether a wired connection is up. Adapter list, link speed, addresses and data usage are not exposed to the shell, and wired connect/disconnect is not available here. Use Windows Settings for wired configuration.")
                color: Colours.palette.m3onSurfaceVariant
                font: Tokens.font.body.small
                wrapMode: Text.WordWrap
            }
        }

        NavRow {
            first: true
            last: true
            icon: "settings_ethernet"
            text: Tr.tr("Windows network settings")
            subtext: Tr.tr("Ethernet adapters and IP configuration")
            onClicked: Qt.openUrlExternally("ms-settings:network-ethernet")
        }
    }
}
