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

    // The parent Network page owns the visibility intent; this sub-page only
    // makes sure a scan is allowed while it is the page in front.
    Component.onCompleted: Nmcli.setListVisible(true)

    ColumnLayout {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        width: root.cappedWidth
        spacing: Tokens.spacing.extraSmall / 2

        Timer {
            running: root.visible && Nmcli.wifiEnabled
            repeat: true
            triggeredOnStart: true
            interval: GlobalConfig.nexus.networkRescanInterval
            onTriggered: Nmcli.rescanWifi()
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
