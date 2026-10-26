pragma ComponentBehavior: Bound

import QtQuick
import Caelestia.Config
import qs.components
import qs.modules.dashboard.media as PlayerUI
import qs.services

// Platform boundary derived from upstream modules/dashboard/Wrapper.qml. The
// open/close geometry, hover activation and animation follow the original
// wrapper, but the loaded content is the media slice's staging of the original
// player Details component, because the dashboard's other tabs (weather,
// performance, calendar, user) have no reviewed Windows facade. Transport
// controls stay disabled unless CAELESTIA_WINDOWS_MEDIA_CONTROLS is set,
// which the combined launcher never does.
Item {
    id: root

    required property ScreenState screenState

    readonly property real nonAnimHeight: content.item ? content.item.implicitHeight : 0
    readonly property bool shouldBeActive: screenState.dashboard && Config.dashboard.enabled
    property real offsetScale: shouldBeActive ? 0 : 1

    visible: offsetScale < 1
    anchors.topMargin: (-implicitHeight - 5) * offsetScale
    implicitHeight: content.implicitHeight
    implicitWidth: content.implicitWidth
    opacity: 1 - offsetScale

    Behavior on offsetScale {
        Anim {}
    }

    Loader {
        id: content

        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom

        active: root.shouldBeActive || root.visible

        // Localized content: the original dashboard media player details with
        // the reviewed read-only facade wiring.
        sourceComponent: StyledRect {
            id: panel

            readonly property real playerWidth: 420
            readonly property real padding: Tokens.padding.large

            implicitWidth: playerWidth + padding * 2
            implicitHeight: playerHost.item
                ? playerHost.item.implicitHeight + padding * 2 : padding * 2
            color: Colours.palette.m3surfaceContainer
            radius: Tokens.rounding.extraLarge

            Loader {
                id: playerHost

                active: Players.enabled
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.margins: panel.padding
                height: item ? Math.max(item.implicitHeight, 0) : 0

                sourceComponent: PlayerUI.Details {
                    objectName: "combinedMediaDetails"
                    width: parent ? parent.width : 0
                    controlsEnabled: Players.canControl(Players.active)
                }
            }
        }
    }
}
