pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Caelestia.Config
import qs.components
import qs.services
import qs.modules.nexus as Nexus

// Quota / Agents Usage Dropdown Panel.
// Lives inside the drawers ContentWindow in the top-right corner.
Item {
    id: root

    required property ScreenState screenState

    readonly property bool shouldBeActive: screenState.quota && QuotaConfig.enabled
    // The relative-time tick only runs while this drawer is open.
    property bool clockHeld: false

    // Close the drawer and open Nexus on its Services page, found by its icon
    // rather than a fixed index so a reordered registry still lands there.
    function openServices(): void {
        root.screenState.quota = false;
        const idx = Nexus.PageRegistry.pages.findIndex(p => p.icon === "build");
        Nexus.WindowFactory.openPage(Math.max(0, idx));
    }

    function syncClock(): void {
        if (root.shouldBeActive && !root.clockHeld) {
            root.clockHeld = true;
            Quota.holdClock();
        } else if (!root.shouldBeActive && root.clockHeld) {
            root.clockHeld = false;
            Quota.releaseClock();
        }
    }

    onShouldBeActiveChanged: {
        root.syncClock();
        if (shouldBeActive && Date.now() - Quota.lastUpdatedAt > 30000)
            Quota.refresh();
    }
    Component.onCompleted: root.syncClock()
    Component.onDestruction: {
        if (root.clockHeld)
            Quota.releaseClock();
    }

    property real offsetScale: shouldBeActive ? 0 : 1

    visible: offsetScale < 1
    width: implicitWidth
    anchors.topMargin: (-implicitHeight - 5) * offsetScale
    implicitWidth: QuotaConfig.panelWidth
    implicitHeight: Math.min(
        QuotaConfig.panelHeight,
        (content.item?.implicitHeight ?? 0) + Tokens.padding.medium * 2
    )
    opacity: 1 - offsetScale

    onOffsetScaleChanged: {
        if (offsetScale >= 1) {
            Quota.resetToDefault();
            content.item?.resetScroll();
        }
    }

    Behavior on offsetScale {
        Anim {}
    }

    Loader {
        id: content

        anchors.fill: parent
        // OpenUsage's 12 dp panel margin (Support/PanelMetrics.swift).
        anchors.margins: Tokens.padding.medium

        active: root.shouldBeActive || root.visible
        // A URL boundary keeps the closed drawer's Content graph out of shell
        // compilation. Loader caches these initial bindings while inactive and
        // applies them before completion on every creation, including reopen.
        Component.onCompleted: content.setSource(Qt.resolvedUrl("Content.qml"), {
            loading: Qt.binding(() => Quota.loading),
            hasError: Qt.binding(() => Quota.hasError),
            error: Qt.binding(() => Quota.error),
            revealed: Qt.binding(() => root.shouldBeActive)
        })
    }

    Connections {
        target: content.item
        // Quota sources and the panel switch live on Nexus > Services
        // (the "Agent usage" section), which answers both of OpenUsage's
        // Accounts and Settings until a page of its own exists.
        function onAccountsRequested(): void { root.openServices(); }
        function onSettingsRequested(): void { root.openServices(); }
    }
}
