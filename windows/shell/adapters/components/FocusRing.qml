import QtQuick
import Caelestia.Config
import qs.services

// Windows port (#210): keyboard focus indicator. Upstream Caelestia has no
// keyboard path through its rows, so it has no focus treatment to reuse. This
// is M3's focus ring: a 3px secondary outline following the target's corners,
// drawn on top of the state layer. Set `offset` to draw it outside the target
// (M3's 2px gap); rows keep it inside, where neighbours and the page's clip
// cannot cut it. Bind `showing` to keyboard focus only: Control.visualFocus,
// or, on an item a click never focuses, activeFocus until a press sets its
// `pointerUsed` flag through pointerPressed() (the item clears the flag when
// its focus changes).
StyledRect {
    property bool showing
    property real offset

    readonly property bool isFocusRing: true

    // A press on a row or nav entry leaves keyboard focus where it was (rows
    // never take focus on a click), so hide that item's indicator, as a
    // control's visualFocus clears when a click moves focus to it.
    function pointerPressed(): void {
        const item = Window.activeFocusItem;
        if (item?.pointerUsed !== undefined)
            item.pointerUsed = true;
    }

    anchors.fill: parent
    anchors.margins: -offset
    z: 1

    border.width: 3
    border.color: Colours.palette.m3secondary
    opacity: showing ? 1 : 0
    visible: opacity > 0

    Behavior on opacity {
        Anim {
            type: Anim.DefaultEffects
        }
    }
}
