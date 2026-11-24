pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Window
import Quickshell
import Caelestia.Components
import Caelestia.Config
import Caelestia.I18n
import qs.components
import qs.components.effects
import qs.services
import "ThumbnailLogic.js" as Logic
import "../../utils/FileUrls.js" as FileUrls

// One post-capture preview, drawn by Thumbnails.qml inside its panel.
//
// Keep the screenshot in view until hover reveals its actions. The owner
// handles the clipboard, file lifetime and native drag.
Item {
    id: root

    required property var owner
    // A Thumbnails entry: path, imagePath, saved, closing, imageWidth,
    // imageHeight, dpr. `dragging` is optional (false when missing).
    required property var entry
    // This card's rectangle in the panel, from ThumbnailLogic.stackRects().
    required property var slot
    // Whether the panel is on screen. Suspension pauses the timer without
    // rewinding the entrance of a card that was already displayed.
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
    readonly property bool paused: hovered || dragging || swipe > 0 || menuLoader.active || owner.suspended
        || !!entry.outputPending || !!entry.afterReveal || !!entry.copyOperation || entry.copyFailed === true
    // Milliseconds of timeout used so far. Only unpaused time counts.
    property real elapsed

    // The press that may become a drag, in the card's coordinates. `armed` is
    // true from the press on the card body until it ends or becomes a drag.
    // `dragged` stays true after a drag until the next press, so the click that
    // the end of a drag can leave behind does not open the image.
    property point pressPoint
    property bool armed
    property bool dragged
    property real swipe
    property bool swiping

    property bool entered
    readonly property bool readyForEntrance: image.status === Image.Ready || image.status === Image.Error || !entry.imagePath
    readonly property bool shown: present && entered && !entry.closing
    readonly property bool animateMotion: entry.fromEditor !== true || entry.closing
    // 0 to 1. `slide` moves the card in from the right with spatial motion and
    // `fade` is its opacity. A card that is closing is gone once `fade` is 0.
    property real slide
    property real fade
    readonly property bool cover: owner.appearance?.cover ?? true
    readonly property bool memoryPreview: !!entry.memorySource?.toString()
    readonly property real drift: (owner.appearance?.corner ?? "").endsWith("-left") ? -Logic.DRIFT : Logic.DRIFT
    readonly property real swipeX: swipe * Math.sign(drift)
    readonly property var controls: Logic.controls(width, height)
    readonly property font pillFont: Qt.font({ pixelSize: controls.font, weight: Font.Medium })
    readonly property real pillWidth: Logic.controls(width, height, Math.max(copyMetrics.advanceWidth, saveMetrics.advanceWidth)).buttonWidth
    readonly property real cornerRadius: 12

    TextMetrics { id: copyMetrics; font: root.pillFont; text: Tr.tr("Copy") }
    TextMetrics { id: saveMetrics; font: root.pillFont; text: Tr.tr("Save") }

    // A button runs one of the owner's actions.
    function perform(name: string): void {
        if (entry.outputPending && name !== "close")
            return;
        if (name === "copy")
            owner.copyEntry(entry, true);
        else if (name === "save") {
            if (owner.saveEntry(entry, owner.showExportPath))
                owner.close(entry);
        }
        else if (name === "reveal")
            owner.reveal(entry);
        else if (name === "edit")
            owner.edit(entry);
        else if (name === "pin")
            owner.pin(entry);
        else if (name === "close")
            owner.discardEntry ? owner.discardEntry(entry) : owner.close(entry);
    }

    // A press on the card body. The action buttons are above the body, so a
    // press on one of them never gets here.
    function bodyPressed(x: real, y: real): void {
        dragged = false;
        armed = true;
        swipe = 0;
        swiping = false;
        pressPoint = Qt.point(x, y);
    }

    // The pointer moved with the button down. Past the system drag distance the
    // press becomes a drag of the image file. A press that never moves that far
    // is a click, which the body handles on release as before.
    function bodyMoved(x: real, y: real): void {
        if (!armed || dragging || entry.outputPending)
            return;
        const dx = x + swipeX - pressPoint.x;
        const dy = y - pressPoint.y;
        const outward = Logic.dismissOffset(dx, dy, drift < 0);
        if (swiping || outward) {
            swiping = true;
            dragged = true;
            swipe = Math.max(0, dx * Math.sign(drift));
            return;
        }
        if (!Logic.dragStarts(pressPoint, { x, y }, owner.dragDistance(), dpr))
            return;
        armed = false;
        dragged = true;
        if (owner.drag(entry, image))
            owner.close(entry);
        // The drag ate the button release, so the body still holds the pointer
        // grab. Turning it off and on lets go of it.
        body.enabled = false;
        body.enabled = true;
    }

    function bodyReleased(cancelled = false): void {
        armed = false;
        if (!cancelled && swiping && swipe >= Math.max(8, Math.min(16, width * 0.05)))
            owner.close(entry);
        swipe = 0;
        swiping = false;
    }

    function enterWhenReady(): void {
        if (!present || entered || entry.closing || !readyForEntrance)
            return;
        entered = true;
        slide = 1;
        fade = 1;
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
    visible: present && entered && fade > 0
    opacity: fade * (1 - 0.45 * Math.min(1, swipe / 16))
    transform: Translate {
        x: (1 - root.slide) * root.drift + root.swipeX
    }

    onDraggingChanged: {
        if (!dragging)
            afterDrag = true;
    }

    onPresentChanged: enterWhenReady()
    onReadyForEntranceChanged: enterWhenReady()
    Component.onCompleted: enterWhenReady()

    // The entrance and exit animate; a card that is closing with nothing on
    // screen (hidden panel, motion off) must still finish.
    onFadeChanged: {
        if (fade === 0 && entry.closing)
            owner.finish(entry);
    }

    Connections {
        target: root.entry

        function onClosingChanged(): void {
            if (!root.entry.closing)
                return;
            if (!root.present || root.fade === 0) {
                root.owner.finish(root.entry);
                return;
            }
            root.slide = 0;
            root.fade = 0;
        }
    }

    Connections {
        target: root.visible && (root.entry.afterReveal || root.entry.captureReleasedAt) && !root.entry.previewPresented
            ? root.Window.window : null

        function onFrameSwapped(): void {
            root.entry.previewPresented = true;
            root.owner.logCaptureTiming(root.entry, "first-frame");
            Qt.callLater(root.owner.finishDeferredCapture, root.entry);
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
        enabled: root.animateMotion

        Anim {
            type: Anim.DefaultSpatial
        }
    }

    Behavior on fade {
        enabled: root.animateMotion

        Anim {
            type: Anim.DefaultEffects
        }
    }

    // A neighbour leaving moves the stack down. The first placement is not
    // animated, so a new card appears where it belongs.
    Behavior on y {
        enabled: root.present && root.fade >= 1

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
        x: root.x + (1 - root.slide) * root.drift + root.swipeX
        y: root.y
        width: root.visible ? root.width : 0
        height: root.visible ? root.height : 0
    }

    Elevation {
        anchors.fill: card
        radius: card.radius
        level: 3
        z: -1
    }

    Rectangle {
        id: card

        anchors.fill: parent
        color: root.cover ? "transparent" : "#1f1f1f"
        radius: root.cornerRadius
    }

    Image {
        id: image

        objectName: "captureThumbnailImage"
        anchors.fill: parent
        // The owner points `imagePath` at the saved file before it deletes a
        // preview file, so this source never names a file that is about to go.
        // Any later reload (a new size or scale) reads the saved file.
        source: root.memoryPreview ? root.entry.memorySource : FileUrls.fromLocalPath(root.entry.imagePath)
        sourceSize: root.memoryPreview ? Qt.size(-1, -1)
            : Qt.size(Math.ceil(width * root.dpr), Math.ceil(height * root.dpr))
        fillMode: root.cover ? Image.PreserveAspectCrop : Image.PreserveAspectFit
        clip: root.cover
        asynchronous: !root.memoryPreview
        retainWhileLoading: true // Save points this card at an identical PNG.
        cache: false
        smooth: true
        mipmap: true
    }

    // The offscreen software renderer can't run the rounded mask shader.
    ShaderEffectSource {
        id: imageTexture
        anchors.fill: image
        visible: false
        hideSource: roundedImage.visible
        sourceItem: roundedImage.visible ? image : null
    }

    RoundedMask {
        id: roundedImage
        anchors.fill: image
        visible: GraphicsInfo.api !== GraphicsInfo.Software
        source: imageTexture
        topLeftRadius: root.cornerRadius
        topRightRadius: topLeftRadius
        bottomLeftRadius: topLeftRadius
        bottomRightRadius: topLeftRadius
    }

    Rectangle {
        anchors.fill: parent
        radius: card.radius
        color: "transparent"
        border.width: 1.5
        border.color: Qt.rgba(1, 1, 1, 0.4)
    }

    // Click the body to dismiss, or drag the full-size file out of the panel.
    MouseArea {
        id: body

        objectName: "captureThumbnailBody"
        anchors.fill: parent
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onPressed: mouse => {
            if (mouse.button === Qt.LeftButton)
                root.bodyPressed(mouse.x, mouse.y);
        }
        onPositionChanged: mouse => root.bodyMoved(mouse.x, mouse.y)
        onReleased: mouse => {
            if (mouse.button === Qt.LeftButton)
                root.bodyReleased();
        }
        onCanceled: root.bodyReleased(true)
        onClicked: mouse => {
            if (mouse?.button === Qt.RightButton)
                menuLoader.active = true;
            else if (!root.dragged)
                root.owner.close(root.entry);
        }
        onWheel: wheel => {
            const delta = root.drift < 0 ? -wheel.pixelDelta.x : wheel.pixelDelta.x;
            wheel.accepted = delta > 0.5 && delta > Math.abs(wheel.pixelDelta.y) * 0.35;
            if (!wheel.accepted)
                return;
            root.swipe += delta;
            if (root.swipe >= 16) {
                root.owner.close(root.entry);
                root.swipe = 0;
            } else {
                resetWheel.restart();
            }
        }
    }

    Timer {
        id: resetWheel
        interval: 160
        onTriggered: root.swipe = 0
    }

    Loader {
        id: menuLoader
        active: false
        onLoaded: item.popup()
        sourceComponent: Menu {
            popupType: Popup.Window
            onClosed: Qt.callLater(() => menuLoader.active = false)
            MenuItem { text: Tr.tr("Copy"); enabled: !root.entry.outputPending; onTriggered: root.perform("copy") }
            MenuItem { text: Tr.tr("Save"); enabled: !root.entry.outputPending; onTriggered: root.perform("save") }
            MenuItem { text: Tr.tr("Save as…"); enabled: root.owner.showExportPath && !root.entry.outputPending; onTriggered: root.owner.saveAs(root.entry) }
            MenuSeparator {}
            MenuItem { text: Tr.tr("Open in editor"); enabled: !root.entry.outputPending; onTriggered: root.perform("edit") }
            MenuItem { text: Tr.tr("Pin to screen"); enabled: !root.entry.outputPending; onTriggered: root.perform("pin") }
            MenuItem { text: Tr.tr("Open image"); enabled: !root.entry.outputPending; onTriggered: root.owner.open(root.entry) }
            MenuItem { text: root.revealText; enabled: !root.entry.outputPending; onTriggered: root.perform("reveal") }
            MenuSeparator {}
            MenuItem { text: Tr.tr("Close all"); onTriggered: root.owner.closeAll() }
        }
    }

    readonly property string revealText: entry.saved || !owner.showExportPath ? Tr.tr("Show in folder") : Tr.tr("Save and show in folder")

    Item {
        id: actions
        objectName: "captureThumbnailActions"
        anchors.fill: parent
        opacity: root.hovered && !root.dragging ? 1 : 0
        visible: opacity > 0
        enabled: root.hovered && !root.dragging && !root.entry.closing

        Behavior on opacity {
            Anim { type: Anim.FastEffects }
        }

        Rectangle {
            objectName: "captureThumbnailScrim"
            anchors.fill: parent
            radius: card.radius
            color: Qt.rgba(0, 0, 0, 0.45)
        }

        Column {
            objectName: "captureThumbnailPrimaryActions"
            x: Logic.snap((actions.width - width) / 2, root.dpr)
            y: Logic.snap((actions.height - height) / 2, root.dpr)
            spacing: Logic.snap(root.controls.gap, root.dpr)

            PrimaryAction {
                operation: "copy"
                text: copyMetrics.text
            }
            PrimaryAction {
                operation: "save"
                text: saveMetrics.text
            }
        }

        CornerAction {
            operation: "close"
            text: Tr.tr("Close")
            symbol: "close"
        }
        CornerAction {
            operation: "pin"
            text: Tr.tr("Pin to screen")
            symbol: "push_pin"
            atRight: true
        }
        CornerAction {
            operation: "edit"
            text: Tr.tr("Edit")
            symbol: "edit"
            atBottom: true
        }
        CornerAction {
            operation: "reveal"
            text: root.revealText
            symbol: "folder_open"
            atRight: true
            atBottom: true
        }
    }

    component PrimaryAction: AbstractButton {
        id: button
        required property string operation
        enabled: !root.entry.outputPending
        objectName: "captureThumbnailAction-" + operation
        width: Logic.snap(root.pillWidth, root.dpr)
        height: Logic.snap(root.controls.buttonHeight, root.dpr)
        padding: 0
        hoverEnabled: true
        onClicked: root.perform(operation)
        background: Rectangle {
            radius: height / 2
            color: Qt.rgba(1, 1, 1, button.hovered || button.activeFocus ? 0.95 : 0.85)
        }
        contentItem: StyledText {
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            text: button.text
            font: root.pillFont
            color: button.hovered ? "black" : "#1a1a1a"
            transform: PixelSnap {
                target: button.contentItem
                surface: root
                dpr: root.dpr
            }
        }
        Accessible.role: Accessible.Button
        Accessible.name: text
        Accessible.onPressAction: clicked()
    }

    component CornerAction: AbstractButton {
        id: button

        required property string operation
        required property string symbol
        enabled: operation === "close" || !root.entry.outputPending
        property bool atRight
        property bool atBottom
        objectName: "captureThumbnailAction-" + operation
        padding: 0
        hoverEnabled: true
        width: Logic.snap(root.controls.corner, root.dpr)
        height: width
        x: Logic.snap(atRight ? parent.width - width - root.controls.pad : root.controls.pad, root.dpr)
        y: Logic.snap(atBottom ? parent.height - height - root.controls.pad : root.controls.pad, root.dpr)
        onClicked: root.perform(operation)

        background: Rectangle {
            radius: width / 2
            color: Qt.rgba(1, 1, 1, button.hovered || button.activeFocus ? 0.35 : 0.18)
            border.width: 1
            border.color: Qt.rgba(1, 1, 1, 0.5)
        }
        contentItem: StyledText {
            horizontalAlignment: Text.AlignHCenter
            verticalAlignment: Text.AlignVCenter
            text: button.symbol
            font.family: Tokens.font.icon.small.family
            font.pixelSize: root.controls.icon
            color: "white"
            transform: PixelSnap {
                target: button.contentItem
                surface: root
                dpr: root.dpr
            }
        }

        ToolTip.visible: hovered
        ToolTip.delay: 500
        ToolTip.text: text
        Accessible.role: Accessible.Button
        Accessible.name: text
        Accessible.onPressAction: button.clicked()
    }
}
