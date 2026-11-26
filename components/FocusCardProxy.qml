pragma ComponentBehavior: Bound

import QtQuick

// Visual viewport for interactive drawer content while it is reparented into
// the fixed-size focus companion. Inactive use is a transparent pass-through,
// so the original drawer hierarchy keeps its layout and clipping.
Item {
    id: proxy

    required property var focusWindow
    required property Item sourceItem
    required property string focusSurface
    property bool active: false

    readonly property bool inWindow: active && focusWindow?.surface === focusSurface
    readonly property real contentOffsetX: focusWindow ? focusWindow.contentX - focusWindow.viewportX : 0
    readonly property real contentOffsetY: focusWindow ? focusWindow.contentY - focusWindow.viewportY : 0

    objectName: "drawerFocusCard"
    parent: inWindow ? focusWindow.contentHost : sourceItem
    x: inWindow ? focusWindow.viewportX : 0
    y: inWindow ? focusWindow.viewportY : 0
    width: inWindow ? focusWindow.viewportWidth : sourceItem.width
    height: inWindow ? focusWindow.viewportHeight : sourceItem.height
    clip: inWindow && focusWindow.viewportClips
    z: inWindow ? 1 : 0
}
