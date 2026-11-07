pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Caelestia.Config
import Caelestia.I18n
import qs.components
import qs.components.controls
import qs.services
import qs.modules.nexus.common

// Windows adaptation of modules/nexus/pages/network/SavedNetworksPage.qml.
//
// Upstream enumerates saved NetworkManager connection profiles and can remove
// them. The pinned Windows backend exposes no saved-profile enumeration (only a
// per-access-point `hasProfile` flag), so this page does not pretend to list
// them. It explains where Windows keeps them and offers the saved networks that
// are currently in range, which is the only truthful subset the adapter has.
PageBase {
    id: root

    readonly property var savedInRange: [...Nmcli.networks].filter(ap => ap.hasProfile === true).sort((a, b) => a.ssid.localeCompare(b.ssid))

    title: Tr.tr("Saved networks")
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
            last: root.savedInRange.length === 0

            StyledText {
                id: explain

                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.margins: Tokens.padding.large

                text: Tr.tr("Windows keeps saved Wi-Fi profiles. This shell can only show the ones currently in range; add, remove or edit them in Windows Settings.")
                color: Colours.palette.m3onSurfaceVariant
                font: Tokens.font.body.small
                wrapMode: Text.WordWrap
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            spacing: Tokens.spacing.extraSmall / 2

            Repeater {
                model: root.savedInRange

                NavRow {
                    id: savedRow

                    required property var modelData
                    required property int index

                    Layout.fillWidth: true
                    first: savedRow.index === 0
                    last: savedRow.index === root.savedInRange.length - 1
                    icon: "wifi"
                    text: savedRow.modelData.ssid
                    subtext: savedRow.modelData.isSecure ? savedRow.modelData.security : Tr.trCtx("Open", "open wifi network")
                    onClicked: {
                        root.nState.selectedNetworkSsid = savedRow.modelData.ssid;
                        root.nState.selectedNetworkId = savedRow.modelData.selectionId || "";
                        root.nState.networkDetailsFromSaved = true;
                        root.nState.openSubPage(3);
                    }
                }
            }
        }

        NavRow {
            Layout.topMargin: Tokens.spacing.small
            first: true
            last: true
            icon: "settings_ethernet"
            text: Tr.tr("Manage saved networks in Windows")
            subtext: Tr.tr("Add, remove or edit Wi-Fi profiles")
            onClicked: Qt.openUrlExternally("ms-settings:network-wifi")
        }
    }
}
