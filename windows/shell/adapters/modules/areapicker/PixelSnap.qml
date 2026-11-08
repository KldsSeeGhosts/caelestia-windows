import QtQuick

// Moves a label or an icon onto a whole device pixel.
//
// StyledText draws with NativeRendering, so glyphs at a fractional device
// position look soft or unevenly spaced at 125% and 150% scaling. The Caelestia
// controls centre their content and add logical-pixel offsets (padding, the icon's
// one pixel nudge, the width of a label), and these land between device pixels
// even when the control itself is on one. Assign this to the `transform` of the
// text or icon item:
//
//   label.transform: PixelSnap { target: button.label; surface: bar; dpr: 1.25 }
//
// `surface` is an ancestor that the caller keeps on a whole device pixel (the
// toolbar, its popover or a thumbnail card). The shift is the difference between
// the item's position in that surface and the nearest whole device pixel. Only
// positions are read, never mapped coordinates, so the shift cannot feed back into
// itself, and it follows every later move of a layout above the item.
Translate {
    id: root

    required property Item target
    required property Item surface
    // The device pixel ratio of the screen.
    required property real dpr

    // Where the item's box starts in the surface, in logical pixels.
    readonly property point origin: {
        let x = 0;
        let y = 0;
        for (let item = target; item && item !== surface; item = item.parent) {
            x += item.x;
            y += item.y;
        }
        return Qt.point(x, y);
    }
    readonly property real ratio: dpr > 0 ? dpr : 1

    x: Math.round(origin.x * ratio) / ratio - origin.x
    y: Math.round(origin.y * ratio) / ratio - origin.y
}
