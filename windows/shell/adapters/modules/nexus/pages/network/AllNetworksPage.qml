pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Caelestia.Config
import Caelestia.I18n
import qs.components
import qs.services
import qs.modules.nexus.common

// Windows adaptation of modules/nexus/pages/network/AllNetworksPage.qml.
//
// Upstream renders four filtered sections (saved, secure, open, other) driven by
// Nmcli.hasSavedProfile(), which the Windows facade also provides, so the
// sections are kept. The sort and filter helpers that upstream runs through
// nmcli are gone: this page only reuses the shared Windows NetworkList.
PageBase {
    id: root

    readonly property bool allFound: Nmcli.networks.length > 0

    title: Tr.tr("All networks")
    isSubPage: true

    // This sub-page registers its own visibility owner. The parent Network page
    // may still hold an owner, and a second Nexus window must not be affected
    // when this one is popped or destroyed.
    // The native backend owns the immediate scan and periodic scan timer.
    function setVisibility(visible: bool): void {
        if (visible)
            Nmcli.acquireListVisibility(root);
        else
            Nmcli.releaseListVisibility(root);
    }

    Component.onCompleted: root.setVisibility(root.visible)
    Component.onDestruction: Nmcli.releaseListVisibility(root)
    onVisibleChanged: root.setVisibility(root.visible)

    ColumnLayout {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        width: root.cappedWidth
        spacing: Tokens.spacing.extraSmall / 2

        // The parent Network page is hidden while this sub-page is open, so
        // repeat the facade's last connect/forget result here.
        ConnectedRect {
            readonly property bool shown: Nmcli.resultText.length > 0

            Layout.fillWidth: true
            Layout.bottomMargin: shown ? Tokens.spacing.small / 2 : -parent.spacing
            visible: shown
            implicitHeight: shown ? allResultText.implicitHeight + Tokens.padding.large * 2 : 0
            first: true
            last: true

            StyledText {
                id: allResultText

                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.margins: Tokens.padding.large

                text: Nmcli.resultText
                color: Nmcli.resultSucceeded === false ? Colours.palette.m3error : Colours.palette.m3onSurfaceVariant
                font: Tokens.font.body.small
                wrapMode: Text.WordWrap
            }
        }

        NetworkList {
            id: allList

            nState: root.nState
            first: true
            last: true
        }

        InfoRow {
            Layout.topMargin: Tokens.spacing.small / 2
            visible: root.allFound
            first: true
            last: true
            icon: "wifi"
            label: Tr.tr("Networks found")
            value: root.allFound ? allList.list.count.toString() : ""
        }
    }
}
