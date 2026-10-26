pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Caelestia.Config
import qs.components
import qs.components.controls
import qs.modules.launcher
import qs.modules.launcher.services

// Platform boundary derived from upstream modules/launcher/Wrapper.qml. The
// open/close geometry, hover activation and animation follow the original
// wrapper, but the loaded content is the apps slice's staging of the original
// AppList and SearchBar (appsOnly), because the full launcher ContentList,
// wallpapers, calculator and scheme rows have no reviewed Windows facade. The
// search never launches: the catalog facade refuses every launch without
// CAELESTIA_WINDOWS_APP_LAUNCH, which the combined launcher never sets.
Item {
    id: root

    required property ShellScreen screen
    required property ScreenState screenState
    required property var panels

    readonly property bool shouldBeActive: screenState.launcher && Config.launcher.enabled

    readonly property real maxHeight: {
        let max = screen.height - Config.border.thickness * 2 + Tokens.padding.extraLarge;
        if (screenState.dashboard)
            max -= panels.dashboard.nonAnimHeight;
        return max;
    }

    property real offsetScale: shouldBeActive ? 0 : 1

    onShouldBeActiveChanged: {
        if (shouldBeActive)
            implicitHeight = Qt.binding(() => content.implicitHeight);
        else
            implicitHeight = implicitHeight; // Break binding during close anim
    }

    visible: offsetScale < 1
    anchors.bottomMargin: (-implicitHeight - 5) * offsetScale
    implicitHeight: content.implicitHeight
    implicitWidth: content.implicitWidth || 630 // Hard coded fallback for first open
    opacity: 1 - offsetScale

    Component.onCompleted: Qt.callLater(() => Apps) // Load apps on init

    Behavior on offsetScale {
        Anim {}
    }

    Loader {
        id: content

        anchors.top: parent.top
        anchors.horizontalCenter: parent.horizontalCenter

        active: root.shouldBeActive || root.visible

        // Localized content: the original app list and search bar exactly as
        // the bounded apps prototype stages them.
        sourceComponent: Item {
            id: panel

            // Sized from the list as upstream Content.qml does; the search bar
            // fills the panel, so it cannot size it.
            implicitWidth: listWrapper.width + Tokens.padding.large * 2
            implicitHeight: listWrapper.height + search.implicitHeight + Tokens.padding.large * 2

            Item {
                id: listWrapper

                implicitWidth: list.width
                implicitHeight: list.height + Tokens.padding.large

                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottom: search.top
                anchors.bottomMargin: Tokens.padding.large

                AppList {
                    id: list

                    objectName: "combinedLauncherAppList"
                    width: Tokens.sizes.launcher.itemWidth
                    height: Math.min(root.maxHeight - search.implicitHeight - Tokens.padding.large * 3, implicitHeight)
                    search: search
                    screenState: root.screenState
                    appsOnly: true
                }
            }

            SearchBar {
                id: search

                objectName: "combinedLauncherSearch"

                anchors.left: parent.left
                anchors.right: parent.right
                anchors.bottom: parent.bottom
                anchors.margins: Tokens.padding.large

                onAccepted: {
                    if (!Apps.launchEnabled || !list.currentItem || !list.currentItem.modelData)
                        return;
                    Apps.launch(list.currentItem.modelData);
                }
            }
        }
    }
}
