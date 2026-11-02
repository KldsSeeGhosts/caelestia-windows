pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Caelestia.Config
import Caelestia.I18n
import qs.components
import qs.components.controls
import qs.services
import qs.modules.nexus.common

// Windows adaptation of modules/nexus/pages/network/NetworkDetailPage.qml.
//
// Upstream shows signal/security/address information from Nmcli and offers
// IPv4 configuration, autoconnect and a passwordless "forget". The pinned
// Windows backend publishes a visible access point projection only: SSID,
// strength, security, active and the saved-profile flag. Address, gateway, DNS
// and autoconnect come back empty and the shell cannot change Windows IP
// configuration, so those rows and the IPv4 form are not shown. Disconnect and
// Forget stay, gated by the facade, and any credential or address change is
// deferred to Windows Settings.
PageBase {
    id: root

    readonly property var ap: Nmcli.findNetwork(root.nState.selectedNetworkSsid)
    readonly property bool isActive: !!root.ap && root.ap.active

    title: root.nState.selectedNetworkSsid || Tr.trCtx("Network", "wifi network name")
    isSubPage: true

    // `ap` goes null for a moment whenever the facade rebuilds its scan
    // results, and closing on that transient threw the user back to the
    // network list mid-rescan. Wait for a quiet period before giving up; a
    // returning access point stops the timer.
    onApChanged: {
        if (root.ap)
            closeTimer.stop();
        else
            closeTimer.start();
    }

    ColumnLayout {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        width: root.cappedWidth
        spacing: Tokens.spacing.extraSmall / 2

        Timer {
            id: closeTimer

            interval: 1500
            onTriggered: {
                if (!root.ap)
                    nState.closeSubPage();
            }
        }

        SectionHeader {
            first: true
            text: Tr.tr("Connection")
        }

        InfoRow {
            first: true
            label: Tr.trCtx("Status", "network connection state")
            value: root.isActive ? Tr.trCtx("Connected", "network connected") : Tr.trCtx("Not connected", "network not connected")
        }

        InfoRow {
            label: Tr.tr("Signal strength")
            value: Tr.tr("%1%").arg(root.ap?.strength ?? 0)
        }

        InfoRow {
            label: Tr.tr("Security")
            value: root.ap?.isSecure ? root.ap.security : Tr.trCtx("Open", "open wifi network")
        }

        InfoRow {
            last: true
            label: Tr.tr("Saved profile")
            value: root.ap?.hasProfile ? Tr.trCtx("Saved", "network saved") : Tr.trCtx("Not saved", "network not saved")
        }

        SectionHeader {
            text: Tr.tr("Actions")
        }

        RowButton {
            first: true
            icon: "link_off"
            text: Tr.trCtx("Disconnect", "network action")
            disabled: !root.isActive || !Nmcli.controlsEnabled
            onClicked: Nmcli.disconnectFromNetwork()
        }

        RowButton {
            last: true
            icon: "delete"
            text: Tr.tr("Forget network")
            subtext: Tr.tr("Removes the saved Windows profile")
            disabled: !(root.ap?.hasProfile ?? false) || !Nmcli.controlsEnabled
            onClicked: Nmcli.forgetNetwork(root.nState.selectedNetworkSsid)
        }

        NavRow {
            Layout.topMargin: Tokens.spacing.small
            first: true
            last: true
            icon: "settings_ethernet"
            text: Tr.tr("Windows network settings")
            subtext: Tr.tr("IP configuration, DNS and passwords")
            onClicked: Qt.openUrlExternally("ms-settings:network-wifi")
        }
    }
}
