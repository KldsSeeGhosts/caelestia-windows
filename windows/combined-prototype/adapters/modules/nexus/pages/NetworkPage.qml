pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Caelestia.Config
import Caelestia.I18n
import qs.components
import qs.components.controls
import qs.services
import qs.modules.nexus.common

// Windows adaptation of modules/nexus/pages/NetworkPage.qml.
//
// Kept from upstream: the page title, spacing, Wi-Fi toggle,
// network list, "show all"/"saved networks"/"add network" rows and the whole
// List motion. Changed for Windows:
//   * the wired section uses the backend's single connected flag instead of
//     the Linux per-interface detail calls (those return empty strings here);
//   * the VPN section is replaced by a Windows Settings row, because the
//     pinned backend exposes no VPN provider API and upstream's VPN service is
//     not staged;
//   * "Add network" and "Saved networks" lead to honest pages that defer the
//     credential and profile stores to Windows, since the adapter collects no
//     Wi-Fi key (see windows/docs/USER-GUIDE.md).
PageBase {
    id: root

    title: Tr.tr("Network")

    // The Windows scanner runs only while a caller says the list is visible and
    // the controls opt-in is on. Every window and sub-page registers its own
    // interest, so closing one Nexus window cannot stop another window's scan.
    // The native backend scans on show and every eight seconds while visible;
    // a second page timer duplicates that work and overwrites command feedback.
    function setVisibility(visible: bool): void {
        if (visible)
            Nmcli.acquireListVisibility(root);
        else
            Nmcli.releaseListVisibility(root);
    }

    // A refused/failed command has no row to land on (for example a read-only
    // run or an unavailable adapter), and a successful connect is useful
    // feedback too. The facade's lastResult is the single source of truth.
    readonly property string actionNote: {
        if (!Nmcli.enabled || !Nmcli.listAvailable)
            return "";
        const lines = [];
        if (!Nmcli.controlsEnabled)
            lines.push(Tr.tr("Wi-Fi actions are disabled for read-only observation."));
        if (Nmcli.resultText.length > 0)
            lines.push(Nmcli.resultText);
        return lines.join("\n");
    }

    Component.onCompleted: root.setVisibility(root.visible)
    Component.onDestruction: Nmcli.releaseListVisibility(root)
    onVisibleChanged: root.setVisibility(root.visible)

    ColumnLayout {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        width: root.cappedWidth
        spacing: Tokens.spacing.extraSmall / 2

        // Wired connection. The pinned backend reports a connected flag only,
        // so no address, speed or usage rows are fabricated.
        InfoRow {
            Layout.topMargin: Nmcli.hasAvailableEthernet ? 0 : -parent.spacing
            visible: Nmcli.hasAvailableEthernet
            first: true
            last: true
            icon: "settings_ethernet"
            iconColour: Colours.palette.m3primary
            label: Tr.trCtx("Ethernet", "wired network")
            subtext: Tr.tr("Connected")
            value: ""
        }

        // Honest status for the states in which the list is withheld. The
        // facade's reason is a full sentence, so it wraps in a note block
        // instead of eliding inside a single-line row.
        ConnectedRect {
            readonly property bool shown: Nmcli.status === "location-denied" || Nmcli.status === "no-adapter" || Nmcli.status === "unavailable" || Nmcli.status === "initializing"

            Layout.topMargin: shown ? Tokens.spacing.small / 2 : -parent.spacing
            Layout.fillWidth: true
            visible: shown
            implicitHeight: shown ? statusNote.implicitHeight + Tokens.padding.large * 2 : 0
            first: true
            last: true

            StyledText {
                id: statusNote

                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.margins: Tokens.padding.large
                visible: parent.shown

                text: Nmcli.reason
                color: Colours.palette.m3onSurfaceVariant
                font: Tokens.font.body.small
                wrapMode: Text.WordWrap
            }
        }

        ToggleRow {
            Layout.topMargin: Nmcli.hasAvailableEthernet ? Tokens.spacing.large : 0
            first: true
            text: Tr.tr("Wi-Fi")
            font: Tokens.font.body.medium
            horizontalPadding: Tokens.padding.largeIncreased
            checked: Nmcli.wifiEnabled
            enabled: Nmcli.controlsEnabled && Nmcli.adapterPresent
            onToggled: Nmcli.enableWifi(checked)
        }

        ConnectedRect {
            readonly property bool shown: root.actionNote.length > 0

            Layout.topMargin: shown ? Tokens.spacing.small / 2 : -parent.spacing
            Layout.fillWidth: true
            visible: shown
            implicitHeight: shown ? resultNoteText.implicitHeight + Tokens.padding.large * 2 : 0
            first: true
            last: true

            StyledText {
                id: resultNoteText

                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.margins: Tokens.padding.large
                visible: parent.shown

                text: root.actionNote
                color: Nmcli.resultText.length > 0 && Nmcli.resultSucceeded === false ? Colours.palette.m3error : Colours.palette.m3onSurfaceVariant
                font: Tokens.font.body.small
                wrapMode: Text.WordWrap
            }
        }

        NetworkList {
            Layout.bottomMargin: Nmcli.wifiEnabled && Nmcli.networks.length > GlobalConfig.nexus.maxNetworksShown ? 0 : -parent.spacing
            nState: root.nState
            limit: GlobalConfig.nexus.maxNetworksShown

            Behavior on Layout.bottomMargin {
                Anim {
                    type: Anim.DefaultEffects
                }
            }
        }

        // All networks button, only when > max networks
        RowButton {
            Layout.preferredHeight: Nmcli.wifiEnabled && Nmcli.networks.length > GlobalConfig.nexus.maxNetworksShown ? implicitHeight : 0
            clip: true

            icon: "expand_content"
            // TRANSLATORS: %1 = number of networks found
            text: Tr.tr("Show all networks (%1)").arg(Nmcli.networks.length)
            trailingIcon: "chevron_right"
            onClicked: root.nState.openSubPage(5) // All networks sub-page

            Behavior on Layout.preferredHeight {
                Anim {
                    type: Anim.DefaultEffects
                }
            }
        }

        // Saved networks button
        RowButton {
            icon: "bookmark"
            text: Tr.tr("Saved networks")
            trailingIcon: "chevron_right"
            onClicked: root.nState.openSubPage(6) // Saved networks sub-page
        }

        RowButton {
            last: true
            icon: "add"
            text: Tr.tr("Add network")
            disabled: !Nmcli.wifiEnabled
            onClicked: root.nState.openSubPage(2) // Add network sub-page
        }

        // Windows-owned connection settings. Upstream lists VPN providers and a
        // static-IP form here; neither has a Windows adapter, so the honest
        // equivalent is a link to the place Windows keeps them.
        ToggleRow {
            Layout.topMargin: Tokens.spacing.large
            Layout.fillWidth: true
            first: true
            last: true
            text: Tr.tr("VPN")
            font: Tokens.font.body.medium
            horizontalPadding: Tokens.padding.largeIncreased
            subtext: Tr.tr("Windows Settings manages VPN profiles")
            checked: false
            enabled: false
        }

        NavRow {
            first: true
            last: true
            icon: "settings_ethernet"
            text: Tr.tr("Windows network settings")
            subtext: Tr.tr("Wi-Fi passwords, VPN profiles and IP configuration")
            onClicked: Qt.openUrlExternally("ms-settings:network")
        }
    }
}
