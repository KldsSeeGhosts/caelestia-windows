pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import qs.services

ToolTip {
    id: root
    property Item boundsItem
    property string family: ""
    padding: 10
    delay: 500
    timeout: 7000
    width: Math.min(boundsItem ? boundsItem.width - 16 : 300, label.implicitWidth + padding * 2)
    x: {
        if (!boundsItem)
            return (parent.width - width) / 2;
        const left = boundsItem.mapToItem(parent, 0, 0).x;
        return Math.max(left + 8, Math.min(left + boundsItem.width - width - 8, (parent.width - width) / 2));
    }
    y: parent.height + 6
    background: Rectangle {
        radius: 8
        color: Colours.palette.m3surfaceContainerHigh
        border.width: 1
        border.color: Colours.palette.m3outlineVariant
    }
    contentItem: Text {
        id: label
        text: root.text
        textFormat: Text.PlainText
        wrapMode: Text.WordWrap
        color: Colours.palette.m3onSurface
        font.family: root.family
        font.pixelSize: 11
        lineHeight: 1.2
    }
}
