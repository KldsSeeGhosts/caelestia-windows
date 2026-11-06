pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Shapes
import Caelestia.Config
import qs.components
import qs.components.effects
import qs.services

// The hover detail OpenUsage opens from a row's figure (Views/HoverPopoverState.swift,
// Views/MotionAwareHoverPopover.swift): it appears 400 ms after the pointer
// settles on the figure, stays while the pointer is over the figure or the
// detail, and goes 180 ms after it leaves both. A click opens it explicitly,
// and then it stays until Escape, another click or the drawer closing. Drawn
// inside the drawer, below the figure with its arrow pointing up at it, or
// above it when there is no room below.
Item {
    id: root
    objectName: "quotaPopover"

    // What the popover is laid out inside (the drawer content).
    required property Item boundsItem
    property Item anchorItem: null
    property Component detail: null
    // What the detail shows. Not `data`: that is Item's own list of children.
    property var detailData: null
    property bool explicit: false
    readonly property bool open: anchorItem !== null && shown
    property bool shown: false
    property bool overAnchor: false
    readonly property bool above: placement.above
    // The loaded detail, for tests and accessibility.
    readonly property Item detailItem: loader.item
    readonly property Item arrowItem: arrowShape
    // The arrow reads as part of the card but stands off it: a raised surface
    // and the theme's outline, not the card's faint hairline (OpenUsage).
    readonly property color arrowFill: Colours.palette.m3surfaceContainerHigh
    readonly property color arrowStroke: Colours.palette.m3outline
    readonly property int arrowHeight: 8
    readonly property int arrowWidth: 18

    signal dismissed()

    // OpenUsage's reveal delay and hide grace.
    readonly property int revealDelay: 400
    readonly property int hideGrace: 180

    function hover(anchor: Item, component: Component, detail: var, active: bool): void {
        if (active) {
            if (root.anchorItem !== anchor && root.shown && !root.explicit)
                root.shown = false;
            root.anchorItem = anchor;
            root.detail = component;
            root.detailData = detail;
            root.overAnchor = true;
            hideTimer.stop();
            if (!root.shown)
                showTimer.restart();
        } else if (root.anchorItem === anchor) {
            root.overAnchor = false;
            showTimer.stop();
            if (!root.explicit)
                hideTimer.restart();
        }
    }
    function openFor(anchor: Item, component: Component, detail: var): void {
        showTimer.stop();
        hideTimer.stop();
        root.anchorItem = anchor;
        root.detail = component;
        root.detailData = detail;
        root.explicit = true;
        root.shown = true;
    }
    function dismiss(): void {
        showTimer.stop();
        hideTimer.stop();
        const was = root.shown;
        root.shown = false;
        root.explicit = false;
        root.overAnchor = false;
        root.anchorItem = null;
        if (was)
            root.dismissed();
    }

    Timer {
        id: showTimer
        interval: root.revealDelay
        onTriggered: if (root.overAnchor) root.shown = true
    }
    Timer {
        id: hideTimer
        interval: root.hideGrace
        onTriggered: if (!root.overAnchor && !bodyHover.hovered && !root.explicit) root.dismiss()
    }

    visible: open
    z: 10
    width: body.width
    height: body.height + arrowHeight

    // Where the popover goes: centred on the figure, kept inside the bounds,
    // below it unless that would leave the bounds.
    QtObject {
        id: placement
        readonly property rect anchorRect: {
            const a = root.anchorItem;
            if (!a || !root.boundsItem)
                return Qt.rect(0, 0, 0, 0);
            // Re-evaluated while the content scrolls or reflows.
            void (a.x + a.y + a.width + a.height + root.boundsItem.width + root.boundsItem.height
                + (a.parent ? a.parent.x + a.parent.y + a.parent.width : 0) + (root.shown ? 1 : 0));
            const p = a.mapToItem(root.boundsItem, 0, 0);
            return Qt.rect(p.x, p.y, a.width, a.height);
        }
        readonly property bool above: anchorRect.y + anchorRect.height + root.height > root.boundsItem.height
            && anchorRect.y - root.height >= 0
        readonly property real x: Math.max(0, Math.min(root.boundsItem.width - root.width,
            anchorRect.x + anchorRect.width / 2 - root.width / 2))
        readonly property real arrowX: Math.max(16, Math.min(root.width - 16, anchorRect.x + anchorRect.width / 2 - x))
    }
    x: placement.x
    y: above ? placement.anchorRect.y - height - 2 : placement.anchorRect.y + placement.anchorRect.height + 2

    Elevation {
        anchors.fill: body
        radius: body.radius
        level: 2
    }
    Rectangle {
        id: body
        objectName: "quotaPopoverBody"
        y: root.above ? 0 : root.arrowHeight
        width: loader.implicitWidth
        height: loader.implicitHeight
        radius: Tokens.rounding.medium
        color: Colours.palette.m3surfaceContainer
        border.width: 1
        border.color: Qt.alpha(Colours.palette.m3onSurface, Colours.light ? 0.08 : 0.1)

        HoverHandler {
            id: bodyHover
            onHoveredChanged: {
                if (hovered)
                    hideTimer.stop();
                else if (!root.explicit && !root.overAnchor)
                    hideTimer.restart();
            }
        }
        Loader {
            id: loader
            active: root.open
            sourceComponent: root.detail
            // Every detail takes its data through a `detail` property.
            onLoaded: item.detail = Qt.binding(() => root.detailData)
        }
    }
    // The arrow, filled with the body colour and outlined on its two slanted
    // edges, over the body's border so the seam does not show.
    Shape {
        id: arrowShape
        objectName: "quotaPopoverArrow"
        x: placement.arrowX - root.arrowWidth / 2
        y: root.above ? body.height - 1 : 1
        width: root.arrowWidth
        height: root.arrowHeight
        ShapePath {
            fillColor: root.arrowFill
            strokeColor: root.arrowStroke
            strokeWidth: 1
            startX: 0
            startY: root.above ? 0 : root.arrowHeight
            PathLine { x: root.arrowWidth / 2; y: root.above ? root.arrowHeight : 0 }
            PathLine { x: root.arrowWidth; y: root.above ? 0 : root.arrowHeight }
        }
    }
}
