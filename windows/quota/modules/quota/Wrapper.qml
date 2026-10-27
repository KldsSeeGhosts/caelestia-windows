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
    onShouldBeActiveChanged: {
        if (shouldBeActive && Date.now() - Quota.lastUpdatedAt > 30000)
            Quota.refresh();
    }

    property real offsetScale: shouldBeActive ? 0 : 1

    visible: offsetScale < 1
    width: implicitWidth
    anchors.topMargin: (-implicitHeight - 5) * offsetScale
    implicitWidth: QuotaConfig.panelWidth
    implicitHeight: Math.min(
        QuotaConfig.panelHeight,
        content.implicitHeight + Tokens.padding.large * 2
    )
    opacity: 1 - offsetScale

    onOffsetScaleChanged: {
        if (offsetScale >= 1) {
            Quota.resetToDefault();
            content.resetScroll();
        }
    }

    Behavior on offsetScale {
        Anim {}
    }

    Content {
        id: content

        anchors.fill: parent
        anchors.margins: Tokens.padding.large
        loading: Quota.loading
        hasError: Quota.hasError
        error: Quota.error
    }
}
