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
    required property matrix4x4 inputTransformMatrix
    property bool active: false
    property Item contentItem: null

    readonly property bool inWindow: active && focusWindow?.surface === focusSurface
    readonly property real contentOffsetX: focusWindow ? focusWindow.contentX - focusWindow.viewportX : 0
    readonly property real contentOffsetY: focusWindow ? focusWindow.contentY - focusWindow.viewportY : 0

    function intersectBounds(first: rect, second: rect): rect {
        const left = Math.max(first.x, second.x);
        const top = Math.max(first.y, second.y);
        const right = Math.min(first.x + first.width, second.x + second.width);
        const bottom = Math.min(first.y + first.height, second.y + second.height);
        if (right <= left || bottom <= top)
            return Qt.rect(0, 0, 0, 0);
        return Qt.rect(left, top, right - left, bottom - top);
    }

    readonly property rect inputBounds: {
        if (!inWindow || !contentItem || !focusWindow)
            return Qt.rect(0, 0, 0, 0);

        const contentWidth = contentItem.width;
        const contentHeight = contentItem.height;
        if (contentWidth <= 0 || contentHeight <= 0)
            return Qt.rect(0, 0, 0, 0);

        const matrix = inputTransformMatrix;
        const x0 = matrix.m14;
        const x1 = matrix.m11 * contentWidth + matrix.m14;
        const x2 = matrix.m12 * contentHeight + matrix.m14;
        const x3 = matrix.m11 * contentWidth + matrix.m12 * contentHeight + matrix.m14;
        const y0 = matrix.m24;
        const y1 = matrix.m21 * contentWidth + matrix.m24;
        const y2 = matrix.m22 * contentHeight + matrix.m24;
        const y3 = matrix.m21 * contentWidth + matrix.m22 * contentHeight + matrix.m24;
        const baseX = x + contentItem.x;
        const baseY = y + contentItem.y;
        const left = baseX + Math.min(x0, x1, x2, x3);
        const right = baseX + Math.max(x0, x1, x2, x3);
        const top = baseY + Math.min(y0, y1, y2, y3);
        const bottom = baseY + Math.max(y0, y1, y2, y3);
        const transformed = Qt.rect(left, top, right - left, bottom - top);
        if (!clip)
            return transformed;
        return intersectBounds(transformed, Qt.rect(x, y, width, height));
    }
    readonly property rect inputRegionBounds: {
        const bounds = inputBounds;
        if (bounds.width <= 0 || bounds.height <= 0)
            return Qt.rect(0, 0, 0, 0);
        const left = Math.floor(bounds.x);
        const top = Math.floor(bounds.y);
        const right = Math.ceil(bounds.x + bounds.width);
        const bottom = Math.ceil(bounds.y + bounds.height);
        return Qt.rect(left, top, right - left, bottom - top);
    }

    objectName: "drawerFocusCard"
    parent: inWindow ? focusWindow.contentHost : sourceItem
    x: inWindow ? focusWindow.viewportX : 0
    y: inWindow ? focusWindow.viewportY : 0
    width: inWindow ? focusWindow.viewportWidth : sourceItem.width
    height: inWindow ? focusWindow.viewportHeight : sourceItem.height
    clip: inWindow && focusWindow.viewportClips
    z: inWindow ? 1 : 0
}
