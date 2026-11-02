pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Caelestia.Config
import Caelestia.I18n
import qs.components
import qs.components.controls
import qs.services
import qs.modules.nexus.common

// Windows adaptation of modules/nexus/pages/network/AddVpnPage.qml.
//
// Upstream edits a Caelestia-owned VPN provider record (name, interface,
// connect/disconnect commands, ping stats) through services/VPN.qml, which runs
// Linux processes and is not staged on Windows. The pinned backend has no VPN
// provider API, and Windows owns VPN profiles through its own settings and
// credential flows. The page is kept in the registry with an honest explanation
// plus the Windows entry point instead of a dead form.
PageBase {
    id: root

    title: Tr.tr("VPN providers")
    isSubPage: true

    ColumnLayout {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        width: root.cappedWidth
        spacing: Tokens.spacing.extraSmall / 2

        ConnectedRect {
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

                text: Tr.tr("VPN profiles and their credentials belong to Windows. This shell does not start or configure a VPN client itself, so providers are managed in Windows Settings.")
                color: Colours.palette.m3onSurfaceVariant
                font: Tokens.font.body.small
                wrapMode: Text.WordWrap
            }
        }

        NavRow {
            first: true
            last: true
            icon: "vpn_key"
            text: Tr.tr("Windows VPN settings")
            subtext: Tr.tr("Add, edit or connect a VPN profile")
            onClicked: Qt.openUrlExternally("ms-settings:network-vpn")
        }
    }
}
