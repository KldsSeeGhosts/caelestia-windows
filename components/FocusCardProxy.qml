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

    function transformedCorners(): var {
        if (!contentItem)
            return [];
        const contentWidth = contentItem.width;
        const contentHeight = contentItem.height;
        if (contentWidth <= 0 || contentHeight <= 0)
            return [];
        const matrix = inputTransformMatrix;
        const baseX = x + contentItem.x;
        const baseY = y + contentItem.y;
        return [
            Qt.point(baseX + matrix.m14, baseY + matrix.m24),
            Qt.point(baseX + matrix.m11 * contentWidth + matrix.m14,
                baseY + matrix.m21 * contentWidth + matrix.m24),
            Qt.point(baseX + matrix.m12 * contentHeight + matrix.m14,
                baseY + matrix.m22 * contentHeight + matrix.m24),
            Qt.point(baseX + matrix.m11 * contentWidth + matrix.m12 * contentHeight + matrix.m14,
                baseY + matrix.m21 * contentWidth + matrix.m22 * contentHeight + matrix.m24)
        ];
    }

    function containsPoint(sceneX: real, sceneY: real): bool {
        if (!inWindow || !contentItem)
            return false;
        if (clip && (sceneX < x || sceneX >= x + width || sceneY < y || sceneY >= y + height))
            return false;
        const matrix = inputTransformMatrix;
        const a = matrix.m11;
        const b = matrix.m12;
        const c = matrix.m21;
        const d = matrix.m22;
        const determinant = a * d - b * c;
        if (Math.abs(determinant) < 1e-8)
            return false;
        const baseX = x + contentItem.x;
        const baseY = y + contentItem.y;
        const px = sceneX - baseX - matrix.m14;
        const py = sceneY - baseY - matrix.m24;
        const localX = (d * px - b * py) / determinant;
        const localY = (-c * px + a * py) / determinant;
        return localX >= -0.01 && localX < contentItem.width + 0.01
            && localY >= -0.01 && localY < contentItem.height + 0.01;
    }

    function horizontalLineXs(corners, lineY): var {
        const xs = [];
        for (let i = 0; i < corners.length; i++) {
            const first = corners[i];
            const second = corners[(i + 1) % corners.length];
            const dy = second.y - first.y;
            if (Math.abs(dy) < 1e-8) {
                if (Math.abs(lineY - first.y) < 1e-8)
                    xs.push(first.x, second.x);
                continue;
            }
            const low = Math.min(first.y, second.y) - 1e-8;
            const high = Math.max(first.y, second.y) + 1e-8;
            if (lineY < low || lineY > high)
                continue;
            const t = (lineY - first.y) / dy;
            xs.push(first.x + t * (second.x - first.x));
        }
        return xs;
    }

    function bandedMaskSlices(): var {
        const corners = transformedCorners();
        if (!inWindow || corners.length !== 4)
            return [];
        let minimumY = Infinity;
        let maximumY = -Infinity;
        for (const corner of corners) {
            minimumY = Math.min(minimumY, corner.y);
            maximumY = Math.max(maximumY, corner.y);
        }
        let clipLeft = -Infinity;
        let clipRight = Infinity;
        if (clip) {
            minimumY = Math.max(minimumY, y);
            maximumY = Math.min(maximumY, y + height);
            clipLeft = x;
            clipRight = x + width;
        }
        const top = Math.floor(minimumY);
        const bottom = Math.ceil(maximumY);
        if (bottom <= top)
            return [];
        const count = Math.min(32, bottom - top);
        const slices = [];
        for (let i = 0; i < count; i++) {
            const sliceTop = top + Math.floor(i * (bottom - top) / count);
            const sliceBottom = top + Math.floor((i + 1) * (bottom - top) / count);
            if (sliceBottom <= sliceTop)
                continue;
            const xs = horizontalLineXs(corners, sliceTop).concat(horizontalLineXs(corners, sliceBottom));
            for (const corner of corners)
                if (corner.y >= sliceTop && corner.y <= sliceBottom)
                    xs.push(corner.x);
            if (xs.length === 0)
                continue;
            const left = Math.max(Math.min(...xs), clipLeft);
            const right = Math.min(Math.max(...xs), clipRight);
            const integerLeft = Math.floor(left);
            const integerRight = Math.ceil(right);
            if (integerRight > integerLeft)
                slices.push(Qt.rect(integerLeft, sliceTop, integerRight - integerLeft, sliceBottom - sliceTop));
        }
        return slices;
    }

    readonly property bool inputHasShear: Math.abs(inputTransformMatrix.m12) > 1e-6
        || Math.abs(inputTransformMatrix.m21) > 1e-6
    readonly property rect inputBounds: {
        if (!inWindow || !contentItem || !focusWindow)
            return Qt.rect(0, 0, 0, 0);
        const corners = transformedCorners();
        if (corners.length !== 4)
            return Qt.rect(0, 0, 0, 0);
        let left = Infinity;
        let right = -Infinity;
        let top = Infinity;
        let bottom = -Infinity;
        for (const corner of corners) {
            left = Math.min(left, corner.x);
            right = Math.max(right, corner.x);
            top = Math.min(top, corner.y);
            bottom = Math.max(bottom, corner.y);
        }
        const transformed = Qt.rect(left, top, right - left, bottom - top);
        if (!clip)
            return transformed;
        return intersectBounds(transformed, Qt.rect(x, y, width, height));
    }
    readonly property rect inputRegionBounds: {
        if (inputHasShear)
            return Qt.rect(0, 0, 0, 0);
        const bounds = inputBounds;
        if (bounds.width <= 0 || bounds.height <= 0)
            return Qt.rect(0, 0, 0, 0);
        const left = Math.floor(bounds.x);
        const top = Math.floor(bounds.y);
        const right = Math.ceil(bounds.x + bounds.width);
        const bottom = Math.ceil(bounds.y + bounds.height);
        return Qt.rect(left, top, right - left, bottom - top);
    }
    readonly property var inputMaskSlices: inputHasShear ? bandedMaskSlices() : []

    function maskContainsPoint(sceneX: real, sceneY: real): bool {
        if (!inWindow)
            return false;
        if (!inputHasShear) {
            const bounds = inputRegionBounds;
            return bounds.width > 0 && bounds.height > 0
                && sceneX >= bounds.x && sceneX < bounds.x + bounds.width
                && sceneY >= bounds.y && sceneY < bounds.y + bounds.height;
        }
        for (const slice of inputMaskSlices)
            if (sceneX >= slice.x && sceneX < slice.x + slice.width
                && sceneY >= slice.y && sceneY < slice.y + slice.height)
                return true;
        return false;
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
