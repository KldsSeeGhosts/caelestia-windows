pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Caelestia.Config
import qs.components
import qs.services

// Quota / Agents Usage Dropdown Panel.
// Lives inside the drawers ContentWindow in the top-right corner.
Item {
    id: root

    required property ScreenState screenState

    readonly property bool shouldBeActive: screenState.quota && QuotaConfig.enabled
    // The relative-time tick only runs while this drawer is open.
    property bool clockHeld: false

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
        ((content.item as Content)?.implicitHeight ?? 0) + Tokens.padding.large * 2
    )
    opacity: 1 - offsetScale

    onOffsetScaleChanged: {
        if (offsetScale >= 1) {
            Quota.resetToDefault();
            (content.item as Content)?.resetScroll();
        }
    }

    Behavior on offsetScale {
        Anim {}
    }

    Loader {
        id: content

        anchors.fill: parent
        anchors.margins: Tokens.padding.large

        active: root.shouldBeActive || root.visible
        sourceComponent: Content {
            loading: Quota.loading
            hasError: Quota.hasError
            error: Quota.error
            revealed: root.shouldBeActive
        }
    }
}
