pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Quickshell
import Caelestia.Config
import Caelestia.I18n
import qs.components
import qs.components.controls
import qs.components.effects
import qs.services
import "ThumbnailLogic.js" as Logic
import "../../utils/FileUrls.js" as FileUrls

// One post-capture preview, drawn by Thumbnails.qml inside its panel.
//
// The card is 260 x 174 with a surface fill, a primaryContainer border and the
// image fitted 20 px in from every edge, as the classic tool's thumbnail was.
// The buttons that show while the pointer is over it are Caelestia IconButtons
// in a row on surfaceVariant, sized by the control and by Tokens. The card owns
// only its own presentation and timeout. Everything that touches files or the clipboard is a
// function on `owner` (Thumbnails.qml).
Item {
    id: root

    required property var owner
    // A Thumbnails entry: path, imagePath, saved, closing, imageWidth,
    // imageHeight, dpr. `dragging` is optional (false when missing).
    required property var entry
    // This card's rectangle in the panel, from ThumbnailLogic.stackRects().
    required property var slot
    // Whether the panel is on screen. A hidden panel pauses the timeout, and
    // the card plays its entrance again when the panel returns.
    required property bool present

    // Fixtures set this because offscreen windows receive no pointer.
    property bool manualHover
    // The drag modal loop takes the pointer events, so the hover handler can keep
    // reporting "hovered" after a drag has ended somewhere else. After a drag the
    // handler is ignored until it reports a change or a movement of its own.
    property bool afterDrag
    readonly property bool hovered: (hover.hovered && !afterDrag) || manualHover
    // The owner sets this on the entry for as long as the system drag runs. The
    // card then keeps its timeout still, as it does under the pointer.
    readonly property bool dragging: entry.dragging === true
    readonly property bool paused: hovered || dragging || owner.suspended
    // Milliseconds of timeout used so far. Only unpaused time counts.
    property real elapsed

    // The press that may become a drag, in the card's coordinates. `armed` is
    // true from the press on the card body until it ends or becomes a drag.
    // `dragged` stays true after a drag until the next press, so the click that
    // the end of a drag can leave behind does not open the image.
    property point pressPoint
    property bool armed
    property bool dragged

    readonly property bool shown: present && !entry.closing
    // 0 to 1. `slide` moves the card in from the right with spatial motion and
    // `fade` is its opacity. A card that is closing is gone once `fade` is 0.
    property real slide
    property real fade
    readonly property var fit: Logic.fitImage({ width: width, height: height },
        { width: entry.imageWidth, height: entry.imageHeight }, entry.dpr)

    // A pill button runs one of the owner's actions.
    function perform(name: string): void {
        if (name === "copy")
            owner.copyEntry(entry);
        else if (name === "save")
            owner.saveEntry(entry);
        else if (name === "reveal")
            owner.reveal(entry);
        else if (name === "close")
            owner.close(entry);
    }

    // A press on the card body. The action buttons are above the body, so a
    // press on one of them never gets here.
    function bodyPressed(x: real, y: real): void {
        dragged = false;
        armed = true;
        pressPoint = Qt.point(x, y);
    }

    // The pointer moved with the button down. Past the system drag distance the
    // press becomes a drag of the image file. A press that never moves that far
    // is a click, which the body handles on release as before.
    function bodyMoved(x: real, y: real): void {
        if (!armed || dragging)
            return;
        if (!Logic.dragStarts(pressPoint, { x: x, y: y }, owner.dragDistance(), dpr))
            return;
        armed = false;
        dragged = true;
        owner.drag(entry, image);
        // The drag ate the button release, so the body still holds the pointer
        // grab. Turning it off and on lets go of it.
        body.enabled = false;
        body.enabled = true;
    }

    function bodyReleased(): void {
        armed = false;
    }

    function updateTarget(): void {
        const target = shown ? 1 : 0;
        slide = target;
        fade = target;
    }

    // The card starts on a whole device pixel, so everything placed in it with
    // whole device offsets (the pill, the buttons, their icons) is on one too. A
    // card sliding in is between pixels until it settles. The pixels are those of
    // the window the card is in, as Qt renders it now. `entry.dpr` is the ratio of
    // the capture and only sizes the image; the screen can change after a capture,
    // and the window announces that change.
    readonly property real windowDpr: (QsWindow.window as QsWindow)?.devicePixelRatio ?? 1
    readonly property real dpr: windowDpr > 0 ? windowDpr : 1

    objectName: "captureThumbnail"
    x: Logic.snap(slot.x, dpr)
    y: Logic.snap(slot.y, dpr)
    width: slot.width
    height: slot.height
    opacity: fade
    transform: Translate {
        x: (1 - root.slide) * Logic.DRIFT
    }

    onDraggingChanged: {
        if (!dragging)
            afterDrag = true;
    }

    onShownChanged: updateTarget()
    Component.onCompleted: updateTarget()

    // The entrance and exit animate; a card that is closing with nothing on
    // screen (hidden panel, motion off) must still finish.
    onFadeChanged: {
        if (fade === 0 && entry.closing)
            owner.finish(entry);
    }

    Connections {
        target: root.entry

        function onClosingChanged(): void {
            if (root.entry.closing && root.fade === 0)
                root.owner.finish(root.entry);
        }
    }

    Connections {
        target: root.owner

        // A new timeout starts the count again, as the classic tool does.
        function onSecondsChanged(): void {
            root.elapsed = 0;
        }
    }

    Timer {
        id: ticker

        property double last

        interval: 50
        repeat: true
        running: root.shown && root.owner.seconds > 0

        onRunningChanged: {
            if (running)
                last = Date.now();
        }

        onTriggered: {
            const now = Date.now();
            const delta = now - last;
            last = now;
            const next = Logic.advance(root.elapsed, delta, root.paused, root.owner.seconds);
            root.elapsed = next.elapsed;
            if (next.expired)
                root.owner.close(root.entry);
        }
    }

    Behavior on slide {
        Anim {
            type: Anim.DefaultSpatial
        }
    }

    Behavior on fade {
        Anim {
            type: Anim.DefaultEffects
        }
    }

    // A neighbour leaving moves the stack down. The first placement is not
    // animated, so a new card appears where it belongs.
    Behavior on y {
        enabled: root.fade >= 1

        Anim {
            type: Anim.DefaultSpatial
        }
    }

    HoverHandler {
        id: hover

        onHoveredChanged: root.afterDrag = false
        onPointChanged: root.afterDrag = false
    }

    // The rectangle this card occupies on screen, for the panel's input mask. It
    // is a sibling of the card, not a child, and follows the card's slide, so the
    // mask moves with the card as it enters and leaves. A region only watches an
    // item's x, y, width and height, and the slide is a transform. A card that
    // is fully transparent takes no presses.
    readonly property Item maskItem: maskArea

    Item {
        id: maskArea

        objectName: "captureThumbnailMask"
        parent: root.parent
        x: root.x + (1 - root.slide) * Logic.DRIFT
        y: root.y
        width: root.fade > 0 ? root.width : 0
        height: root.fade > 0 ? root.height : 0
    }

    Elevation {
        anchors.fill: card
        radius: card.radius
        level: 3
        z: -1
    }

    StyledRect {
        id: card

        anchors.fill: parent
        color: Colours.palette.m3surface
        // The classic tool's "normal" radius is Tokens.rounding.medium
        // (ThemeTokens.qml writes it under that name).
        radius: Tokens.rounding.medium
        border.width: 1
        border.color: Colours.palette.m3primaryContainer
    }

    Image {
        id: image

        objectName: "captureThumbnailImage"
        anchors.centerIn: parent
        width: root.fit.width
        height: root.fit.height
        // The owner points `imagePath` at the saved file before it deletes a
        // preview file, so this source never names a file that is about to go.
        // Any later reload (a new size or scale) reads the saved file.
        source: FileUrls.fromLocalPath(root.entry.imagePath)
        sourceSize: Qt.size(Math.ceil(root.fit.width * root.entry.dpr), Math.ceil(root.fit.height * root.entry.dpr))
        fillMode: Image.PreserveAspectFit
        asynchronous: true
        cache: false
        smooth: true
        mipmap: true
    }

    // The card body opens the image, and pulling it past the system drag distance
    // drags the image file out instead. Nothing here edits it: the editor does
    // not exist yet.
    MouseArea {
        id: body

        objectName: "captureThumbnailBody"
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onPressed: mouse => root.bodyPressed(mouse.x, mouse.y)
        onPositionChanged: mouse => root.bodyMoved(mouse.x, mouse.y)
        onReleased: root.bodyReleased()
        onCanceled: root.bodyReleased()
        onClicked: {
            if (!root.dragged)
                root.owner.open(root.entry);
        }
    }

    StyledRect {
        id: pill

        readonly property var names: Logic.actions(root.entry.saved)
        readonly property var geometry: Logic.pillRect({ width: root.width, height: root.height },
            { width: row.implicitWidth + Tokens.padding.extraSmall * 2, height: row.implicitHeight + Tokens.padding.extraSmall * 2 },
            { scale: root.dpr, bottom: Tokens.spacing.small })

        objectName: "captureThumbnailActions"
        x: geometry.x
        y: geometry.y
        width: geometry.width
        height: geometry.height
        radius: Tokens.rounding.large
        color: Colours.palette.m3surfaceVariant
        opacity: root.hovered ? 1 : 0
        visible: opacity > 0

        Behavior on opacity {
            Anim {
                type: Anim.FastEffects
            }
        }

        Row {
            id: row

            // Centred on a whole device pixel, so the buttons' edges are sharp too.
            x: Logic.snap((pill.width - width) / 2, root.dpr)
            y: Logic.snap((pill.height - height) / 2, root.dpr)
            spacing: Tokens.spacing.extraSmall

            Repeater {
                model: pill.names

                ActionButton {
                    onTriggered: name => root.perform(name)
                }
            }
        }
    }

    component ActionButton: IconButton {
        id: button

        required property string modelData
        readonly property var spec: ({
            copy: { icon: "content_copy", label: Tr.tr("Copy") },
            save: { icon: "save", label: Tr.tr("Save") },
            reveal: { icon: "folder_open", label: Tr.tr("Show in folder") },
            close: { icon: "close", label: Tr.tr("Close") }
        })[modelData]

        signal triggered(string name)

        objectName: "captureThumbnailAction-" + modelData
        type: IconButton.Text
        icon: spec.icon
        onClicked: triggered(modelData)

        // The control nudges its icon by a logical pixel. The icon goes to a
        // whole device pixel (see PixelSnap).
        label.transform: PixelSnap {
            target: button.label
            surface: root
            dpr: root.dpr
        }

        ToolTip.visible: hovered
        ToolTip.delay: 500
        ToolTip.text: spec.label
        Accessible.role: Accessible.Button
        Accessible.name: spec.label
        Accessible.onPressAction: button.clicked()
    }
}
