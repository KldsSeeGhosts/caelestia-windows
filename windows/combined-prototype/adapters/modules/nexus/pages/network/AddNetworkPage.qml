pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Caelestia.Config
import Caelestia.I18n
import qs.components
import qs.components.controls
import qs.services
import qs.modules.nexus.common

// Windows adaptation of modules/nexus/pages/network/AddNetworkPage.qml.
//
// Upstream renders a hidden-network form with an SSID field, a security choice
// and a password field. This port never collects Wi-Fi credentials: the Windows
// facade accepts only an already-saved profile or an open network, and
// windows/docs/USER-GUIDE.md states that a new protected network is completed
// in Windows Settings. The page therefore keeps the upstream title and row
// structure but offers the Windows entry point instead of a credential form.
PageBase {
    id: root

    title: Tr.tr("Add network")
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

                text: Tr.tr("Windows asks for a Wi-Fi password in its own secure prompt. This shell connects to saved or open networks directly and hands a new protected network to Windows Settings, so no password is ever typed here.")
                color: Colours.palette.m3onSurfaceVariant
                font: Tokens.font.body.small
                wrapMode: Text.WordWrap
            }
        }

        NavRow {
            first: true
            last: true
            icon: "wifi_password"
            text: Tr.tr("Add a network in Windows")
            subtext: Tr.tr("Enter the SSID and password in Windows Settings")
            onClicked: Qt.openUrlExternally("ms-settings:network-wifi")
        }
    }
}
