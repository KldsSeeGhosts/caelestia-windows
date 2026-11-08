pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Caelestia.Config
import Caelestia.I18n
import qs.components
import qs.components.effects
import qs.services
import "ThumbnailLogic.js" as Logic
import "../../utils/FileUrls.js" as FileUrls

// One post-capture preview, drawn by Thumbnails.qml inside its panel.
//
// The look follows the classic capture tool's thumbnail (260 x 174, surface
// fill, 1 px primaryContainer border, the image fitted 20 px in from every
// edge, a pill of 30 px buttons on surfaceVariant while the pointer is over
// it), built from Caelestia components and motion. The card owns only its own
// presentation and timeout. Everything that touches files or the clipboard is a
// function on `owner` (Thumbnails.qml).
Item {
    id: root

    required property var owner
    // A Thumbnails entry: path, saved, closing, imageWidth, imageHeight, dpr.
    required property var entry
    // This card's rectangle in the panel, from ThumbnailLogic.stackRects().
    required property var slot
    // Whether the panel is on screen. A hidden panel pauses the timeout, and
    // the card plays its entrance again when the panel returns.
    required property bool present

    // Fixtures set this because offscreen windows receive no pointer.
    property bool manualHover
    readonly property bool hovered: hover.hovered || manualHover
    readonly property bool paused: hovered || owner.suspended
    // Milliseconds of timeout used so far. Only unpaused time counts.
    property real elapsed

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

    function updateTarget(): void {
        const target = shown ? 1 : 0;
        slide = target;
        fade = target;
    }

    objectName: "captureThumbnail"
    x: slot.x
    y: slot.y
    width: slot.width
    height: slot.height
    opacity: fade
    transform: Translate {
        x: (1 - root.slide) * Logic.DRIFT
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

        property url target

        objectName: "captureThumbnailImage"
        anchors.centerIn: parent
        width: root.fit.width
        height: root.fit.height
        // The file may be replaced or deleted later (Save moves a preview file
        // into Screenshots), so the picture is read once.
        source: target
        sourceSize: Qt.size(Math.ceil(root.fit.width * root.entry.dpr), Math.ceil(root.fit.height * root.entry.dpr))
        fillMode: Image.PreserveAspectFit
        asynchronous: true
        cache: false
        smooth: true
        mipmap: true

        Component.onCompleted: target = FileUrls.fromLocalPath(root.entry.path)
    }

    // The card body opens the image. Nothing here edits it: the editor does not
    // exist yet.
    MouseArea {
        objectName: "captureThumbnailBody"
        anchors.fill: parent
        cursorShape: Qt.PointingHandCursor
        onClicked: root.owner.open(root.entry)
    }

    StyledRect {
        id: pill

        readonly property var names: Logic.actions(root.entry.saved)
        readonly property var geometry: Logic.pillRect({ width: root.width, height: root.height }, names.length)

        objectName: "captureThumbnailActions"
        x: geometry.x
        y: geometry.y
        width: geometry.width
        height: geometry.height
        radius: Tokens.rounding.medium
        color: Colours.palette.m3surfaceVariant
        opacity: root.hovered ? 1 : 0
        visible: opacity > 0

        Behavior on opacity {
            Anim {
                type: Anim.FastEffects
            }
        }

        Row {
            anchors.centerIn: parent
            spacing: Logic.BUTTON_GAP

            Repeater {
                model: pill.names

                ActionButton {
                    onTriggered: name => root.perform(name)
                }
            }
        }
    }

    component ActionButton: StyledRect {
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
        implicitWidth: Logic.BUTTON
        implicitHeight: Logic.BUTTON
        radius: Tokens.rounding.small

        ToolTip.visible: layer.containsMouse
        ToolTip.delay: 300
        ToolTip.text: spec.label
        Accessible.role: Accessible.Button
        Accessible.name: spec.label
        Accessible.onPressAction: button.triggered(button.modelData)

        StateLayer {
            id: layer

            radius: button.radius
            onClicked: button.triggered(button.modelData)
        }

        MaterialIcon {
            anchors.centerIn: parent
            anchors.verticalCenterOffset: 1
            text: button.spec.icon
            color: Colours.palette.m3primary
            fontStyle: Tokens.font.icon.medium
        }
    }
}
