pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Quickshell.Services.SystemTray
import Caelestia.Config
import qs.components.effects
import qs.services
import qs.utils

MouseArea {
    id: root

    // Windows staging: the role stays shaped like the original SystemTray item
    // for upstream consumers, but the type is widened so a bounded fixture can
    // render delegates without referencing the native singleton. Upstream
    // models still supply SystemTrayItem objects, so behavior is unchanged.
    required property var modelData

    // Windows staging hooks. Defaults reproduce upstream Linux behavior: left
    // click activates, right click sends the secondary action, and both are
    // always enabled. The bounded Windows host disables interactions for
    // read-only observation. With nativeMenuMode it asks for the native context
    // menu instead of the secondary action, because the pinned backend reports
    // hasMenu=true while the menu handle is null (item.hpp lines 102-103).
    property bool interactionsEnabled: true
    property bool nativeMenuMode: false

    readonly property alias iconItem: icon

    signal nativeMenuRequested(real x, real y)

    acceptedButtons: Qt.LeftButton | Qt.RightButton
    // Windows compact trays must not leave invisible icons accepting clicks.
    enabled: interactionsEnabled
    hoverEnabled: nativeMenuMode
    ToolTip.visible: nativeMenuMode && containsMouse
    ToolTip.delay: 500
    ToolTip.text: modelData.title || modelData.id
    implicitWidth: Tokens.font.body.small.pointSize * 2
    implicitHeight: Tokens.font.body.small.pointSize * 2

    onClicked: event => {
        if (!root.interactionsEnabled)
            return;
        if (event.button === Qt.LeftButton)
            modelData.activate();
        else if (root.nativeMenuMode) {
            const point = root.mapToItem(null, root.width / 2, root.height / 2);
            root.nativeMenuRequested(point.x, point.y);
        } else
            modelData.secondaryActivate();
    }

    ColouredIcon {
        id: icon

        anchors.fill: parent
        source: Icons.getTrayIcon(root.modelData.id, root.modelData.icon)
        colour: Colours.palette.m3secondary
        layer.enabled: Config.bar.tray.recolour
    }
}
